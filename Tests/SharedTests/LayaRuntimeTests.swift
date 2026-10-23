import XCTest
import CryptoKit
import CommandMode
import Shared
@testable import ModelManager

/// Pipe fixtures are test doubles only. The production helper always runs real ONNX inference.
@MainActor
final class LayaRuntimeTests: XCTestCase {
    private var temporary: URL!
    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("LocalFlow-LayaTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }

    private func fixture(response: String? = nil, stall: Bool = false) throws -> URL {
        let ready = #"{"ready":true,"protocolVersion":1,"coldLoadMilliseconds":4,"residentBytes":1024}"#
        let valid = response ?? #"{"intent":{"value":"dictation","confidence":0.9,"accepted":true},"risk":{"value":"safe","confidence":0.9,"accepted":true},"requiresMoreSpeech":{"value":false,"confidence":0.9,"accepted":true},"inferenceMilliseconds":1}"#
        let body = stall ? "exec /bin/sleep 10" : "printf '{\"id\":\"%s\",\"decisions\":%s}\\n' \"$request_id\" '\(valid)'"
        let script = """
        #!/bin/sh
        printf '%s\\n' '\(ready)'
        while IFS= read -r line; do
            request_id=$(printf '%s' "$line" | /usr/bin/sed -E 's/.*"id":"([^"]+)".*/\\1/')
            touch '\(temporary.appendingPathComponent("received").path)'
            \(body)
        done
        """
        let executable = temporary.appendingPathComponent("localflow-laya")
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return temporary
    }
    func testExplicitPreparationBundleContainsRealSourcesAndPins() throws {
        let script = try XCTUnwrap(DecisionModelManager.preparationScriptURL)
        let root = script.deletingLastPathComponent()
        for relative in ["prepare-laya.py", "LayaHelper/Package.swift", "LayaHelper/Package.resolved", "LayaHelper/Sources/LayaHelper/LocalLaya.swift", "Laya/evaluate.py", "Laya/utterances.json", "laya-questions.json"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path), relative)
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("laya-questions.json")), try DecisionQuestionSchema.data())
    }

    func testMissingModelReturnsFallbackWithoutLaunchingAProcess() async throws {
        let manager = DecisionModelManager(directory: temporary.appendingPathComponent("missing"))
        manager.prepareInstalled()
        XCTAssertEqual(manager.status, .notInstalled)
        let fallback = try DeterministicDecisionEngine.decisions(for: .execute(.mute), isFinal: true)
        let result = await manager.evaluate(DecisionState(text: "mute"), fallback: fallback)
        XCTAssertEqual(result, fallback)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.appendingPathComponent("missing").path))
    }
    func testNativeIPCReusesProcessAndUnloads() async throws {
        let engine = LayaDecisionEngine()
        let metrics = try await engine.loadInstalled(directory: fixture())
        XCTAssertEqual(metrics.residentBytes, 1024)
        for _ in 0..<2 {
            let result = try await engine.evaluate(DecisionState(text: "ordinary text"))
            XCTAssertEqual(result.intent?.value, .dictation)
        }
        await engine.unload()
        do { _ = try await engine.evaluate(DecisionState(text: "ordinary text")); XCTFail("Unloaded model should be unavailable") }
        catch { XCTAssertEqual(error as? DecisionError, .unavailable) }
    }
    func testUnloadDrainsInFlightInferenceBeforeImmediateReload() async throws {
        let engine = LayaDecisionEngine()
        _ = try await engine.loadInstalled(directory: fixture(stall: true))
        let pending = Task { try await engine.evaluate(DecisionState(text: "old session")) }
        let received = temporary.appendingPathComponent("received")
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: received.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: received.path))
        await engine.unload()
        _ = try await engine.loadInstalled(directory: fixture())
        do { _ = try await pending.value; XCTFail("Stopped old inference cannot return a result") } catch {}
        let new = try await engine.evaluate(DecisionState(text: "new session"))
        XCTAssertEqual(new.intent?.value, .dictation)
        await engine.unload()
    }
    func testDiskUsageAndRepeatedRemovalUseOnlyTestOwnedDirectory() async throws {
        let root = temporary.appendingPathComponent("model")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 1024).write(to: root.appendingPathComponent("weights"))
        let manager = DecisionModelManager(directory: root)
        let bytes = await manager.diskUsage()
        XCTAssertEqual(bytes, 1024)
        for _ in 0..<3 { try await manager.remove(); manager.prepareInstalled() }
        XCTAssertEqual(manager.status, .notInstalled); XCTAssertFalse(manager.isBusy)
        let empty = await manager.diskUsage(); XCTAssertEqual(empty, 0)
    }
    func testInvalidProbabilityRejectsResponseAndResetsRuntime() async throws {
        let engine = LayaDecisionEngine()
        let response = #"{"intent":{"value":"dictation","confidence":2,"accepted":true},"risk":{"value":"safe","confidence":0.9,"accepted":true},"requiresMoreSpeech":{"value":false,"confidence":0.9,"accepted":true},"inferenceMilliseconds":1}"#
        _ = try await engine.loadInstalled(directory: fixture(response: response))
        do { _ = try await engine.evaluate(DecisionState(text: "text")); XCTFail("Invalid score must fail") } catch {}
        let metrics = await engine.metrics
        XCTAssertNil(metrics)
    }
    func testCancellationStopsInferenceAndAllowsANewLoad() async throws {
        let engine = LayaDecisionEngine()
        _ = try await engine.loadInstalled(directory: fixture(stall: true))
        let task = Task { try await engine.evaluate(DecisionState(text: "text")) }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: temporary.appendingPathComponent("received").path) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: temporary.appendingPathComponent("received").path))
        let start = Date()
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled inference must not return decisions") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        _ = try await engine.loadInstalled(directory: fixture())
        let result = try await engine.evaluate(DecisionState(text: "new session"))
        XCTAssertEqual(result.intent?.value, .dictation)
        await engine.unload()
    }
    func testInferenceDeadlineStopsStalledHelperAndResetsState() async throws {
        let engine = LayaDecisionEngine()
        _ = try await engine.loadInstalled(directory: fixture(stall: true))
        let start = Date()
        do { _ = try await engine.evaluate(DecisionState(text: "text")); XCTFail("Stalled inference must fail") } catch {}
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        let metrics = await engine.metrics
        XCTAssertNil(metrics)
    }

    func testUnexpectedQuestionFieldsFailClosed() async throws {
        let engine = LayaDecisionEngine()
        _ = try await engine.loadInstalled(directory: fixture())
        do { _ = try await engine.evaluate(DecisionState(text: "text"), questions: [.intent]); XCTFail("Unrequested question fields must be rejected") } catch {}
        await engine.unload()
    }

    func testUnsupportedLanguageDoesNotKillWarmRuntime() async throws {
        let engine = LayaDecisionEngine()
        _ = try await engine.loadInstalled(directory: fixture())
        do { _ = try await engine.evaluate(DecisionState(text: "bonjour", languageCode: "fr")); XCTFail("English checkpoint must refuse French") }
        catch { XCTAssertEqual(error as? DecisionError, .unsupportedLanguage) }
        let result = try await engine.evaluate(DecisionState(text: "English"))
        XCTAssertEqual(result.intent?.value, .dictation)
        await engine.unload()
    }
    func testInvalidInstallPreservesExistingModelDirectory() async throws {
        let installed = temporary.appendingPathComponent("installed")
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        let marker = installed.appendingPathComponent("user-marker")
        try Data("existing".utf8).write(to: marker)
        let manager = DecisionModelManager(directory: installed)
        do { try await manager.install(from: temporary.appendingPathComponent("invalid")); XCTFail("Missing manifest must fail") } catch {}
        XCTAssertEqual(try Data(contentsOf: marker), Data("existing".utf8))
    }
    func testRealPackageCannotEnableAGateWithoutHeldOutEvidence() throws {
        guard let path = ProcessInfo.processInfo.environment["LOCALFLOW_LAYA_PACKAGE"] else {
            throw XCTSkip("Opt-in integrity check requires a real prepared package")
        }
        let tampered = temporary.appendingPathComponent("tampered-package")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: tampered)
        let calibrationURL = tampered.appendingPathComponent("calibration.json")
        var calibration = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: calibrationURL)) as? [String: [String: Any]])
        calibration["requires_more_speech"]?["enabled"] = true
        let bytes = try JSONSerialization.data(withJSONObject: calibration)
        try bytes.write(to: calibrationURL)
        let manifestURL = tampered.appendingPathComponent("manifest.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        var files = try XCTUnwrap(manifest["files"] as? [String: String])
        files["calibration.json"] = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        manifest["files"] = files
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        XCTAssertThrowsError(try DecisionModelManager.validate(tampered))
    }

    func testRealModelInstallRemoveAndReinstallWhenExplicitPackageIsProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["LOCALFLOW_LAYA_PACKAGE"] else {
            throw XCTSkip("Opt-in installation smoke test uses a temporary model directory")
        }
        let package = URL(fileURLWithPath: path)
        let installed = temporary.appendingPathComponent("installed-model")
        let manager = DecisionModelManager(directory: installed)
        let fallback = try DeterministicDecisionEngine.decisions(for: .execute(.mute), isFinal: true)
        for _ in 0..<2 {
            try await manager.install(from: package)
            for _ in 0..<400 {
                if manager.status == .ready || manager.status == .failed { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            XCTAssertEqual(manager.status, .ready)
            let result = await manager.evaluate(DecisionState(text: "Mute."), fallback: fallback)
            // Import/lifecycle remains supported, but v1's flat intent/risk
            // scores must no longer have production authority. Direct real
            // legacy inference is exercised separately below.
            XCTAssertEqual(result, fallback)
            let observation = await manager.evaluateForAgent(DecisionState(text: "Mute."), fallback: fallback)
            XCTAssertEqual(observation.source, .deterministic)
            XCTAssertEqual(observation.decisions, fallback)
            try await manager.remove()
            XCTAssertEqual(manager.status, .notInstalled)
            XCTAssertFalse(FileManager.default.fileExists(atPath: installed.path))
            let recovered = await manager.evaluate(DecisionState(text: "Mute."), fallback: fallback)
            XCTAssertEqual(recovered, fallback)
        }
    }

    func testRealLayaFeedsIncrementalAgentWithCalibratedAbstention() async throws {
        guard let path = ProcessInfo.processInfo.environment["LOCALFLOW_LAYA_PACKAGE"] else {
            throw XCTSkip("Opt-in real Laya + agent integration; no production model access or OS effects")
        }
        struct Catalog: ApplicationCatalog {
            func installedApplications() -> [ApplicationMatch] {
                [ApplicationMatch(name: "Notes", bundleIdentifier: "com.apple.Notes", url: nil, confidence: 1)]
            }
        }
        final class Boundary: NativeToolSystem {
            var calls: [NativeToolID] = []
            func prepare(_ action: AgentAction) async throws -> AgentAction { action }
            func perform(_ id: NativeToolID, arguments: ToolArguments) async throws -> ToolExecution {
                calls.append(id)
                return ToolExecution(message: id.description, verification: .verified)
            }
        }
        let package = URL(fileURLWithPath: path)
        try DecisionModelManager.validate(package)
        let engine = LayaDecisionEngine()
        _ = try await engine.loadInstalled(directory: package)
        let boundary = Boundary()
        let agent = VoiceAgentCoordinator(commands: CommandMode(catalog: Catalog()),
                                         executor: ActionExecutor(registry: ToolRegistry(system: boundary))) { state, fallback in
            do { return AgentDecisionEvaluation(decisions: try await engine.evaluate(state), source: .laya) }
            catch { XCTFail("Installed real inference failed: \(error)"); return AgentDecisionEvaluation(decisions: fallback, source: .deterministic) }
        }
        agent.begin()
        agent.receive(PartialTranscript(text: "Open Notess then create a note"))
        await agent.waitForPendingWork()
        XCTAssertTrue(boundary.calls.isEmpty)
        XCTAssertTrue(agent.snapshot.decisionSources.contains("laya"), "The uncertain target must exercise real optional inference")
        await agent.finish(FinalTranscript(text: "Open Notes then create note Startup Ideas: Build locally.", source: .streaming))
        XCTAssertEqual(boundary.calls, [.openApplication, .createNote])
        XCTAssertTrue(agent.snapshot.timings.contains { $0.kind == .decision && $0.milliseconds > 0 })
        await agent.cancelAndWait()
        await engine.unload()
    }

    func testRealNativeInferenceWhenExplicitTestPackageIsProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["LOCALFLOW_LAYA_PACKAGE"] else {
            throw XCTSkip("Opt-in real inference; ordinary tests never download models")
        }
        let package = URL(fileURLWithPath: path)
        try DecisionModelManager.validate(package)
        let engine = LayaDecisionEngine()
        let metrics = try await engine.loadInstalled(directory: package)
        XCTAssertGreaterThan(metrics.residentBytes, 0)
        for text in ["Open Notes.", "Search GitHub for Swift actors.", "Open Safari, no wait don't do anything yet."] {
            let result = try await engine.evaluate(DecisionState(text: text))
            XCTAssertNotNil(result.intent)
            XCTAssertNotNil(result.risk)
            XCTAssertNotNil(result.requiresMoreSpeech)
            XCTAssertGreaterThan(result.inferenceMilliseconds, 0)
        }
        await engine.unload()
    }
}
