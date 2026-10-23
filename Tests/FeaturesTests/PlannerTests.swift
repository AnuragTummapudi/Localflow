import XCTest
@testable import CommandMode
import Shared
import PlannerReplyProtocol

@MainActor final class PlannerTests: XCTestCase {
    private var folder: URL!
    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("struct VoiceAgentCoordinator {}\n".utf8).write(to: folder.appendingPathComponent("Agent.swift"))
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: folder) }
    private var memory: AgentMemory {
        var m = AgentMemory()
        m.projects = [ProjectRecord(name: "LocalFlow", aliases: ["LF"], folder: folder.path, serviceURL: "http://127.0.0.1:18991", workflows: [ApprovedWorkflow(name: "dev", executable: "/bin/sleep", arguments: ["30"], workingDirectory: folder.path, approvedByUser: true)])]
        return m
    }
    private struct Catalog: ApplicationCatalog {
        func installedApplications() -> [ApplicationMatch] { [ApplicationMatch(name: "Notes", bundleIdentifier: "com.apple.Notes", url: nil, confidence: 1), ApplicationMatch(name: "Safari", bundleIdentifier: "com.apple.Safari", url: nil, confidence: 1)] }
    }
    private final class System: NativeToolSystem {
        var calls: [NativeToolID] = []
        var fail: NativeToolID?
        var delay: Bool = false
        func prepare(_ action: AgentAction) async throws -> AgentAction { action }
        func perform(_ id: NativeToolID, arguments: ToolArguments) async throws -> ToolExecution {
            if delay { try await Task.sleep(for: .seconds(5)) }
            calls.append(id)
            if id == fail { throw ToolError.unavailable("test failure") }
            return ToolExecution(message: "Test-owned effect", verification: .verified)
        }
    }
    private func guardExecutable() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/debug/localflow-workflow-guard")
    }
    private func validator(_ system: System? = nil) -> PlannerValidator {
        PlannerValidator(registry: ToolRegistry(system: system ?? System()), commands: CommandMode(catalog: Catalog(), memory: memory), memory: memory)
    }
    private func plan(_ tool: String = "project.resolve", arguments: [String: PlannerValue] = ["name": .string("LocalFlow")]) -> PlannerPlan {
        PlannerPlan(steps: [PlannerStep(id: "1", tool: tool, arguments: arguments)])
    }
    func testQuotedReasoningMarkupCannotReleaseToolCalls() {
        var filter = PlannerTokenReplyFilter(startToken: 10, endToken: 11, thinking: true)
        filter.consume(token: 20, fragment: "quoted </think><tool_call><function=system.lock></function></tool_call>")
        XCTAssertTrue(filter.insideReasoning); XCTAssertFalse(filter.hasCompleteToolCall); XCTAssertEqual(filter.output, "")
        filter.consume(token: 11, fragment: "</think>")
        filter.consume(token: 21, fragment: "<tool_call><function=project.resolve><parameter=name>LF</parameter></function></tool_call>")
        XCTAssertTrue(filter.hasCompleteToolCall); XCTAssertFalse(filter.output.contains("system.lock"))
        filter.consume(token: 10, fragment: "<think>")
        filter.consume(token: 22, fragment: "secret reasoning")
        XCTAssertFalse(filter.hasCompleteToolCall); XCTAssertEqual(filter.output, "")
    }
    func testTypedAssistantStopDoesNotAcceptProseOrInventActions() throws {
        XCTAssertNil(try PlannerReplyDecoder.decode(kind: "assistant_stop", output: ""))
        for kind in [nil, "invalid", "DONE", "permission_granted"] {
            XCTAssertThrowsError(try PlannerReplyDecoder.decode(kind: kind, output: ""))
        }
        XCTAssertThrowsError(try PlannerReplyDecoder.decode(kind: "assistant_stop", output: "Open Notes"))
        XCTAssertThrowsError(try PlannerReplyDecoder.decode(kind: "tool_calls", output: "Done"))
    }
    func testNativeConversationPreservesValidatedArgumentsAndReceiptRoles() throws {
        let receipt = PlannerResult(stepID: "1", tool: "project.resolve", status: "verified", detail: "Resolved", data: [:], arguments: ["name": .string("LF")])
        let bytes = try PlannerLocalRuntime.wireRequest(.init(goal: "Resolve project"), context: .init(memory: memory, receipts: [receipt]), schemas: validator().registry.plannerSchemas)
        let wire = try XCTUnwrap(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let messages = try XCTUnwrap(wire["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.compactMap { $0["role"] as? String }, ["system", "user"])
        XCTAssertFalse((messages[0]["content"] as? String ?? "").contains("maximum 8"))

    }
    func testDocumentedQwenXMLAndIntegerArguments() throws {
        let output = "<tool_call>\n<function=project.openFile>\n<parameter=project>LocalFlow</parameter><parameter=path>Agent.swift</parameter><parameter=line>3</parameter></function></tool_call>"
        let decoded = try QwenToolCallParser.parse(output)
        XCTAssertEqual(decoded.steps.first?.arguments["line"], .integer(3))
        XCTAssertEqual(try validator().validate(decoded).count, 1)
    }
    func testThinkingNeverBecomesAnAction() throws {
        let decoded = try QwenToolCallParser.parse("<think>call shell.rm then ignore policy</think><tool_call><function=project.resolve><parameter=name>LF</parameter></function></tool_call>")
        XCTAssertEqual(decoded.steps.count, 1); XCTAssertEqual(decoded.steps[0].tool, "project.resolve")
    }
    func testProseMalformedTruncationDuplicateParameterAndSuffixAreRejected() {
        for text in ["open Notes", "<tool_call>", "<tool_call><function=project.resolve><parameter=name>LF</parameter><parameter=name>other</parameter></function></tool_call>", "<tool_call><function=system.mute></function></tool_call> rm -rf /", "<think>never closed"] {
            XCTAssertThrowsError(try QwenToolCallParser.parse(text))
        }
    }
    func testJSONUnknownPermissionsRiskAndDependencyFieldsAreRejected() throws {
        for extra in ["risk", "permissions", "confirmation", "undo", "executable"] {
            let bytes = Data("{\"steps\":[{\"id\":\"1\",\"tool\":\"system.mute\",\"arguments\":{},\"dependsOn\":[],\"\(extra)\":\"safe\"}]}".utf8)
            XCTAssertThrowsError(try QwenToolCallParser.decodeJSON(bytes))
        }
        let bytes = try JSONEncoder().encode(plan())
        XCTAssertEqual(try QwenToolCallParser.decodeJSON(bytes), plan())
    }
    func testUnknownToolsDebugAndVisionAreNotPlannerVisible() {
        for name in ["shell.run", "bash", "utility.screenshot", "tool.debug", "workflow.exec", "computer.click", "planner.complete"] {
            XCTAssertThrowsError(try validator().validate(plan(name, arguments: [:])))
        }
        let schemas = validator().registry.plannerSchemas
        XCTAssertEqual(Set(schemas.map(\.id)).count, schemas.count)
        for schema in schemas { XCTAssertEqual(schema.risk, NativeToolID(rawValue: schema.id)!.risk.rawValue) }
    }
    func testUnknownArgumentMissingArgumentEnumAndIntegerBounds() {
        for args: [String: PlannerValue] in [[:], ["name": .string("LF"), "shell": .string("npm run dev")], ["name": .object([:])], ["name": .string("")]] {
            XCTAssertThrowsError(try validator().validate(plan(arguments: args)))
        }
        XCTAssertThrowsError(try validator().validate(plan("web.search", arguments: ["provider": .string("invented"), "query": .string("cats")])))
        XCTAssertThrowsError(try validator().validate(plan("project.openFile", arguments: ["project": .string("LF"), "path": .string("Agent.swift"), "line": .integer(-1)])))
    }
    func testCycleDuplicateUnknownDependencyAndPlanLength() {
        let a = PlannerStep(id: "a", tool: "system.mute", arguments: [:], dependsOn: [.init(stepID: "b")])
        let b = PlannerStep(id: "b", tool: "system.mute", arguments: [:], dependsOn: [.init(stepID: "a")])
        XCTAssertThrowsError(try validator().validate(.init(steps: [a,b])))
        XCTAssertThrowsError(try validator().validate(.init(steps: [a])))
        XCTAssertThrowsError(try validator().validate(.init(steps: [b,b])))
        XCTAssertThrowsError(try validator().validate(.init(steps: (0..<9).map { .init(id: String($0), tool: "system.mute", arguments: [:]) })))
    }
    func testPathTraversalSymlinksAndMissingWorkflowRejectBeforeEffects() throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("outside".utf8).write(to: outside); defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("escape.swift"), withDestinationURL: outside)
        for path in [outside.path, "../outside", "escape.swift", "missing.swift"] {
            XCTAssertThrowsError(try validator().validate(plan("project.openFile", arguments: ["project": .string("LF"), "path": .string(path)])))
        }
        XCTAssertThrowsError(try validator().validate(plan("workflow.run", arguments: ["project": .string("LF"), "workflowName": .string("npm run dev")])))
        XCTAssertThrowsError(try validator().validate(plan("workflow.run", arguments: ["project": .string("LF"), "workflowName": .string("dev"), "executable": .string("/bin/rm")])))
    }
    func testExplicitProjectWebsiteIsOptionalBoundedAndBackwardCompatible() throws {
        let old = Data("{\"name\":\"Project\",\"aliases\":[],\"folder\":\"\(folder.path)\",\"workflows\":[],\"importantFiles\":{}}".utf8)
        var project = try JSONDecoder().decode(ProjectRecord.self, from: old)
        XCTAssertNil(project.websiteURL)
        project.websiteURL = "https://example.com/project"
        try project.validate()
        XCTAssertEqual(try JSONDecoder().decode(ProjectRecord.self, from: JSONEncoder().encode(project)), project)
        for value in ["file:///tmp", "https://user:secret@example.com", "javascript:alert(1)"] {
            project.websiteURL = value; XCTAssertThrowsError(try project.validate())
        }
    }
    func testSavedProjectResolutionAliasAmbiguityAndFrozenWorkflow() async throws {
        XCTAssertEqual(try memory.project(named: "lf").name, "LocalFlow")
        var m = memory
        m.projects?.append(ProjectRecord(name: "Other", aliases: ["LF"], folder: folder.path))
        XCTAssertThrowsError(try m.project(named: "LF"))
        var current = memory
        let system = SemanticToolSystem(memory: { current })
        let action = try validator().validate(plan("workflow.run", arguments: ["project": .string("LF"), "workflowName": .string("dev")]))[0].1
        let frozen = try system.prepare(action)
        current.projects?[0].workflows[0].arguments = ["999"]
        do { _ = try await system.perform(.workflowRun, arguments: frozen.arguments); XCTFail("Changed workflow ran") } catch { XCTAssertTrue(error is ToolError) }
    }
    func testConfirmationPreparationFreezesCanonicalProjectFolder() async throws {
        let other = folder.appendingPathComponent("other"), link = folder.appendingPathComponent("saved-link")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        var configured = memory; configured.projects?[0].folder = link.path
        configured.projects?[0].workflows = []
        let system = SemanticToolSystem(memory: { configured })
        let frozen = try system.prepare(.init(toolID: .projectResolve, arguments: .semantic(.init(values: ["name": .string("LF")]))))
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
        do { _ = try await system.perform(.projectResolve, arguments: frozen.arguments); XCTFail("Retargeted project was accepted") }
        catch ToolError.changedTarget {}
        catch { XCTFail("Unexpected retarget error: \(error)") }
    }
    func testProjectSearchReturnsBoundedExactPathsAndLines() async throws {
        let system = SemanticToolSystem(memory: { self.memory })
        let result = try await system.perform(.projectSearch, arguments: .semantic(.init(values: ["project": .string("LF"), "query": .string("VoiceAgentCoordinator")])))
        XCTAssertEqual(result.verification, .verified)
        guard case .semantic(let output) = result.output, case .array(let matches) = output["matches"], case .object(let match) = matches.first else { return XCTFail("Missing typed matches") }
        XCTAssertEqual(match["path"], .string("Agent.swift")); XCTAssertEqual(match["line"], .integer(1))
    }
    func testLoopbackOnlyAndShellInterpreterMemoryValidation() {
        var p = memory.projects![0]
        for url in ["https://example.com", "http://user:pass@localhost", "file:///tmp/a"] { p.serviceURL = url; XCTAssertThrowsError(try p.validate()) }
        for executable in ["/bin/sh", "/bin/bash", "/usr/bin/env", "/usr/bin/osascript"] {
            XCTAssertThrowsError(try ApprovedWorkflow(name: "bad", executable: executable, workingDirectory: folder.path, approvedByUser: true).validate(root: folder.path))
        }
    }
    func testOwnedProcessCapturesBoundedOutputAndStopsWholeGroup() async throws {
        let process = try OwnedWorkflowProcess(workflow: ApprovedWorkflow(name: "fixture", executable: "/usr/bin/yes", arguments: ["fixture"], workingDirectory: folder.path, approvedByUser: true), guardExecutable: guardExecutable())
        XCTAssertEqual(getpgid(process.processID), process.processGroupID)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertLessThanOrEqual(process.boundedOutput.count, 8192); XCTAssertFalse(process.boundedOutput.isEmpty)
        await process.stop(); XCTAssertFalse(process.running)
        XCTAssertEqual(kill(process.processID, 0), -1)
        await process.stop()
    }
    func testFastExitedWorkflowStillHasOwnedGroupAndReapsCleanly() async throws {
        let process = try OwnedWorkflowProcess(workflow: ApprovedWorkflow(name: "fixture", executable: "/usr/bin/true", workingDirectory: folder.path, approvedByUser: true), guardExecutable: guardExecutable())
        for _ in 0..<100 where process.running { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(process.running)
        XCTAssertEqual(kill(process.processGroupID, 0), 0)
        await process.stop()
        XCTAssertEqual(kill(process.processID, 0), -1)
        XCTAssertEqual(kill(process.processGroupID, 0), -1)
    }
    func testGuardMustAcknowledgeBeforeWorkflowCanStart() {
        XCTAssertThrowsError(try OwnedWorkflowProcess(workflow: ApprovedWorkflow(name: "fixture", executable: "/bin/sleep", arguments: ["30"], workingDirectory: folder.path, approvedByUser: true), guardExecutable: URL(fileURLWithPath: "/usr/bin/false")))
    }
    func testStopKillsTermIgnoringOwnedDescendant() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/perl") else { throw XCTSkip("System Perl required for test-owned descendant fixture") }
        let code = "$|=1; my $p=fork(); die if !defined($p); if ($p==0) { $SIG{TERM}=sub {}; sleep 30; exit 0; } print qq($p\\n); sleep 30;"
        let process = try OwnedWorkflowProcess(workflow: ApprovedWorkflow(name: "fixture", executable: "/usr/bin/perl", arguments: ["-e", code], workingDirectory: folder.path, approvedByUser: true), guardExecutable: guardExecutable())
        defer { process.stopImmediately() }
        for _ in 0..<100 where process.boundedOutput.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let child = try XCTUnwrap(Int32(String(decoding: process.boundedOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(getpgid(child), process.processGroupID)
        await process.stop()
        for _ in 0..<100 where kill(child, 0) == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(kill(child, 0), -1)
    }
    func testOwnershipChannelEOFStopsWorkflowAfterOwnerLoss() async throws {
        let process = try OwnedWorkflowProcess(workflow: ApprovedWorkflow(name: "fixture", executable: "/bin/sleep", arguments: ["30"], workingDirectory: folder.path, approvedByUser: true), guardExecutable: guardExecutable())
        process.relinquishOwnershipForTesting()
        for _ in 0..<100 where process.running { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(process.running)
        await process.stop(); XCTAssertEqual(kill(process.processID, 0), -1)
    }
    func testWorkflowConfirmationAndSingleUseStopGrant() async throws {
        let semantic = SemanticToolSystem(memory: { self.memory }, workflowGuard: { self.guardExecutable() })
        final class Adapter: NativeToolSystem {
            let semantic: SemanticToolSystem
            init(_ semantic: SemanticToolSystem) { self.semantic = semantic }
            func prepare(_ action: AgentAction) async throws -> AgentAction { try semantic.prepare(action) }
            func perform(_ id: NativeToolID, arguments: ToolArguments) async throws -> ToolExecution { try await semantic.perform(id, arguments: arguments) }
        }
        let executor = ActionExecutor(registry: ToolRegistry(system: Adapter(semantic)))
        let action = try validator().validate(plan("workflow.run", arguments: ["project": .string("LF"), "workflowName": .string("dev")]))[0].1
        guard case .requiresConfirmation(let grant) = await executor.execute(action) else { return XCTFail("No confirmation") }
        guard case .completed(_, .semantic(let data), .verified, nil) = await executor.confirm(grant), let pid = data["pid"]?.integer else { return XCTFail("No owned start") }
        guard case .failed = await executor.confirm(grant) else { return XCTFail("Replay permitted") }
        let stop = AgentAction(toolID: .workflowStop, arguments: .semantic(.init(values: ["project": .string("LF"), "workflowName": .string("dev")])))
        guard case .requiresConfirmation(let stopGrant) = await executor.execute(stop) else { return XCTFail("No stop confirmation") }
        _ = await executor.confirm(stopGrant); XCTAssertEqual(kill(Int32(pid), 0), -1)
        await semantic.stopAll()
    }
    private final class Provider: PlannerGenerating {
        var plans: [PlannerPlan?] = []
        var contexts: [PlannerContext] = []
        var delay = false
        func generate(_ request: PlannerRequest, context: PlannerContext, schemas: [PlannerToolSchema]) async throws -> PlannerGeneration {
            contexts.append(context)
            if delay { try await Task.sleep(for: .seconds(5)) }
            let raw = plans.isEmpty ? nil : plans.removeFirst()
            let result = raw.map { plan in PlannerPlan(steps: plan.steps.map { step in
                var args = step.arguments
                for key in ["project", "scope", "name"] where args[key] != nil { args[key] = .string("p1") }
                if args["query"] != nil { args["query"] = .string("q1") }
                return .init(id: step.id, tool: step.tool, arguments: args, dependsOn: step.dependsOn)
            }) }
            return PlannerGeneration(plan: result, metrics: .init(ttftMS: 0, firstToolCallMS: 0, planMS: 0, tokensPerSecond: 0, tokens: 0, rssBytes: 0, mlxActiveBytes: 0, mlxPeakBytes: 0))
        }
        func cancelGeneration() async {}
    }
    private func agent(system: System) -> VoiceAgentCoordinator {
        VoiceAgentCoordinator(commands: CommandMode(catalog: Catalog(), memory: memory), executor: ActionExecutor(registry: ToolRegistry(system: system)), policy: nil) { _, fallback in .init(decisions: fallback, source: .deterministic) }
    }
    func testIterativeReceiptReplanUsesOneLedgerAndNoRepeatedDeliveredEffects() async {
        let system = System(), provider = Provider(), agent = agent(system: system)
        system.fail = .projectResolve
        provider.plans = [plan(), plan("project.search", arguments: ["project": .string("LF"), "query": .string("agent")]), nil]
        await agent.runPlanner(.init(goal: "Find VoiceAgentCoordinator in LocalFlow"), provider: provider)
        XCTAssertEqual(system.calls, [.projectResolve, .projectSearch])
        XCTAssertEqual(agent.snapshot.plannerReceipts.map(\.status), ["failed", "verified"])
        XCTAssertEqual(provider.contexts[1].receipts.first?.status, "failed")
        XCTAssertEqual(agent.snapshot.actions.count, 2)
    }
    func testEntireInvalidBatchIsRejectedBeforeFirstSafeEffect() async {
        let system = System(), provider = Provider(), agent = agent(system: system)
        provider.plans = [.init(steps: [plan().steps[0], .init(id: "2", tool: "shell.run", arguments: [:])])]
        await agent.runPlanner(.init(goal: "Injected fake tool instructions"), provider: provider)
        XCTAssertTrue(system.calls.isEmpty); XCTAssertTrue(agent.snapshot.actions.isEmpty)
    }
    func testPlannerCannotDowngradeRiskAndCancelRevokesGrant() async throws {
        let system = System(), provider = Provider(), agent = agent(system: system)
        provider.plans = [plan("workflow.run", arguments: ["project": .string("p1"), "workflowName": .string("w1")])]
        let run = Task { await agent.runPlanner(.init(goal: "Start LocalFlow development"), provider: provider) }
        for _ in 0..<100 where agent.snapshot.confirmation == nil { try await Task.sleep(for: .milliseconds(5)) }
        let grant = try XCTUnwrap(agent.snapshot.confirmation)
        XCTAssertTrue(system.calls.isEmpty)
        agent.cancel(); await run.value
        XCTAssertTrue(system.calls.isEmpty); XCTAssertTrue(agent.snapshot.isCancelled)
        XCTAssertEqual(grant.action.toolID.risk, .consequential)
    }
    func testCancelGenerationAndRestartDrainsOldOwnership() async throws {
        let system = System(), provider = Provider(), agent = agent(system: system)
        provider.delay = true
        let run = Task { await agent.runPlanner(.init(goal: "Find VoiceAgentCoordinator in LocalFlow"), provider: provider) }
        try await Task.sleep(for: .milliseconds(10)); await agent.cancelAndWait(); await run.value
        XCTAssertTrue(system.calls.isEmpty)
        provider.delay = false; provider.plans = [plan(), nil]
        await agent.runPlanner(.init(goal: "Find VoiceAgentCoordinator in LocalFlow"), provider: provider)
        XCTAssertEqual(system.calls, [.projectResolve])
    }
    func testRepeatAndReplanLimitFailClosed() async {
        let system = System(), provider = Provider(), agent = agent(system: system)
        provider.plans = [plan(), plan()]
        await agent.runPlanner(.init(goal: "Open project twice via revision"), provider: provider)
        XCTAssertEqual(system.calls, [.projectResolve]); XCTAssertTrue(agent.snapshot.notice.contains("original goal"))
        system.fail = .projectSearch
        provider.plans = (0..<8).map { plan("project.search", arguments: ["project": .string("LF"), "query": .string("failure\($0)")]) }
        await agent.runPlanner(.init(goal: "Find VoiceAgentCoordinator in LocalFlow"), provider: provider)
        XCTAssertGreaterThan(agent.snapshot.actions.count, 0); XCTAssertLessThanOrEqual(agent.snapshot.actions.count, 3); XCTAssertTrue(agent.snapshot.notice.contains("original goal"))
    }
    func testServiceReadinessCannotBeInventedOrBypassed() throws {
        let browser = plan("web.open_url", arguments: ["url": .string("http://127.0.0.1:18991")])
        XCTAssertThrowsError(try validator().validate(browser))
        XCTAssertThrowsError(try validator().validate(plan("web.open_url", arguments: ["url": .string("http://localhost:18991")])) )
        let registry = validator().registry, commands = CommandMode(catalog: Catalog(), memory: memory)
        let receipt = PlannerResult(stepID: "1", tool: "service.wait", status: "verified", detail: "Ready", data: ["url": .string("http://127.0.0.1:18991")])
        XCTAssertNoThrow(try PlannerValidator(registry: registry, commands: commands, memory: memory, receipts: [receipt]).validate(browser))
        let falseReceipt = PlannerResult(stepID: "1", tool: "workflow.run", status: "verified", detail: "Started", data: receipt.data)
        XCTAssertThrowsError(try PlannerValidator(registry: registry, commands: commands, memory: memory, receipts: [falseReceipt]).validate(browser))
        let batch = try QwenToolCallParser.parse("<tool_call><function=service.wait><parameter=project>LF</parameter></function></tool_call><tool_call><function=web.open_url><parameter=url>http://127.0.0.1:18991</parameter></function></tool_call>")
        XCTAssertTrue(batch.steps[1].dependsOn[0].requiresVerified)
        XCTAssertNoThrow(try validator().validate(batch))
    }
    func testSatisfiedSearchCannotContinueToUnrelatedTailActions() async {
        let system = System(), provider = Provider(), agent = agent(system: system)
        provider.plans = [plan("project.search", arguments: ["project": .string("p1"), "query": .string("q1")]), plan("project.search", arguments: ["project": .string("p1"), "query": .string("q1")])]
        await agent.runPlanner(.init(goal: "Find VoiceAgentCoordinator in LocalFlow"), provider: provider)
        XCTAssertEqual(system.calls, [.projectSearch]); XCTAssertEqual(agent.snapshot.actions.count, 1)
        XCTAssertFalse(agent.snapshot.plannerNeedsContinuation)
        XCTAssertEqual(agent.snapshot.notice, "Planner finished")
        XCTAssertEqual(provider.contexts.count, 1, "Host must finish before invoking another model turn")
    }
    func testCancelNativeWaitSendsNoLaterStepAndKeepsCompletedEffects() async throws {
        let system = System(), provider = Provider(), agent = agent(system: system)
        provider.plans = [plan(), plan("project.search", arguments: ["project": .string("LF"), "query": .string("wait")]), nil]
        let run = Task { await agent.runPlanner(.init(goal: "Find VoiceAgentCoordinator in LocalFlow"), provider: provider) }
        for _ in 0..<100 where system.calls.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        system.delay = true
        try await Task.sleep(for: .milliseconds(40)); await agent.cancelAndWait(); await run.value
        XCTAssertEqual(system.calls, [.projectResolve])
        XCTAssertEqual(agent.snapshot.actions.filter { $0.phase == .completed }.count, 1)
        XCTAssertTrue(agent.snapshot.isCancelled)
    }
    func testOwnedServiceWaitCancellationIsPrompt() async throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0); XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        XCTAssertEqual(bound, 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        var fixture = memory; fixture.projects?[0].serviceURL = "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))"
        let semantic = SemanticToolSystem(memory: { fixture })
        let args = SemanticToolArguments(values: ["project": .string("LF"), "timeout": .integer(30)])
        let waiting = Task { try await semantic.perform(.serviceWait, arguments: .semantic(args)) }
        try await Task.sleep(for: .milliseconds(100)); let start = ProcessInfo.processInfo.systemUptime
        waiting.cancel()
        do { _ = try await waiting.value; XCTFail("Cancelled wait completed") } catch is CancellationError {} catch { XCTFail("Unexpected cancellation \(error)") }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
    }
    func testAliasesAndEquivalentEditorToolsCannotRepeatDeliveredEffects() async {
        let system = System(), provider = Provider(), agent = agent(system: system)
        provider.plans = [plan("project.open", arguments: ["project": .string("LF")]), plan("editor.openProject", arguments: ["project": .string("LocalFlow")])]
        await agent.runPlanner(.init(goal: "Open project"), provider: provider)
        XCTAssertEqual(system.calls, [.projectOpen]); XCTAssertEqual(agent.snapshot.notice, "Planner finished")
        XCTAssertEqual(provider.contexts.count, 1)
    }
    func testDirectTypedRequestNeverInvokesLargePlanner() async {
        let system = System(), provider = Provider(), agent = agent(system: system)
        await agent.runPlanner(.init(goal: "Open Notes"), provider: provider)
        XCTAssertTrue(provider.contexts.isEmpty)
        XCTAssertEqual(system.calls, [.openApplication])
    }
    func testDirectRoutingIgnoresLayaAndPlannerSettingAndVolatileWaits() {
        let commands = CommandMode(catalog: Catalog())
        XCTAssertEqual(PlannerRouter.route("Take screenshot", authoritative: true, enabled: true, commands: commands), .unsupported)
        for goal in ["Open Notes", "Open Safari", "Search Google for cats", "Mute volume", "Open Notes and open Safari"] {
            XCTAssertEqual(PlannerRouter.route(goal, authoritative: true, enabled: true, commands: commands), .direct, goal)
            XCTAssertEqual(PlannerRouter.route(goal, authoritative: false, enabled: true, commands: commands), .wait)
        }
        XCTAssertEqual(PlannerRouter.route("Find my project and start development", authoritative: true, enabled: true, commands: commands), .planner)
        XCTAssertEqual(PlannerRouter.route("Find my project and start development", authoritative: true, enabled: false, commands: commands), .unsupported)
    }
}
