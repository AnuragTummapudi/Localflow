import XCTest
import Shared
@testable import CommandMode

@MainActor
final class VoiceAgentTests: XCTestCase {
    private struct Catalog: ApplicationCatalog {
        var apps = [ApplicationMatch(name: "Notes", bundleIdentifier: "com.apple.Notes", url: nil, confidence: 1),
                    ApplicationMatch(name: "Safari", bundleIdentifier: "com.apple.Safari", url: nil, confidence: 1),
                    ApplicationMatch(name: "Chrome", bundleIdentifier: "com.google.Chrome", url: nil, confidence: 1)]
        func installedApplications() -> [ApplicationMatch] { apps }
    }
    private final class System: NativeToolSystem {
        var calls: [AgentAction] = []
        var performBody: ((NativeToolID, ToolArguments) async throws -> ToolExecution)?
        func prepare(_ action: AgentAction) async throws -> AgentAction { try Task.checkCancellation(); return action }
        func perform(_ id: NativeToolID, arguments: ToolArguments) async throws -> ToolExecution {
            calls.append(AgentAction(toolID: id, arguments: arguments))
            return try await performBody?(id, arguments) ?? ToolExecution(message: id.description, verification: .verified)
        }
    }
    private final class Time { var value: Double = 0 }
    private func make(_ system: System, time: Time = Time(), catalog: Catalog = Catalog(),
                      evaluate: VoiceAgentCoordinator.Evaluate? = nil) throws -> VoiceAgentCoordinator {
        VoiceAgentCoordinator(commands: CommandMode(catalog: catalog), executor: ActionExecutor(registry: ToolRegistry(system: system)),
                              policy: try .calibrated(), clock: { time.value }, evaluate: evaluate ?? { _, fallback in
            AgentDecisionEvaluation(decisions: fallback, source: .deterministic)
        })
    }
    private func final(_ text: String, confidence: Float? = nil) -> FinalTranscript { FinalTranscript(text: text, confidence: confidence, source: .streaming) }
    private func early(_ agent: VoiceAgentCoordinator, _ time: Time, first: String = "Open Notes, create a new note", next: String = "Open Notes, create a new note, call it Startup Ideas") async {
        agent.receive(PartialTranscript(text: first)); await agent.waitForPendingWork()
        time.value = 1.1
        agent.receive(PartialTranscript(text: next)); await agent.waitForPendingWork()
    }
    func testOpenNotesAuthoritativeFinalAndLifecycle() async throws {
        let system = System(), agent = try make(system)
        agent.begin(); await agent.finish(final("Open Notes"))
        XCTAssertEqual(system.calls.map(\.toolID), [.openApplication])
        XCTAssertEqual(agent.snapshot.actions[0].phases, [.proposed, .stable, .executing, .verified, .completed])
    }
    func testDeveloperEvidenceIsOptInAndRetainsActualReceiptOutput() async throws {
        let system = System(), agent = try make(system)
        system.performBody = { _, _ in ToolExecution(message: "Note read back", output: .note("test-owned-note"), verification: .verified) }
        agent.begin(); agent.receive(PartialTranscript(text: "create note Evidence")); await agent.waitForPendingWork()
        XCTAssertTrue(agent.snapshot.decisionTrace.isEmpty); XCTAssertTrue(agent.snapshot.streamingTranscript.isEmpty)
        agent.developerTraceEnabled = true
        agent.receive(PartialTranscript(text: "create note Evidence: Exact BODY")); await agent.waitForPendingWork()
        await agent.finish(final("create note Evidence: Exact BODY"))
        XCTAssertEqual(agent.snapshot.actions.last?.action.arguments, .note(title: "Evidence", body: "Exact BODY"))
        XCTAssertEqual(agent.snapshot.actions.last?.output, .note("test-owned-note"))
        XCTAssertFalse(agent.snapshot.decisionTrace.isEmpty)
        XCTAssertEqual(agent.snapshot.streamingTranscript, "create note Evidence: Exact BODY")
        agent.clearDeveloperTrace()
        XCTAssertTrue(agent.snapshot.decisionTrace.isEmpty); XCTAssertTrue(agent.snapshot.streamingTranscript.isEmpty)
    }
    func testClearTextPayloadCommandNeverCallsOptionalModel() async throws {
        let system = System()
        var count = 0
        let agent = try make(system, evaluate: { _, fallback in count += 1; return AgentDecisionEvaluation(decisions: fallback, source: .laya) })
        agent.begin(); await agent.finish(final("type at cursor Keep CASE and open Notes"))
        XCTAssertEqual(count, 0)
        XCTAssertEqual(system.calls.count, 1)
        XCTAssertEqual(system.calls.first?.arguments, .text("Keep CASE and open Notes"))
    }
    func testNotesOpensBeforeNoteTitleAndBodyFinishAndDoesNotRepeat() async throws {
        let system = System(), time = Time(), agent = try make(system, time: time)
        agent.begin(); await early(agent, time)
        XCTAssertEqual(system.calls.map(\.toolID), [.openApplication])
        await agent.finish(final("Open Notes, create a new note, call it Startup Ideas, and write Build a local voice agent."))
        XCTAssertEqual(system.calls.map(\.toolID), [.openApplication, .createNote])
        XCTAssertEqual(system.calls.last?.arguments, .note(title: "Startup Ideas", body: "Build a local voice agent."))
    }
    func testSafariThenSearchRetainsExactQueryAndURL() async throws {
        let system = System(), time = Time(), agent = try make(system, time: time)
        agent.begin(); await early(agent, time, first: "Open Safari then search for Swift", next: "Open Safari then search for Swift actors")
        XCTAssertEqual(system.calls.map(\.toolID), [.openApplication])
        await agent.finish(final("Open Safari then search for Swift actors"))
        XCTAssertEqual(system.calls.map(\.toolID), [.openApplication, .openURL])
        guard case .url(let url) = system.calls.last?.arguments else { return XCTFail("Missing search URL") }
        XCTAssertTrue(url.absoluteString.contains("Swift"))
        XCTAssertTrue(url.absoluteString.contains("actors"))
    }
    func testCorrectionBeforeStableExecutionOnlyOpensSafari() async throws {
        let system = System(), time = Time(), agent = try make(system, time: time)
        agent.begin(); agent.receive(PartialTranscript(text: "Open Chrome")); await agent.waitForPendingWork()
        time.value = 0.2; agent.receive(PartialTranscript(text: "Open Chrome actually Safari")); await agent.waitForPendingWork()
        XCTAssertTrue(system.calls.isEmpty)
        await agent.finish(final("Open Chrome actually Safari"))
        XCTAssertEqual(system.calls.count, 1)
        guard case .application(let app, _) = system.calls[0].arguments else { return XCTFail() }
        XCTAssertEqual(app.name, "Safari")
    }
    func testLateCorrectionRequiresExplicitConfirmationAndNeverQuitsChrome() async throws {
        let system = System(), time = Time(), agent = try make(system, time: time)
        agent.begin(); await early(agent, time, first: "Open Chrome then search for Swift", next: "Open Chrome then search for Swift actors")
        XCTAssertEqual(system.calls.count, 1)
        await agent.finish(final("Open Chrome actually Safari then search for Swift actors"))
        XCTAssertNotNil(agent.snapshot.confirmation)
        XCTAssertEqual(system.calls.count, 1)
        await agent.confirm()
        XCTAssertEqual(system.calls.map(\.toolID), [.openApplication, .openApplication, .openURL])
    }
    func testRepeatedPartialIsNotStabilityEvidenceAndFinalDoesNotDoubleExecute() async throws {
        let system = System(), time = Time(), agent = try make(system, time: time)
        agent.begin(); agent.receive(PartialTranscript(text: "Open Notes then search for Swift")); await agent.waitForPendingWork()
        for _ in 0..<10 { time.value += 1; agent.receive(PartialTranscript(text: "Open Notes then search for Swift")) }
        await agent.waitForPendingWork()
        XCTAssertTrue(system.calls.isEmpty)
        await agent.finish(final("Open Notes then search for Swift"))
        await agent.finish(final("Open Notes then search for Swift"))
        XCTAssertEqual(system.calls.map(\.toolID), [.openApplication, .openURL])
    }
    func testAmbiguousOrSubstringAppNameCannotSpeculate() async throws {
        var catalog = Catalog(); catalog.apps.append(ApplicationMatch(name: "Notes", bundleIdentifier: "third.party.notes", url: nil, confidence: 1))
        let system = System(), time = Time(), agent = try make(system, time: time, catalog: catalog)
        agent.begin(); await early(agent, time)
        XCTAssertTrue(system.calls.isEmpty)
        let system2 = System(), agent2 = try make(system2, time: time)
        agent2.begin(); await early(agent2, time, first: "Open Note then search for Swift", next: "Open Note then search for Swift actors")
        XCTAssertTrue(system2.calls.isEmpty)
    }
    func testLowASRConfidenceRequiresConfirmationAtFinal() async throws {
        let system = System(), agent = try make(system)
        agent.begin(); await agent.finish(final("Open Notes", confidence: 0.4))
        XCTAssertTrue(system.calls.isEmpty); XCTAssertNotNil(agent.snapshot.confirmation)
        await agent.confirm(); XCTAssertEqual(system.calls.count, 1)
    }
    func testExactKnownCommandBypassesOptionalModelIncludingItsMoreSpeechVeto() async throws {
        let system = System(), time = Time()
        var modelCalls = 0
        let agent = try make(system, time: time, evaluate: { _, fallback in
            modelCalls += 1
            return AgentDecisionEvaluation(decisions: SpeechDecisions(intent: fallback.intent, risk: fallback.risk,
                requiresMoreSpeech: ScoredDecision(value: true, confidence: try! DecisionProbability(0.98), accepted: true)), source: .laya)
        })
        agent.begin(); await early(agent, time)
        XCTAssertEqual(system.calls.map(\.toolID), [.openApplication]); XCTAssertEqual(modelCalls, 0)
        await agent.finish(final("Open Notes"))
        XCTAssertNil(agent.snapshot.confirmation); XCTAssertEqual(system.calls.count, 1); XCTAssertEqual(modelCalls, 0)
    }
    func testLowConfidenceLayaAbstentionKeepsExactDeterministicFallback() async throws {
        let system = System(), time = Time()
        let agent = try make(system, time: time, evaluate: { _, _ in
            AgentDecisionEvaluation(decisions: SpeechDecisions(intent: ScoredDecision(value: .unknown, confidence: try! DecisionProbability(0.1), accepted: false),
                                                               risk: nil, requiresMoreSpeech: nil), source: .laya)
        })
        agent.begin(); await agent.finish(final("Open Notess"))
        XCTAssertTrue(system.calls.isEmpty); XCTAssertNotNil(agent.snapshot.confirmation)
        await agent.confirm()
        XCTAssertEqual(system.calls.map(\.toolID), [.openApplication])
    }
    func testConsequentialActionNeverRunsFromPartialAndNeedsFinalConfirmation() async throws {
        let system = System(), time = Time(), agent = try make(system, time: time)
        agent.begin(); await early(agent, time, first: "Quit Notes then open Safari", next: "Quit Notes then open Safari and search for Swift")
        XCTAssertTrue(system.calls.isEmpty)
        await agent.finish(final("Quit Notes then open Safari"))
        XCTAssertNotNil(agent.snapshot.confirmation); XCTAssertTrue(system.calls.isEmpty)
        await agent.confirm(); XCTAssertEqual(system.calls.map(\.toolID), [.quitApplication, .openApplication])
    }
    func testDependentCreateWaitsForVerifiedNotesReadiness() async throws {
        let system = System()
        system.performBody = { _, _ in ToolExecution(message: "Request sent", verification: .unverified("Not ready")) }
        let agent = try make(system)
        agent.begin(); await agent.finish(final("Open Notes then create note Startup Ideas: Build locally."))
        XCTAssertEqual(system.calls.map(\.toolID), [.openApplication])
        XCTAssertEqual(agent.snapshot.actions.last?.phase, .failed)
    }
    func testFailedPredecessorBlocksDependentAction() async throws {
        let system = System(); system.performBody = { _, _ in throw ToolError.unavailable("Cannot open") }
        let agent = try make(system)
        agent.begin(); await agent.finish(final("Open Notes then create note Ideas"))
        XCTAssertEqual(system.calls.count, 1); XCTAssertEqual(agent.snapshot.actions.last?.phase, .failed)
    }
    func testCancelMidActionStopsQueueAndNativeWait() async throws {
        let system = System(); let started = expectation(description: "native call started")
        system.performBody = { _, _ in
            started.fulfill(); try await Task.sleep(for: .seconds(10)); return ToolExecution(message: "Finished", verification: .verified)
        }
        let agent = try make(system); agent.begin()
        let finish = Task { await agent.finish(self.final("Open Notes then create note Ideas")) }
        await fulfillment(of: [started], timeout: 1)
        agent.cancel(); await finish.value
        XCTAssertEqual(system.calls.count, 1); XCTAssertTrue(agent.snapshot.isCancelled)
        XCTAssertFalse(agent.snapshot.actions.contains { $0.phase == .executing || $0.phase == .stable })
    }
    func testCancelPendingConfirmationAndNewSessionReset() async throws {
        let system = System(), agent = try make(system)
        agent.begin(); await agent.finish(final("Quit Notes")); agent.cancel(); await agent.confirm()
        XCTAssertTrue(system.calls.isEmpty)
        agent.begin(); await agent.finish(final("Open Notes"))
        XCTAssertFalse(agent.snapshot.isCancelled); XCTAssertEqual(system.calls.count, 1)
        XCTAssertEqual(agent.snapshot.actions.count, 1)
    }
    func testRewrittenPrefixResetsEvidence() throws {
        var tracker = StablePrefixTracker(); let policy = try SpeculationPolicy.calibrated()
        tracker.update("Open Chrome then search", at: 0)
        tracker.update("Open Safari then search for Swift", at: 1)
        XCTAssertEqual(tracker.stableWordCount(at: 2, policy: policy), 1)
        tracker.update("Open Safari then search for Swift actors", at: 2)
        XCTAssertGreaterThanOrEqual(tracker.stableWordCount(at: 3, policy: policy), 4)
    }
    func testHeldOutStabilityGatesRejectUnstableEvidence() throws {
        let policy = try SpeculationPolicy.calibrated()
        for (observations, age, expected) in [(1, 3.0, false), (2, 0.3, false), (4, 0.35, false), (3, 1.0, true), (2, 1.6, true)] {
            XCTAssertEqual(observations >= policy.observations && age >= policy.settleSeconds, expected)
        }
    }
    func testFinalConfidenceRevisionDoesNotRepeatAlreadyOpenedTarget() async throws {
        let system = System(), time = Time(), agent = try make(system, time: time)
        agent.begin(); await early(agent, time)
        await agent.finish(final("Open Notes", confidence: 0.4))
        XCTAssertEqual(system.calls.count, 1)
        XCTAssertNil(agent.snapshot.confirmation)
    }
    func testConfirmedLateCorrectionUsesNewTargetReadinessAndClearsNotice() async throws {
        let system = System(), time = Time(), agent = try make(system, time: time)
        system.performBody = { id, arguments in
            if case .application(let app, _) = arguments, app.name == "Chrome" {
                return ToolExecution(message: "Sent", verification: .unverified("Not ready"))
            }
            return ToolExecution(message: id.description, verification: .verified)
        }
        agent.begin(); await early(agent, time, first: "Open Chrome then search for Swift", next: "Open Chrome then search for Swift actors")
        await agent.finish(final("Open Safari then search for Swift actors"))
        XCTAssertNotNil(agent.snapshot.confirmation)
        await agent.confirm()
        XCTAssertEqual(system.calls.map(\.toolID), [.openApplication, .openApplication, .openURL])
        XCTAssertEqual(agent.snapshot.notice, "")
    }

