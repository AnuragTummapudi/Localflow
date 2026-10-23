import XCTest
import Shared
@testable import CommandMode

@MainActor final class VoiceContinuationTests: XCTestCase {
    private struct Catalog: ApplicationCatalog {
        func installedApplications() -> [ApplicationMatch] {
            ["Notes", "Safari", "Chrome"].map { ApplicationMatch(name: $0, bundleIdentifier: "fixture." + $0, url: nil, confidence: 1) }
        }
    }
    private final class Time { var now = 0.0 }
    private final class System: NativeToolSystem {
        var calls: [AgentAction] = []
        var body: ((NativeToolID, ToolArguments) async throws -> ToolExecution)?
        func prepare(_ action: AgentAction) async throws -> AgentAction { try Task.checkCancellation(); return action }
        func perform(_ id: NativeToolID, arguments: ToolArguments) async throws -> ToolExecution {
            calls.append(AgentAction(toolID: id, arguments: arguments))
            return try await body?(id, arguments) ?? ToolExecution(message: "Fixture receipt", verification: .verified)
        }
    }
    private func make(_ system: System, _ time: Time) -> VoiceAgentCoordinator {
        VoiceAgentCoordinator(commands: CommandMode(catalog: Catalog()), executor: ActionExecutor(registry: ToolRegistry(system: system)), clock: { time.now }) { _, fallback in
            AgentDecisionEvaluation(decisions: fallback, source: .deterministic)
        }
    }
    private func revision(_ text: String, _ agent: VoiceAgentCoordinator, _ time: Time) async {
        time.now += 1.1; agent.receive(PartialTranscript(text: text)); await agent.waitForPendingWork()
    }
    func testAppleCorrectionRevokesUnsentConfirmationAndExecutesExactReplacement() async {
        let system = System(), time = Time()
        let executor = ActionExecutor(registry: ToolRegistry(system: system))
        let agent = VoiceAgentCoordinator(commands: CommandMode(catalog: Catalog()), executor: executor, clock: { time.now }) { _, fallback in
            AgentDecisionEvaluation(decisions: fallback, source: .deterministic)
        }
        agent.begin()
        var ledger = SpeechPhraseLedger()
        ledger.replace(.init(startNanoseconds: 0, endNanoseconds: 10, text: "Open Chrom", isFinal: true))
        agent.receive(ledger.partial); await agent.waitForPendingWork()
        guard let old = agent.snapshot.confirmation else { return XCTFail("Fuzzy finalized app needs a preview") }
        XCTAssertTrue(system.calls.isEmpty)
        ledger.replace(.init(startNanoseconds: 20, endNanoseconds: 30, text: "actually Safari", isFinal: true))
        agent.receive(ledger.partial); await agent.waitForPendingWork()
        XCTAssertNil(agent.snapshot.confirmation)
        XCTAssertEqual(system.calls.map(\.summary), ["Open application: Safari"])
        guard case .failed = await executor.confirm(old) else { return XCTFail("Revised confirmation must be revoked") }
        XCTAssertEqual(system.calls.count, 1)
    }
    func testAppleFinalizedRangesFlushPayloadAndContinueWithoutStoppingCapture() async {
        let system = System(), time = Time(), agent = make(system, time); agent.developerTraceEnabled = true; agent.begin()
        var ledger = SpeechPhraseLedger()
        for (index, text) in ["Open Notes", "Create a new note called Exact title", "Open Safari", "Search for Norbert Wiener", "Open Chrome", "Open github.com"].enumerated() {
            ledger.replace(.init(startNanoseconds: Int64(index * 100), endNanoseconds: Int64(index * 100 + 80), text: text, isFinal: false))
            agent.receive(ledger.partial); await agent.waitForPendingWork()
            ledger.replace(.init(startNanoseconds: Int64(index * 100), endNanoseconds: Int64(index * 100 + 80), text: text, isFinal: true))
            agent.receive(ledger.partial); await agent.waitForPendingWork()
        }
        XCTAssertFalse(agent.snapshot.isFinal)
        XCTAssertEqual(system.calls.map(\.toolID), [.openApplication, .createNote, .openApplication, .openURL, .openApplication, .openURL])
        XCTAssertTrue(system.calls.contains { $0.arguments == .note(title: "Exact title", body: "") })
        XCTAssertTrue(system.calls.contains {
            guard case .url(let url) = $0.arguments else { return false }
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value == "Norbert Wiener"
        })
        let count = system.calls.count
        await agent.finish(FinalTranscript(text: ledger.text, phrases: ledger.phrases))
        XCTAssertEqual(system.calls.count, count)
    }
    func testAppleAlternativeRescueUsesOnlyUniqueExactAppAndPreservesDiagnostics() async {
        let commands = CommandMode(catalog: Catalog())
        func choose(_ text: String, _ alternatives: [String]) -> SpeechInterpretation {
            SpeechAlternativeResolver.select(.init(startNanoseconds: 0, endNanoseconds: 10, text: text, isFinal: true, alternatives: alternatives), commands: commands)
        }
        XCTAssertEqual(choose("open sapphiri", ["open Safari"]).selected, "open Safari")
        let words = SpeechAlternativeResolver.selectAll([
            .init(startNanoseconds: 0, endNanoseconds: 5, text: "Open", isFinal: true),
            .init(startNanoseconds: 5, endNanoseconds: 10, text: "sapphiri", isFinal: true, alternatives: ["Safari"])
        ], commands: commands)
        XCTAssertEqual(words.map(\.selected).joined(separator: " "), "Open Safari")
        XCTAssertFalse(choose("open Notes", ["open Safari"]).rescued)
        XCTAssertFalse(choose("open sapphiri", ["open Safari", "open Chrome"]).rescued)
        for text in ["search for sapphiri", "create note sapphiri", "open example.com", "open GitHub", "open Notes and", "write sapphiri"] {
            XCTAssertFalse(choose(text, ["open Safari"]).rescued)
        }
        let system = System(), time = Time(), agent = make(system, time); agent.developerTraceEnabled = true; agent.begin()
        agent.receive(.init(text: "open sapphiri", revision: 1, phrases: [.init(startNanoseconds: 0, endNanoseconds: 10, text: "open sapphiri", isFinal: true, alternatives: ["open Safari"])]))
        await agent.waitForPendingWork()
        XCTAssertEqual(system.calls.map(\.summary), ["Open application: Safari"])
        XCTAssertEqual(agent.snapshot.speechInterpretations.first?.original, "open sapphiri")
        XCTAssertEqual(agent.snapshot.speechInterpretations.first?.selected, "open Safari")
    }
    func testReconstructContinuationPipelineWhenRequested() async throws {
        guard let output = ProcessInfo.processInfo.environment["LOCALFLOW_CONTINUATION_TRACE_OUTPUT"] else { throw XCTSkip("Opt-in bounded synthetic continuation pipeline reconstruction.") }
        #if DEBUG
        var records: [[AgentStreamTrace]] = []
        for sequence in [
            ["open", "open notes", "open notes open", "open notes open safari", "open notes open safari open", "open notes open safari open chrome"],
            ["open notes", "open notes open safari", "open notes open safari open chrome"],
            ["open notes", "open safari"],
            ["open notes then open", "open notes then open safari", "open safari", "open chrome", "open github.com"]
        ] {
            let system = System(), time = Time(), agent = make(system, time)
            agent.developerTraceEnabled = true; agent.begin()
            for text in sequence { await revision(text, agent, time) }
            records.append(agent.snapshot.streamTrace); await agent.cancelAndWait()
        }
        // Companion traces include the acoustic pause signal available to the live app.
        for sequence in [
            ["open notes", "open notes open safari", "open notes open safari open chrome", "open notes open safari open chrome open github.com"],
            ["open notes", "open safari", "open chrome", "open github.com"]
        ] {
            let system = System(), time = Time(), agent = make(system, time)
            agent.developerTraceEnabled = true; agent.begin()
            for text in sequence { await paused(text, agent, time) }
            XCTAssertEqual(system.calls.count, 4)
            records.append(agent.snapshot.streamTrace); await agent.cancelAndWait()
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: URL(fileURLWithPath: output), options: .atomic)
        #endif
    }
    func testUnpunctuatedDistinctAppCommandsAllExecuteAtFinal() async {
        let system = System(), time = Time(), agent = make(system, time); agent.begin()
        await agent.finish(FinalTranscript(text: "open notes open safari open chrome", source: .streaming))
        XCTAssertEqual(system.calls.map { $0.summary }, ["Open application: Notes", "Open application: Safari", "Open application: Chrome"])
    }
    func testIndependentOpenSurvivesUnknownPredecessorAtFinal() async {
        let system = System(), time = Time(), agent = make(system, time); agent.begin()
        await agent.finish(FinalTranscript(text: "open notes then open sapphiri then open chrome", source: .streaming))
        XCTAssertTrue(system.calls.contains { $0.summary == "Open application: Chrome" })
    }
    private func paused(_ text: String, _ agent: VoiceAgentCoordinator, _ time: Time) async {
        await revision(text, agent, time)
        time.now += 1.1; agent.observePause(silenceDurationSeconds: 1.1)
        await agent.waitForPendingWork()
    }
    func testAContinuousPausedNotesThenSafari() async {
        let system = System(), time = Time(), agent = make(system, time); agent.begin()
        await paused("open notes", agent, time)
        XCTAssertEqual(system.calls.map(\.summary), ["Open application: Notes"])
        await paused("open notes open safari", agent, time)
        XCTAssertEqual(system.calls.map(\.summary), ["Open application: Notes", "Open application: Safari"])
        XCTAssertEqual(agent.snapshot.consumedWordCursor, 4); XCTAssertFalse(agent.snapshot.isFinal)
    }
    func testBThreeIndependentUtteranceHypothesesAndURL() async {
        let system = System(), time = Time(), agent = make(system, time); agent.begin()
        for text in ["open notes", "open safari", "open chrome", "open github.com"] { await paused(text, agent, time) }
        XCTAssertEqual(system.calls.map(\.toolID), [.openApplication, .openApplication, .openApplication, .openURL])
        XCTAssertEqual(system.calls.prefix(3).map(\.summary), ["Open application: Notes", "Open application: Safari", "Open application: Chrome"])
        XCTAssertEqual(system.calls.last?.arguments, .url(URL(string: "https://github.com")!))
        XCTAssertEqual(agent.snapshot.consumedWordCursor, 8)
    }
    func testCNoPunctuationPrefixAdvancementExecutesBeforeFinal() async {
        let system = System(), time = Time(), agent = make(system, time); agent.begin()
        for text in ["open", "open notes", "open notes open", "open notes open safari", "open notes open safari open", "open notes open safari open chrome"] { await revision(text, agent, time) }
        time.now += 1.1; agent.observePause(silenceDurationSeconds: 1.1); await agent.waitForPendingWork()
        XCTAssertEqual(system.calls.map(\.summary), ["Open application: Notes", "Open application: Safari", "Open application: Chrome"])
        XCTAssertFalse(agent.snapshot.isFinal)
    }
    func testDRepeatedPartialAndBoundaryExecutesOnce() async {
        let system = System(), time = Time(), agent = make(system, time); agent.begin()
        for text in ["open notes", "open notes", "open notes."] { await revision(text, agent, time) }
        XCTAssertTrue(system.calls.isEmpty)
        agent.receive(PartialTranscript(text: "open notes.", isUtteranceBoundary: true)); await agent.waitForPendingWork()
        agent.receive(PartialTranscript(text: "open notes.", isUtteranceBoundary: true)); await agent.waitForPendingWork()
        await agent.finish(FinalTranscript(text: "Open Notes.", source: .streaming))
        XCTAssertEqual(system.calls.count, 1)
    }
    func testEUnknownMiddleCannotPoisonLaterIndependentCommand() async {
        let system = System(), time = Time(), agent = make(system, time); agent.begin()
        await paused("open notes", agent, time)
        await paused("open notes open sapphiri", agent, time)
        await paused("open notes open sapphiri open chrome", agent, time)
        await paused("open notes open sapphiri open chrome open github.com", agent, time)
        XCTAssertEqual(system.calls.map(\.toolID), [.openApplication, .openApplication, .openURL])
        XCTAssertEqual(system.calls[1].summary, "Open application: Chrome")
        XCTAssertNil(agent.snapshot.confirmation)
    }
    func testFNotesCreateAppendRetainContextDependencies() async {
        let system = System(), time = Time(), agent = make(system, time); agent.begin()
        await paused("open notes", agent, time)
        await paused("open notes create note LocalFlow Test", agent, time)
        await agent.finish(FinalTranscript(text: "open notes create note LocalFlow Test append to current note hello from LocalFlow", source: .streaming))
        XCTAssertEqual(system.calls.map(\.toolID), [.openApplication, .createNote])
        XCTAssertEqual(agent.snapshot.actions.last?.dependencies, [1])
        XCTAssertEqual(agent.snapshot.confirmation?.action.toolID, .appendNote)
        await agent.confirm()
        XCTAssertEqual(system.calls.map(\.toolID), [.openApplication, .createNote, .appendNote])
    }
    func testGUnverifiedIndependentAppDoesNotBlockNextApp() async {
        let system = System(), time = Time(), agent = make(system, time)
        system.body = { _, _ in ToolExecution(message: "Request accepted only", verification: .unverified("Fixture no readback")) }
        agent.begin(); await paused("open notes", agent, time); await paused("open notes open chrome", agent, time)
        XCTAssertEqual(system.calls.map(\.summary), ["Open application: Notes", "Open application: Chrome"])
        XCTAssertEqual(agent.snapshot.actions.last?.dependencies, [])
    }
    func testHCorrectionBeforeBoundaryOnlyOpensSafari() async {
        let system = System(), time = Time(), agent = make(system, time); agent.begin()
        await revision("open chrome", agent, time)
        await paused("open chrome actually safari", agent, time)
        XCTAssertEqual(system.calls.map(\.summary), ["Open application: Safari"])
    }
    func testIFinalFlushKeepsSentFirstAndExecutesTrailing() async {
        let system = System(), time = Time(), agent = make(system, time); agent.begin()
        await paused("open notes", agent, time)
        await agent.finish(FinalTranscript(text: "open notes open safari", source: .streaming))
        XCTAssertEqual(system.calls.map(\.summary), ["Open application: Notes", "Open application: Safari"])
        XCTAssertEqual(agent.snapshot.consumedWordCursor, 4)
    }
    func testJCancelKeepsSentFirstCancelsPendingLater() async {
        let system = System(), time = Time(), agent = make(system, time); agent.begin()
        await paused("open notes", agent, time); await revision("open notes open safari", agent, time)
        await agent.cancelAndWait()
        XCTAssertEqual(system.calls.map(\.summary), ["Open application: Notes"])
        XCTAssertTrue(agent.snapshot.actions[0].performed)
        XCTAssertEqual(agent.snapshot.actions.last?.phase, .cancelled)
    }
    func testKNewSessionResetsConsumedCursorAndLedger() async {
        let system = System(), time = Time(), agent = make(system, time); agent.begin()
        await paused("open notes", agent, time); await agent.cancelAndWait(); agent.begin()
        XCTAssertEqual(agent.snapshot.consumedWordCursor, 0); XCTAssertTrue(agent.snapshot.actions.isEmpty)
        await paused("open safari", agent, time)
        XCTAssertEqual(system.calls.map(\.summary), ["Open application: Notes", "Open application: Safari"])
    }
    func testContinuousGrammarDoesNotSplitPayloadOrCorrectionHeader() {
        XCTAssertEqual(SpeechCommandSegmenter.segments("write current note open notes open safari", continuous: true).count, 1)
        XCTAssertEqual(SpeechCommandSegmenter.segments("search google for how to open notes open safari", continuous: true).count, 1)
        XCTAssertEqual(SpeechCommandSegmenter.segments("open chrome actually open safari", continuous: true).map(\.text), ["open safari"])
        XCTAssertEqual(SpeechCommandSegmenter.segments("open notes open safari").count, 1)
    }
    func testFailedContextBlocksWriteButNotIndependentBrowser() async {
        let system = System(), time = Time(), agent = make(system, time)
        system.body = { _, arguments in
            if case .application(let app, _) = arguments, app.name == "Notes" { throw CocoaError(.fileNoSuchFile) }
            return ToolExecution(message: "Fixture ready", verification: .verified)
        }
        agent.begin(); await paused("open notes", agent, time)
        await paused("open notes create note Example", agent, time)
        await paused("open notes create note Example open chrome", agent, time)
        // A text-bearing clause owns its trailing text until an audio boundary closes it.
        await agent.finish(FinalTranscript(text: "open notes create note Example open chrome", source: .streaming))
        XCTAssertTrue(system.calls.contains { $0.summary == "Open application: Chrome" })
        XCTAssertFalse(system.calls.contains { $0.toolID == .createNote })
    }
    func testSameTargetInLaterUtteranceIsDistinctFromDuplicateASR() async {
        let system = System(), time = Time(), agent = make(system, time); agent.begin()
        await paused("open notes", agent, time); await paused("open notes open notes", agent, time)
        XCTAssertEqual(system.calls.count, 2)
        XCTAssertEqual(agent.snapshot.actions.map(\.segment), [0, 1])
    }
    func testDeveloperDiagnosticsAreBoundedAndOffByDefault() async {
        let system = System(), time = Time(), agent = make(system, time); agent.begin()
        await paused("open notes", agent, time)
        #if DEBUG
        XCTAssertTrue(agent.snapshot.streamTrace.isEmpty)
        agent.developerTraceEnabled = true
        for i in 0..<110 { await revision("open notes search google for topic \(i)", agent, time) }
        XCTAssertLessThanOrEqual(agent.snapshot.streamTrace.count, 96)
        agent.clearDeveloperTrace(); XCTAssertTrue(agent.snapshot.streamTrace.isEmpty)
        #endif
    }

