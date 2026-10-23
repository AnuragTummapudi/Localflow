import AVFoundation
import Speech
import XCTest
import Shared
import Engines
import CommandMode

final class AppleSpeechTests: XCTestCase {
    func testAudioRangesReplaceVolatileMergeThenFinalizeWithoutDuplicateAppend() {
        var ledger = SpeechPhraseLedger()
        XCTAssertTrue(ledger.replace(.init(startNanoseconds: 0, endNanoseconds: 10, text: "open n", isFinal: false)))
        XCTAssertTrue(ledger.replace(.init(startNanoseconds: 0, endNanoseconds: 12, text: "Open Notes.", isFinal: true)))
        XCTAssertFalse(ledger.replace(.init(startNanoseconds: 0, endNanoseconds: 12, text: "open boats", isFinal: false)))
        ledger.replace(.init(startNanoseconds: 20, endNanoseconds: 30, text: "open", isFinal: false))
        ledger.replace(.init(startNanoseconds: 25, endNanoseconds: 38, text: "Safari", isFinal: false))
        ledger.replace(.init(startNanoseconds: 20, endNanoseconds: 40, text: "Open Safari.", isFinal: true))
        XCTAssertEqual(ledger.text, "Open Notes. Open Safari.")
        XCTAssertEqual(ledger.phrases.map(\.id), [0, 20])
        XCTAssertEqual(ledger.finalizedWordCount, 4)
        XCTAssertEqual(ledger.partial.finalizedText, ledger.text)
        XCTAssertFalse(ledger.replace(ledger.phrases[1]))
    }
    func testIdenticalTextFinalizationAndAlternativesAreDistinctRevisions() {
        var ledger = SpeechPhraseLedger()
        ledger.replace(.init(startNanoseconds: 0, endNanoseconds: 10, text: "Open sapphiri", isFinal: false))
        let partial = ledger.partial
        ledger.replace(.init(startNanoseconds: 0, endNanoseconds: 10, finalizationNanoseconds: 12,
            text: "Open sapphiri", isFinal: true, confidence: 0.75, alternatives: ["Open Safari"]))
        XCTAssertNotEqual(partial, ledger.partial)
        XCTAssertEqual(ledger.phrases[0].confidence, 0.75)
        XCTAssertEqual(ledger.phrases[0].alternatives, ["Open Safari"])
        XCTAssertEqual(ledger.phrases[0].finalizationNanoseconds, 12)
    }
    func testQualityConfigurationDoesNotEnableFastResults() {
        let preset = SpeechTranscriber.Preset(transcriptionOptions: [], reportingOptions: [.volatileResults, .alternativeTranscriptions],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence])
        XCTAssertFalse(preset.reportingOptions.contains(.fastResults))
        XCTAssertTrue(preset.reportingOptions.contains(.volatileResults))
    }
    func testUnsupportedLocaleFailsWithoutInstallationOrFallback() async throws {
        let readiness = await AppleSpeechAssets.shared.readiness(localeIdentifier: "zz-ZZ")
        XCTAssertEqual(readiness.status, .unavailable)
        do {
            _ = try await AppleSpeechAssets.shared.prepare(localeIdentifier: "zz-ZZ", allowInstallation: false)
            XCTFail("Unsupported locale must fail")
        } catch { XCTAssertTrue(error is LocalFlowError) }
    }
    @MainActor func testRealAppleStreamingWithPacedTestOwnedAudioAndRestart() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let root = env["LOCALFLOW_APPLE_SPEECH_FIXTURES"] else { throw XCTSkip("Opt-in real Apple Speech fixtures; no microphone or automatic asset installation in the standard suite.") }
        let locale = env["LOCALFLOW_APPLE_SPEECH_LOCALE"] ?? "en-IN"
        if env["LOCALFLOW_APPLE_INSTALL"] == "1" {
            _ = try await AppleSpeechAssets.shared.prepare(localeIdentifier: locale, allowInstallation: true)
        }
        let ready = await AppleSpeechAssets.shared.readiness(localeIdentifier: locale)
        guard ready.status == .ready else { throw XCTSkip("Apple assets unavailable: " + ready.detail) }
        let engine = AppleSpeechEngine(localeIdentifier: ready.localeIdentifier)
        let (cancelAudio, cancelInput) = AsyncThrowingStream<PCMChunk, Error>.makeStream()
        let cancelled = Task { try await engine.transcribe(chunks: cancelAudio, onPartial: { _ in }) }
        cancelInput.yield(.init(samples: Array(repeating: 0, count: 1600), sampleRate: 16000))
        try await Task.sleep(for: .milliseconds(200))
        let cancelStart = ProcessInfo.processInfo.systemUptime
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Cancelled real analyzer returned an authoritative final") }
        catch { XCTAssertTrue(cancelled.isCancelled) }
        cancelInput.finish()
        let cancelMilliseconds = (ProcessInfo.processInfo.systemUptime - cancelStart) * 1000
        XCTAssertLessThan(cancelMilliseconds, 5000)
        var reports: [[String: Any]] = []
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent("fixtures.json"))) as! [[String: String]]
        for fixture in manifest {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: root).appendingPathComponent(fixture["file"]!))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: buffer)
            let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            let rate = file.processingFormat.sampleRate
            let (chunks, input) = AsyncThrowingStream<PCMChunk, Error>.makeStream(bufferingPolicy: .bufferingOldest(128))
            let evidence = LiveSpeechEvidence()
            let start = ProcessInfo.processInfo.systemUptime
            let native = AppleFixtureNativeSystem(start: start)
            let commands = CommandMode()
            let agent = VoiceAgentCoordinator(commands: commands, executor: ActionExecutor(registry: ToolRegistry(system: native))) { _, fallback in
                AgentDecisionEvaluation(decisions: fallback, source: .deterministic)
            }
            agent.begin()
            let (updates, relay) = AsyncStream<PartialTranscript>.makeStream()
            let consumer = Task { @MainActor in
                for await partial in updates { agent.receive(partial); await agent.waitForPendingWork() }
            }
            let worker = Task { try await engine.transcribe(chunks: chunks) {
                evidence.receive($0, elapsed: (ProcessInfo.processInfo.systemUptime - start) * 1000)
                relay.yield($0)
            } }
            for offset in stride(from: 0, to: samples.count, by: 1024) {
                input.yield(.init(samples: Array(samples[offset..<min(offset + 1024, samples.count)]), sampleRate: rate))
                try await Task.sleep(for: .seconds(1024 / rate))
            }
            // Silence lets Apple finalize an utterance while capture remains open.
            let silenceChunks = fixture["file"] == "continuation.caf" ? 160 : 70
            for _ in 0..<silenceChunks {
                input.yield(.init(samples: Array(repeating: 0, count: 1024), sampleRate: rate))
                try await Task.sleep(for: .seconds(1024 / rate))
            }
            let closed = (ProcessInfo.processInfo.systemUptime - start) * 1000
            input.finish()
            let result = try await worker.value
            relay.finish(); await consumer.value
            await agent.finish(FinalTranscript(text: result.text, confidence: result.confidence, phrases: result.phrases))
            let completed = (ProcessInfo.processInfo.systemUptime - start) * 1000
            XCTAssertFalse(result.text.isEmpty)
            XCTAssertTrue(result.phrases.allSatisfy(\.isFinal))
            let snapshot = evidence.snapshot()
            XCTAssertNotNil(snapshot.firstVolatile)
            XCTAssertLessThan(snapshot.firstVolatile ?? .infinity, closed)
            var row: [String: Any] = ["file": fixture["file"]!, "expected": fixture["utterance"]!, "final": result.text,
                "realAnalyzerCancellationMilliseconds": cancelMilliseconds,
                "exactTranscript": result.text == fixture["utterance"]!, "volatileFromInputStartMilliseconds": snapshot.firstVolatile.map { $0 as Any } ?? NSNull(),
                "firstFinalFromInputStartMilliseconds": snapshot.firstFinal.map { $0 as Any } ?? NSNull(),
                "finalDrainMilliseconds": completed - closed, "completedMilliseconds": completed,
                "inputClosedMilliseconds": closed, "trailingSilenceMilliseconds": Double(silenceChunks * 1024) / rate * 1000,
                "phraseCount": result.phrases.count, "revisions": snapshot.revisions,
                "confidence": result.confidence.map { $0 as Any } ?? NSNull(),
                "volatileRangeLagMilliseconds": snapshot.volatileLags, "finalRangeLagMilliseconds": snapshot.finalLags,
                "speechAlternatives": result.phrases.map { ["original": $0.text, "alternatives": $0.alternatives] as [String: Any] },
                "agentInput": "Real paced Apple Speech; injected native effects, deterministic decision fallback",
                "agentActions": native.rows,
                "agentActionsBeforeInputClose": native.rows.filter { ($0["milliseconds"] as! Double) < closed },
                "confirmation": agent.snapshot.confirmation?.action.summary as Any? ?? NSNull()]
            if let slot = fixture["slot"], let expected = fixture["value"] {
                let action = SpeechCommandSegmenter.noteAction(result.text) ?? {
                    if case .execute(let intent) = commands.resolve(result.text) { return intent.agentAction }
                    return nil
                }()
                var actual: String?
                if let action {
                    switch action.arguments {
                    case .note(let title, let body): actual = slot == "title" ? title : body
                    case .currentNote(let text, _): actual = text
                    case .reminder(let title, _, _): actual = title
                    case .url(let url): actual = slot == "query" ? URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value : url.absoluteString
                    case .website(let name): actual = MacNativeToolSystem.websiteURL(name)?.absoluteString
                    case .search(let query, _): actual = query
                    default: break
                    }
                }
                row["expectedSlot"] = expected; row["actualSlot"] = actual as Any? ?? NSNull()
                row["exactPayload"] = actual == expected
            }
            reports.append(row)
            if fixture["file"] == "continuation.caf" {
                XCTAssertEqual(native.rows.count, 4, "Every command after a pause must survive Apple streaming")
                XCTAssertEqual(native.rows.filter { ($0["milliseconds"] as! Double) < closed }.count, 4,
                               "The continuous fixture must act before recording closes")
            }
        }
        if let output = env["LOCALFLOW_APPLE_SPEECH_REPORT"] {
            // Replace optional nils with NSNull for honest unavailable measurements.
            let data = try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
            try data.write(to: URL(fileURLWithPath: output))
        }
    }
}