    func testNewSessionWaitsForCancelledInferenceOwnership() async throws {
        let system = System(), started = expectation(description: "decision entered")
        var first = true
        let agent = try make(system, evaluate: { _, fallback in
            if first {
                first = false; started.fulfill()
                do { try await Task.sleep(for: .seconds(10)) } catch {}
            }
            return AgentDecisionEvaluation(decisions: fallback, source: .deterministic)
        })
        agent.begin(); agent.receive(PartialTranscript(text: "Open Notess"))
        await fulfillment(of: [started], timeout: 1)
        agent.cancel()
        await agent.cancelAndWait()
        agent.begin(); await agent.finish(final("Open Safari"))
        XCTAssertEqual(system.calls.count, 1)
        guard case .application(let app, _) = system.calls[0].arguments else { return XCTFail() }
        XCTAssertEqual(app.name, "Safari")
    }
    func testFinalCoalescesBehindPartialDecisionWithoutCancellingWarmEngine() async throws {
        let system = System(), started = expectation(description: "partial decision entered")
        var wasCancelled = false
        let agent = try make(system, evaluate: { state, fallback in
            if !state.isFinal {
                started.fulfill()
                do { try await Task.sleep(for: .milliseconds(25)) } catch { wasCancelled = true }
            }
            return AgentDecisionEvaluation(decisions: fallback, source: .deterministic)
        })
        agent.begin(); agent.receive(PartialTranscript(text: "Open Notess"))
        await fulfillment(of: [started], timeout: 1)
        await agent.finish(final("Open Safari"))
        XCTAssertFalse(wasCancelled)
        XCTAssertEqual(system.calls.count, 1)
        guard case .application(let app, _) = system.calls[0].arguments else { return XCTFail() }
        XCTAssertEqual(app.name, "Safari")
    }

