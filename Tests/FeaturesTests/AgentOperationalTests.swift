import XCTest
import Shared
@testable import CommandMode

@MainActor final class AgentOperationalTests: XCTestCase {
    private struct Catalog: ApplicationCatalog {
        func installedApplications() -> [ApplicationMatch] {
            [("Notes", "com.apple.Notes"), ("Safari", "com.apple.Safari"), ("Photo Booth", "com.apple.PhotoBooth"),
             ("Visual Studio Code", "com.microsoft.VSCode"), ("Terminal", "com.apple.Terminal")].map {
                ApplicationMatch(name: $0.0, bundleIdentifier: $0.1, url: nil, confidence: 1)
            }
        }
    }
    private final class System: NativeToolSystem {
        var calls: [AgentAction] = []
        var delay = false
        var onCall: (() -> Void)?
        func prepare(_ action: AgentAction) async throws -> AgentAction { try Task.checkCancellation(); return action }
        func perform(_ id: NativeToolID, arguments: ToolArguments) async throws -> ToolExecution {
            calls.append(AgentAction(toolID: id, arguments: arguments)); onCall?()
            if delay { try await Task.sleep(for: .seconds(10)) }
            return ToolExecution(message: id.description, verification: .verified)
        }
    }
    private var root: URL!
    private var store: AgentMemoryStore!
    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = AgentMemoryStore(directory: root)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root); store = nil }
    private func configured() throws -> CommandMode {
        var memory = AgentMemory()
        memory.preferredApps = ["browser": "Safari", "editor": "com.microsoft.VSCode", "terminal": "Terminal"]
        memory.applicationAliases = ["code": "Visual Studio Code"]
        memory.folders = ["LocalFlow project": "/tmp/LocalFlow"]
        memory.websites = ["placement portal": "https://example.com/placement"]
        memory.workflows = ["start LocalFlow": ["open LocalFlow project", "open my terminal", "open http://localhost:3000"]]
        try store.save(memory)
        return CommandMode(catalog: Catalog(), memory: memory)
    }
    private func agent(_ system: System, commands: CommandMode? = nil) -> VoiceAgentCoordinator {
        VoiceAgentCoordinator(commands: commands ?? CommandMode(catalog: Catalog()), executor: ActionExecutor(registry: ToolRegistry(system: system)), memoryStore: store) { _, fallback in
            AgentDecisionEvaluation(decisions: fallback, source: .deterministic)
        }
    }
    private func finish(_ agent: VoiceAgentCoordinator, _ text: String) async {
        await agent.finish(FinalTranscript(text: text, source: .streaming))
    }
    func testExactAliasesResolveOnlyAtCommandBoundary() throws {
        let commands = try configured()
        guard case .execute(.openApplication(let app)) = commands.resolve("Open my editor") else { return XCTFail() }
        XCTAssertEqual(app.bundleIdentifier, "com.microsoft.VSCode")
        XCTAssertFalse(commands.isExactApplicationOpen("Open my editor", action: .init(toolID: .openApplication, arguments: .application(app))))
        XCTAssertEqual(commands.resolve("I write about my editor"), .notCommand)
        guard case .execute(.openURL(let url)) = commands.resolve("Open placement portal") else { return XCTFail() }
        XCTAssertEqual(url.absoluteString, "https://example.com/placement")
        guard case .execute(.nativeAction(let action)) = commands.resolve("Open LocalFlow project") else { return XCTFail() }
        XCTAssertEqual(action.arguments, .file(URL(fileURLWithPath: "/tmp/LocalFlow")))
    }
    func testWorkflowWaitsForFinalAndExecutesInOrderOnce() async throws {
        let commands = try configured(), system = System()
        let actual = agent(system, commands: commands); actual.begin()
        actual.receive(PartialTranscript(text: "start LocalFlow")); await actual.waitForPendingWork()
        XCTAssertTrue(system.calls.isEmpty)
        await finish(actual, "start LocalFlow")
        await finish(actual, "start LocalFlow")
        XCTAssertEqual(system.calls.map(\.toolID), [.revealFile, .openApplication, .openURL])
        XCTAssertEqual(system.calls.last?.arguments, .url(URL(string: "http://localhost:3000")!))
        XCTAssertEqual(store.memory.approvedCommands.count, 0)
    }
    func testCyclesUnknownAndShellWorkflowsFailClosed() throws {
        let commands = try configured()
        var memory = store.memory
        memory.workflows = ["a": ["run b"], "b": ["run a"]]
        XCTAssertThrowsError(try commands.validateOperationalMemory(memory))
        memory.workflows = ["deploy": ["rm -rf /tmp/project"]]
        XCTAssertThrowsError(try commands.validateOperationalMemory(memory))
        memory.workflows = ["deploy": ["open nonexistent app"]]
        XCTAssertThrowsError(try commands.validateOperationalMemory(memory))
        memory.workflows = [:]; memory.approvedCommands = ["close everything": "quit Notes"]
        XCTAssertThrowsError(try commands.validateOperationalMemory(memory))
    }
    func testConsequentialWorkflowStillRequiresConfirmation() async throws {
        _ = try configured(); var value = store.memory
        value.workflows["finish work"] = ["quit Notes", "open browser"]
        try store.save(value)
        let system = System(), subject = agent(system); subject.begin()
        await finish(subject, "finish work")
        XCTAssertTrue(system.calls.isEmpty); XCTAssertNotNil(subject.snapshot.confirmation)
        XCTAssertFalse(subject.snapshot.timings.contains { $0.kind == .actionStart })
        await subject.confirm()
        XCTAssertEqual(system.calls.map(\.toolID), [.quitApplication, .openApplication])
        XCTAssertThrowsError(try subject.approveSuccessfulCommand(as: "goodbye"))
    }
    func testOnlyExplicitVerifiedSuccessCanBecomeMapping() async throws {
        _ = try configured(); let system = System(), subject = agent(system); subject.begin()
        await finish(subject, "open Notes")
        XCTAssertTrue(store.memory.approvedCommands.isEmpty)
        try subject.approveSuccessfulCommand(as: "workspace")
        XCTAssertEqual(store.memory.approvedCommands["workspace"], "open Notes")
        subject.begin(); await finish(subject, "workspace")
        XCTAssertEqual(system.calls.count, 2)
    }
    func testConfirmationPolicyIsFrozenForSessionAndNeverWeakensConsequentialTools() async throws {
        _ = try configured(); var value = store.memory; value.confirmAllActions = true; try store.save(value)
        let system = System(), subject = agent(system); subject.begin()
        value.confirmAllActions = false; try store.save(value)
        await finish(subject, "open Notes")
        XCTAssertTrue(system.calls.isEmpty); XCTAssertNotNil(subject.snapshot.confirmation)
        await subject.confirm(); XCTAssertEqual(system.calls.count, 1)
        subject.begin(); await finish(subject, "quit Notes")
        XCTAssertNotNil(subject.snapshot.confirmation); XCTAssertEqual(system.calls.count, 1)
    }
    func testNewSessionDrainsOldNativeOwnerEvenWithoutExplicitWait() async throws {
        let system = System(), started = expectation(description: "started")
        system.delay = true; system.onCall = { started.fulfill() }
        let subject = agent(system); subject.begin()
        let first = Task { await self.finish(subject, "open Notes") }
        await fulfillment(of: [started], timeout: 1)
        subject.begin(); system.delay = false; system.onCall = nil
        await finish(subject, "open Safari"); await first.value
        XCTAssertEqual(system.calls.count, 2)
        XCTAssertEqual(subject.snapshot.actions.last?.phase, .completed)
        await subject.cancelAndWait()
    }
    func testCancelledCoordinatorAndExecutorReleaseAfterDraining() async throws {
        weak var released: VoiceAgentCoordinator?
        do {
            let system = System(), subject = agent(system)
            released = subject; subject.begin(); await finish(subject, "open Notes"); await subject.cancelAndWait()
        }
        await Task.yield()
        XCTAssertNil(released)
    }
    func testCorruptMemoryCannotReusePreviousAliases() async throws {
        _ = try configured()
        try Data("bad JSON".utf8).write(to: store.fileURL)
        let system = System(), subject = agent(system); subject.begin()
        await finish(subject, "open my editor")
        XCTAssertTrue(system.calls.isEmpty); XCTAssertTrue(subject.snapshot.isCancelled)
    }
    func testASRHeaderPunctuationAndArticlesPreserveExactPayload() throws {
        XCTAssertEqual(NativeCommandParser.parse("Append to current note, This is exact.")?.arguments, .currentNote("This is exact."))
        XCTAssertEqual(NativeCommandParser.parse("Create a reminder. Review benchmark")?.arguments, .reminder(title: "Review benchmark"))
        XCTAssertEqual(NativeCommandParser.parse("Write current note: Keep commas, periods. And open Safari")?.arguments,
                       .currentNote("Keep commas, periods. And open Safari"))
        XCTAssertNil(NativeCommandParser.parse("Describe how to create a reminder. Review benchmark"))
    }
    func testBenchmarkTenScenariosRepeatedWithDuplicatePartialNotifications() async throws {
        let commands = try configured()
        var results: [AgentBenchmarkResult] = []
        for _ in 0..<5 {
            for scenario in AgentBenchmarkScenario.daily {
                let system = System(), subject = agent(system, commands: commands)
                subject.begin()
                // ASR replay benchmark: these latencies measure injected event delivery,
                // not microphone/STT model inference. Native effects are test doubles.
                for _ in 0..<5 { subject.receive(PartialTranscript(text: scenario.instruction)); await subject.waitForPendingWork() }
                await finish(subject, scenario.instruction)
                if subject.snapshot.confirmation != nil { await subject.confirm() }
                await subject.waitForPendingWork()
                let expected = try scenario.expectedActions(commands: commands)
                let result = AgentBenchmarkResult(scenario: scenario.id, mode: "scripted-ASR-mock-native", snapshot: subject.snapshot, expected: expected)
                XCTAssertEqual(result.duplicateActionRate, 0); XCTAssertEqual(result.incorrectActionRate, 0)
                XCTAssertEqual(result.missingActions, 0); XCTAssertEqual(result.failedActions, 0)
                XCTAssertNotNil(result.partialSTTMilliseconds); XCTAssertNotNil(result.decisionMilliseconds)
                XCTAssertNotNil(result.firstActionMilliseconds); XCTAssertNotNil(result.completionMilliseconds)
                XCTAssertEqual(system.calls.map(\.toolID), expected.map(\.toolID))
                if scenario.id == 3 { XCTAssertEqual(system.calls[0].arguments, .currentNote("This is my dictated benchmark text.")) }
                if scenario.id == 9 { XCTAssertEqual(system.calls[0].arguments, .reminder(title: "Review LocalFlow benchmark")) }
                results.append(result)
                await subject.cancelAndWait()
            }
        }
        if let path = ProcessInfo.processInfo.environment["LOCALFLOW_BENCHMARK_OUTPUT"] {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(results).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
    func testBenchmarkRatesCountUnexpectedAndDuplicateDeliveriesAndMissingSlots() {
        let action = AgentAction(toolID: .copyText, arguments: .text("expected"))
        var snapshot = VoiceAgentSnapshot()
        for action in [action, action, AgentAction(toolID: .copyText, arguments: .text("wrong"))] {
            var record = AgentActionRecord(id: action.id, segment: 0, action: action)
            record.performed = true; record.verification = .verified; record.phases.append(.completed)
            snapshot.actions.append(record)
        }
        let result = AgentBenchmarkResult(scenario: 1, mode: "test", snapshot: snapshot, expected: [action, AgentAction(toolID: .mute, arguments: .none)])
        XCTAssertEqual(result.duplicateActionRate, 1.0 / 3.0)
        XCTAssertEqual(result.incorrectActionRate, 1.0 / 3.0)
        XCTAssertEqual(result.missingActions, 1); XCTAssertNil(result.partialSTTMilliseconds)
    }
}