    func testUnknownIndependentReplacementStillAllowsNextApp() async {
        let system = System(), time = Time(), agent = make(system, time); agent.begin()
        for text in ["open notes", "open sapphiri", "open chrome", "open github.com"] { await paused(text, agent, time) }
        XCTAssertEqual(system.calls.map(\.summary).prefix(2), ["Open application: Notes", "Open application: Chrome"])
        XCTAssertEqual(system.calls.last?.toolID, .openURL)
        XCTAssertNil(agent.snapshot.confirmation)
    }
    func testFinalIndependentReplacementDoesNotDuplicateCompletedUtterances() async {
        let system = System(), time = Time(), agent = make(system, time); agent.begin()
        await paused("open notes", agent, time); await paused("open safari", agent, time)
        await revision("open chrome", agent, time)
        await agent.finish(FinalTranscript(text: "open chrome", source: .streaming))
        XCTAssertEqual(system.calls.map(\.summary), ["Open application: Notes", "Open application: Safari", "Open application: Chrome"])
    }

    func testRequestedCompoundCreatesExactTitleAndBody() async {
        let system = System(), time = Time(), agent = make(system, time); agent.begin()
        await agent.finish(FinalTranscript(text: "Open Notes, create a new note called LocalFlow Test, and write hello from LocalFlow", source: .streaming))
        XCTAssertEqual(system.calls.map(\.toolID), [.openApplication, .createNote])
        XCTAssertEqual(system.calls.last?.arguments, .note(title: "LocalFlow Test", body: "hello from LocalFlow"))
    }