    func testPunctuationAndCaseChangesAreNotNewStabilityEvidence() throws {
        var tracker = StablePrefixTracker()
        tracker.update("Open Notes then search", at: 0)
        tracker.update("open notes, then search.", at: 1)
        XCTAssertEqual(tracker.stableWordCount(at: 2, policy: try .calibrated()), 0)
    }
    func testFinalUnknownDoesNotExecuteProposedPartial() async throws {
        let system = System(), agent = try make(system)
        agent.begin(); agent.receive(PartialTranscript(text: "Open Notes")); await agent.waitForPendingWork()
        await agent.finish(final("I was describing how to open notes."))
        XCTAssertTrue(system.calls.isEmpty)
        XCTAssertFalse(agent.snapshot.actions.contains { $0.phase == .stable || $0.phase == .executing })
    }
    func testAmbiguousFinalNameRequiresConfirmation() async throws {
        var catalog = Catalog(); catalog.apps.append(ApplicationMatch(name: "Notes", bundleIdentifier: "third.party.notes", url: nil, confidence: 1))
        let system = System(), agent = try make(system, catalog: catalog)
        agent.begin(); await agent.finish(final("Open Notes"))
        XCTAssertTrue(system.calls.isEmpty); XCTAssertNotNil(agent.snapshot.confirmation)
    }
    func testSlowNativeReadinessCompletesBeforeCreateNote() async throws {
        let system = System()
        system.performBody = { id, _ in
            if id == .openApplication { await Task.yield(); try Task.checkCancellation() }
            return ToolExecution(message: id.description, verification: .verified)
        }
        let agent = try make(system); agent.begin()
        await agent.finish(final("Open Notes and create a new note, call it Ideas, and write Exact body."))
        XCTAssertEqual(system.calls.map(\.toolID), [.openApplication, .createNote])
        XCTAssertEqual(system.calls.last?.arguments, .note(title: "Ideas", body: "Exact body."))
    }

