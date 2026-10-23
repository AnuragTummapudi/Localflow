import XCTest
import CryptoKit
import CommandMode
import Shared
@testable import ModelManager

/// Real v2 ONNX opt-in. No downloads or changes to production model directories.
@MainActor
final class NarrowLayaRuntimeTests: XCTestCase {
    private func package() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["LOCALFLOW_LAYA_V2_PACKAGE"] else {
            throw XCTSkip("Opt-in prepared v2 model required.")
        }
        return URL(fileURLWithPath: path)
    }

    func testRealV2SupportsOnlyRequestedHeadsAndKeepsResidentRuntime() async throws {
        let root = try package()
        try DecisionModelManager.validate(root)
        let engine = LayaDecisionEngine()
        let loaded = try await engine.loadInstalled(directory: root)
        XCTAssertGreaterThan(loaded.residentBytes, 0)
        let version = await engine.protocolVersion
        XCTAssertEqual(version, 2)
        let workloads: [Set<NarrowDecisionQuestion>] = [
            [.actionableCommand], [.actionableCommand, .needsMoreSpeech],
            [.actionableCommand, .correctionOrReplacement], [.coarseFamily], Set(NarrowDecisionQuestion.allCases)
        ]
        for heads in workloads {
            let result = try await engine.evaluateNarrow(DecisionState(text: "Open Notes and create a", isFinal: false), questions: heads)
            XCTAssertEqual(result.actionableCommand != nil, heads.contains(.actionableCommand))
            XCTAssertEqual(result.needsMoreSpeech != nil, heads.contains(.needsMoreSpeech))
            XCTAssertEqual(result.correctionOrReplacement != nil, heads.contains(.correctionOrReplacement))
            XCTAssertEqual(result.coarseFamily != nil, heads.contains(.coarseFamily))
            XCTAssertGreaterThan(result.inferenceMilliseconds, 0)
            // Unreviewed v2 observations cannot become authority merely by import.
            XCTAssertFalse(result.actionableCommand?.accepted ?? false)
            XCTAssertFalse(result.needsMoreSpeech?.accepted ?? false)
            XCTAssertFalse(result.correctionOrReplacement?.accepted ?? false)
            XCTAssertFalse(result.coarseFamily?.accepted ?? false)
            let current = await engine.metrics
            XCTAssertEqual(current?.coldLoadMilliseconds, loaded.coldLoadMilliseconds)
        }
        do {
            _ = try await engine.evaluate(DecisionState(text: "Mute"))
            XCTFail("v2 cannot expose the removed risk/flat intent schema")
        } catch { XCTAssertEqual(error as? DecisionError, .unavailable) }
        await engine.unload()
        // Disabled/abstained actionability cannot justify extra streaming passes.
        let manager = DecisionModelManager(directory: root)
        manager.prepareInstalled()
        for _ in 0..<300 where manager.isBusy { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(manager.status, .ready)
        let routed = await manager.evaluateForAgent(DecisionState(text: "Open Notes and create a", isFinal: false),
            fallback: SpeechDecisions(intent: nil, risk: nil, requiresMoreSpeech: nil))
        let narrow = try XCTUnwrap(routed.decisions.narrow)
        XCTAssertNotNil(narrow.actionableCommand)
        XCTAssertFalse(narrow.actionableCommand?.accepted ?? true)
        XCTAssertNil(narrow.needsMoreSpeech)
        XCTAssertNil(narrow.correctionOrReplacement)
        XCTAssertNil(narrow.coarseFamily)
        await manager.engine.unload()
    }

    func testRehashedPoliciesStillCannotEnableUnreviewedV2() throws {
        let root = try package()
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("LocalFlow-v2-integrity-" + UUID().uuidString)
        try FileManager.default.copyItem(at: root, to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let calibrationURL = temporary.appendingPathComponent("calibration.json")
        var policies = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: calibrationURL)) as? [String: [String: Any]])
        policies["actionable_command"]?["enabled"] = true
        policies["actionable_command"]?["threshold"] = 0.99
        let calibration = try JSONSerialization.data(withJSONObject: policies)
        try calibration.write(to: calibrationURL)
        let validationURL = temporary.appendingPathComponent("validation.json")
        var evidence = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: validationURL)) as? [String: Any])
        evidence["policies"] = policies
        evidence["quality"] = ["actionable_command": ["calibrationWilsonLower": 1.0, "heldoutWilsonLower": 1.0]]
        let validation = try JSONSerialization.data(withJSONObject: evidence)
        try validation.write(to: validationURL)
        let manifestURL = temporary.appendingPathComponent("manifest.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        var hashes = try XCTUnwrap(manifest["files"] as? [String: String])
        hashes["calibration.json"] = SHA256.hash(data: calibration).map { String(format: "%02x", $0) }.joined()
        hashes["validation.json"] = SHA256.hash(data: validation).map { String(format: "%02x", $0) }.joined()
        manifest["files"] = hashes
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        XCTAssertThrowsError(try DecisionModelManager.validate(temporary))
    }
}