private final class LiveSpeechEvidence: @unchecked Sendable {
    private let lock = NSLock()
    private var firstVolatile: Double?
    private var firstFinal: Double?
    private var revisions = 0
    private var previous: [Int64: SpeechPhrase] = [:]
    private var volatileLags: [Double] = []
    private var finalLags: [Double] = []
    func receive(_ partial: PartialTranscript, elapsed: Double) {
        lock.lock(); defer { lock.unlock() }; revisions += 1
        for phrase in partial.phrases where previous[phrase.id] != phrase {
            if !phrase.text.isEmpty {
                let lag = elapsed - Double(phrase.endNanoseconds) / 1_000_000
                if phrase.isFinal { finalLags.append(lag) } else { volatileLags.append(lag) }
            }
            previous[phrase.id] = phrase
        }
        if firstVolatile == nil, partial.phrases.contains(where: { !$0.isFinal && !$0.text.isEmpty }) { firstVolatile = elapsed }
        if firstFinal == nil, partial.phrases.contains(where: { $0.isFinal && !$0.text.isEmpty }) { firstFinal = elapsed }
    }
    func snapshot() -> (firstVolatile: Double?, firstFinal: Double?, revisions: Int, volatileLags: [Double], finalLags: [Double]) {
        lock.lock(); defer { lock.unlock() }; return (firstVolatile, firstFinal, revisions, volatileLags, finalLags)
    }
}

@MainActor private final class AppleFixtureNativeSystem: NativeToolSystem {
    let start: Double
    var rows: [[String: Any]] = []
    init(start: Double) { self.start = start }
    func prepare(_ action: AgentAction) async throws -> AgentAction { action }
    func perform(_ id: NativeToolID, arguments: ToolArguments) async throws -> ToolExecution {
        rows.append(["tool": id.rawValue, "arguments": String(describing: arguments),
                     "milliseconds": (ProcessInfo.processInfo.systemUptime - start) * 1000])
        return ToolExecution(message: "Injected fixture receipt; no native effect", verification: .verified)
    }
}