    func testPayloadCannotSmuggleSecondCommand() async throws {
        let system = System(), agent = try make(system)
        agent.begin(); await agent.finish(final("Create note Ideas: Build offline and open Safari then lock it"))
        XCTAssertEqual(system.calls.map(\.toolID), [.createNote])
        XCTAssertEqual(system.calls[0].arguments, .note(title: "Ideas", body: "Build offline and open Safari then lock it"))
    }
    func testUnsupportedEarlierClauseDoesNotBlockIndependentOpen() async throws {
        let system = System(), agent = try make(system)
        agent.begin(); await agent.finish(final("Something unclear then open Safari"))
        XCTAssertEqual(system.calls.map(\.toolID), [.openApplication]); XCTAssertFalse(agent.snapshot.notice.isEmpty)
    }
    func testIncompleteNoteBodyDoesNotCreatePlaceholderNote() async throws {
        let system = System(), agent = try make(system)
        agent.begin(); await agent.finish(final("Open Notes, create a new note, call it Startup Ideas, and write..."))
        XCTAssertEqual(system.calls.map(\.toolID), [.openApplication])
        XCTAssertFalse(agent.snapshot.notice.isEmpty)
    }
    func testLocalTimingsContainNoTranscriptAndAreBounded() async throws {
        let system = System(), time = Time(), agent = try make(system, time: time)
        agent.begin(); time.value = 0.4; agent.receive(PartialTranscript(text: "Open Notes")); await agent.waitForPendingWork()
        time.value = 2; await agent.finish(final("Open Notes"))
        XCTAssertEqual(agent.snapshot.timings.first?.kind, .speechToPartial)
        XCTAssertEqual(agent.snapshot.timings.first?.milliseconds, 400)
        XCTAssertTrue(agent.snapshot.timings.contains { $0.kind == .decision })
        XCTAssertTrue(agent.snapshot.timings.contains { $0.kind == .actionStart })
        XCTAssertTrue(agent.snapshot.timings.contains { $0.kind == .actionCompletion })
        XCTAssertLessThanOrEqual(agent.snapshot.timings.count, 128)
    }
}