    func testUnsupportedMiddleCannotSilentlyReuseOlderNoteContext() async {
        let system = System(), time = Time(), agent = make(system, time); agent.begin()
        await agent.finish(FinalTranscript(text: "open notes then something unclear then create note Example", source: .streaming))
        // Unknown connectors are not standalone command headers: use an actual unknown app header.
        XCTAssertFalse(system.calls.contains { $0.toolID == .createNote })
        await agent.cancelAndWait(); agent.begin()
        await agent.finish(FinalTranscript(text: "open notes then open impossibleappname then create note Example", source: .streaming))
        XCTAssertFalse(system.calls.contains { $0.toolID == .createNote })
        XCTAssertEqual(agent.snapshot.confirmation?.action.toolID, .openApplication)
        XCTAssertEqual(agent.snapshot.actions.last?.dependencies, [1])
        await agent.cancelAndWait(); agent.begin()
        await agent.finish(FinalTranscript(text: "open notes then open then create note Example", source: .streaming))
        XCTAssertFalse(system.calls.contains { $0.toolID == .createNote })
        XCTAssertEqual(agent.snapshot.actions.last?.phase, .failed)
    }

    func testInstalledBundleShortNameExecutesAtPauseWithoutFuzzyGate() async {
        struct ChromeCatalog: ApplicationCatalog {
            func installedApplications() -> [ApplicationMatch] {
                [ApplicationMatch(name: "Google Chrome", bundleIdentifier: "com.google.Chrome", url: nil, confidence: 1, alternateNames: ["Chrome"])]
            }
        }
        let system = System(), time = Time()
        let agent = VoiceAgentCoordinator(commands: CommandMode(catalog: ChromeCatalog()), executor: ActionExecutor(registry: ToolRegistry(system: system)), clock: { time.now }) { _, fallback in
            XCTFail("Exact installed bundle name must bypass semantic inference")
            return AgentDecisionEvaluation(decisions: fallback, source: .fallback)
        }
        agent.begin(); await paused("open chrome", agent, time)
        XCTAssertEqual(system.calls.map(\.summary), ["Open application: Google Chrome"])
        XCTAssertNil(agent.snapshot.confirmation); XCTAssertFalse(agent.snapshot.isFinal)
    }
    func testAmbiguousBundleShortNameDoesNotExecuteAtPause() async {
        struct AmbiguousCatalog: ApplicationCatalog {
            func installedApplications() -> [ApplicationMatch] {
                ["stable", "beta"].map { ApplicationMatch(name: "Google Chrome " + $0, bundleIdentifier: "fixture." + $0, url: nil, confidence: 1, alternateNames: ["Chrome"]) }
            }
        }
        let system = System(), time = Time()
        let agent = VoiceAgentCoordinator(commands: CommandMode(catalog: AmbiguousCatalog()), executor: ActionExecutor(registry: ToolRegistry(system: system)), clock: { time.now }) { _, fallback in
            AgentDecisionEvaluation(decisions: fallback, source: .deterministic)
        }
        agent.begin(); await paused("open chrome", agent, time)
        XCTAssertTrue(system.calls.isEmpty)
        await agent.finish(FinalTranscript(text: "open chrome", source: .streaming))
        XCTAssertNotNil(agent.snapshot.confirmation); XCTAssertTrue(system.calls.isEmpty)
    }

}
