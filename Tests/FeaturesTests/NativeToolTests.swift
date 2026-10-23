import AppKit
import XCTest
@testable import CommandMode
import TextInjection

private func required<Value>(_ value: Value?, file: StaticString = #filePath, line: UInt = #line) throws -> Value {
    try XCTUnwrap(value, file: file, line: line)
}

@MainActor
final class NativeToolTests: XCTestCase {
    private final class System: NativeToolSystem {
        var calls: [(NativeToolID, ToolArguments)] = []
        var preparations: [AgentAction] = []
        var prepareBody: ((AgentAction) async throws -> AgentAction)?
        var performBody: ((NativeToolID, ToolArguments) async throws -> ToolExecution)?
        func prepare(_ action: AgentAction) async throws -> AgentAction {
            preparations.append(action)
            return try await prepareBody?(action) ?? action
        }
        func perform(_ id: NativeToolID, arguments: ToolArguments) async throws -> ToolExecution {
            calls.append((id, arguments))
            return try await performBody?(id, arguments) ?? ToolExecution(message: id.description, verification: .verified)
        }
    }
    private struct FailedVerifier: ActionVerifier {
        func verify(_ action: AgentAction, execution: ToolExecution) async -> ToolVerification { .failed("Readback differs") }
    }
    private let app = ApplicationMatch(name: "Notes", bundleIdentifier: "com.apple.Notes", url: nil, confidence: 1)
    private func arguments(_ id: NativeToolID) -> ToolArguments {
        switch id {
        case .uiObserve: return .semantic(.init(values: ["app": .string("com.apple.finder")]))
        case .uiFocus, .uiPress, .uiSelect, .uiRaiseWindow: return .semantic(.init(values: ["app": .string("com.apple.finder"), "elementID": .string("ax:test:1")]))
        case .uiSetValue: return .semantic(.init(values: ["app": .string("com.apple.finder"), "elementID": .string("ax:test:1"), "value": .string("test")]))
        case .uiScroll: return .semantic(.init(values: ["app": .string("com.apple.finder"), "elementID": .string("ax:test:1"), "direction": .string("down")]))
        case .openApplication, .focusApplication, .quitApplication: return .application(app)
        case .openURL: return .url(URL(string: "https://example.com")!)
        case .searchWeb, .searchProvider, .spotifySearch: return .search(query: "Swift & concurrency", provider: "google")
        case .openWebsite: return .website("github")
        case .typeText, .copyText: return .text("Literal `a<b` $HOME; \"quotes\".")
        case .replaceSelection: return .selection("Replacement")
        case .setVolume, .volumeUp, .volumeDown: return .volume(10)
        case .createReminder: return .reminder(title: "Send the design notes", notes: "LocalFlow", due: Date(timeIntervalSince1970: 1_800_000_000))
        case .createNote: return .note(title: "Meeting", body: "First line\nSecond line")
        case .appendNote, .writeNote, .renameNote: return .currentNote("Exact text.")
        case .spotifyTransport: return .spotify(.pause)
        case .screenshot: return .screenshot()
        case .revealFile: return .file(URL(fileURLWithPath: "/tmp/example"))
        case .mute, .unmute, .sleepDisplay, .lockMac: return .none
        case .projectResolve: return .semantic(.init(values: ["name": .string("LocalFlow")]))
        case .projectOpen, .editorOpenProject, .projectReveal, .workflowList, .serviceStatus, .serviceWait: return .semantic(.init(values: ["project": .string("LocalFlow")]))
        case .projectSearch, .editorRevealSymbol: return .semantic(.init(values: ["project": .string("LocalFlow"), "query": .string("agent")]))
        case .fileSearch: return .semantic(.init(values: ["scope": .string("LocalFlow"), "query": .string("agent")]))
        case .projectOpenFile, .editorOpenFile, .fileOpen, .fileReveal: return .semantic(.init(values: ["project": .string("LocalFlow"), "path": .string("agent.swift")]))
        case .workflowRun, .workflowStop: return .semantic(.init(values: ["project": .string("LocalFlow"), "workflowName": .string("dev")]))
        }
    }
    private func completed(_ result: ToolResult, file: StaticString = #filePath, line: UInt = #line) -> ToolUndoToken? {
        guard case .completed(_, _, _, let undo) = result else { XCTFail("Expected completion", file: file, line: line); return nil }
        return undo
    }
    private func challenge(_ result: ToolResult, file: StaticString = #filePath, line: UInt = #line) -> ToolConfirmation? {
        guard case .requiresConfirmation(let challenge) = result else { XCTFail("Expected explicit confirmation", file: file, line: line); return nil }
        return challenge
    }
    private func failed(_ result: ToolResult, file: StaticString = #filePath, line: UInt = #line) {
        guard case .failed = result else { XCTFail("Expected failure", file: file, line: line); return }
    }

#if DEBUG
    func testNativeNoteTitleReadbackPreservesEveryBodyByteAndRisk() {
        XCTAssertEqual(MacNativeToolSystem.noteTitleReplacementPlaintext("Old title\nExact BODY & trailing spaces  \n\n", title: "A <title> & B"),
            "A <title> & B\nExact BODY & trailing spaces  \n")
        XCTAssertEqual(NativeToolID.renameNote.risk, .consequential)
    }
    func testRealityGateConsumesRealConfirmationWithoutSendingEffectOrAllowingReplay() async throws {
        let system = System(), executor = ActionExecutor(registry: ToolRegistry(system: system))
        let result = await executor.execute(AgentAction(toolID: .lockMac, arguments: .none))
        let grant = try required(challenge(result))
        XCTAssertEqual(system.preparations.count, 1); XCTAssertTrue(system.calls.isEmpty)
        XCTAssertTrue(executor.validateConfirmationWithoutPerforming(grant))
        XCTAssertFalse(executor.validateConfirmationWithoutPerforming(grant))
        failed(await executor.confirm(grant))
        XCTAssertTrue(system.calls.isEmpty)
    }
    func testCancellingOldPreviewCannotRevokeNewNativeConfirmation() async throws {
        let system = System(), executor = ActionExecutor(registry: ToolRegistry(system: system))
        let old = try required(challenge(await executor.execute(AgentAction(toolID: .lockMac, arguments: .none))))
        let current = try required(challenge(await executor.execute(AgentAction(toolID: .quitApplication, arguments: .application(app)))))
        XCTAssertFalse(executor.cancelConfirmation(matching: old))
        XCTAssertTrue(executor.validateConfirmationWithoutPerforming(current))
        XCTAssertTrue(system.calls.isEmpty)
    }
#endif

    func testRegistryStableIDsDescriptionsAndAuthoritativeRiskForEveryTool() {
        let registry = ToolRegistry(system: System())
        XCTAssertEqual(registry.allTools.count, NativeToolID.allCases.count)
        XCTAssertEqual(Set(registry.allTools.map { $0.id.rawValue }).count, NativeToolID.allCases.count)
        for tool in registry.allTools {
            XCTAssertFalse(tool.description.isEmpty)
            XCTAssertEqual(tool.requiresConfirmation, tool.risk == .consequential)
            XCTAssertEqual(tool.risk, tool.id.risk)
            XCTAssertEqual(tool.argumentKind, tool.id.argumentKind)
        }
        for id in [NativeToolID.quitApplication, .replaceSelection, .writeNote, .appendNote, .renameNote, .lockMac, .sleepDisplay] {
            XCTAssertEqual(registry.tool(id).risk, .consequential)
        }
    }
    func testEveryProductionToolRoutesExactTypedArgumentsAndEnforcesRisk() async {
        for id in NativeToolID.allCases {
            let system = System(), action = AgentAction(toolID: id, arguments: arguments(id))
            let executor = ActionExecutor(registry: ToolRegistry(system: system))
            let result = await executor.execute(action)
            if id.risk == .consequential {
                XCTAssertTrue(system.calls.isEmpty, "\(id) ran before confirmation")
                if let prompt = challenge(result) { _ = completed(await executor.confirm(prompt)) }
            } else { _ = completed(result) }
            XCTAssertEqual(system.preparations, [action])
            XCTAssertEqual(system.calls.count, 1)
            XCTAssertEqual(system.calls.first?.0, id)
            XCTAssertEqual(system.calls.first?.1, action.arguments)
        }
    }
    func testInvalidAndCrossToolArgumentsNeverReachOS() async {
        let system = System(), executor = ActionExecutor(registry: ToolRegistry(system: system))
        let invalid: [(NativeToolID, ToolArguments)] = [
            (.setVolume, .volume(101)), (.setVolume, .volume(-1)), (.volumeUp, .volume(0)),
            (.openURL, .url(URL(string: "javascript:alert(1)")!)), (.openURL, .url(URL(fileURLWithPath: "/tmp/test"))),
            (.openURL, .url(URL(string: "https://user:secret@example.com")!)), (.quitApplication, .none),
            (.typeText, .text(" \n")), (.replaceSelection, .text("Do not paste without selection")),
            (.createNote, .note(title: "", body: "body")), (.createReminder, .reminder(title: "")),
            (.screenshot, .screenshot(destination: URL(fileURLWithPath: "/tmp/existing.pdf"))),
            (.revealFile, .file(URL(string: "https://example.com")!)), (.lockMac, .url(URL(string: "https://example.com")!))
        ]
        for (id, args) in invalid { failed(await executor.execute(AgentAction(toolID: id, arguments: args))) }
        XCTAssertTrue(system.calls.isEmpty)
        XCTAssertTrue(system.preparations.isEmpty)
    }
    func testFrozenSelectionConfirmationCannotBeReusedOrTamperedWith() async throws {
        let system = System(), executor = ActionExecutor(registry: ToolRegistry(system: system))
        let snapshot = SelectedTextSnapshot(requestID: UUID(), processIdentifier: 123, bundleIdentifier: "test.editor", text: "old", range: NSRange(location: 0, length: 3), method: .accessibility)
        system.prepareBody = { action in action.prepared(arguments: .selection("new", snapshot: snapshot)) }
        let prompt = try required(challenge(await executor.execute(AgentAction(toolID: .replaceSelection, arguments: .selection("new")))))
        let forged = ToolConfirmation(id: prompt.id, action: prompt.action.prepared(arguments: .selection("changed", snapshot: snapshot)))
        failed(await executor.confirm(forged))
        XCTAssertTrue(system.calls.isEmpty)
        _ = completed(await executor.confirm(prompt))
        XCTAssertEqual(system.calls.first?.1, .selection("new", snapshot: snapshot))
        failed(await executor.confirm(prompt))
        XCTAssertEqual(system.calls.count, 1)
    }
    func testCancelAndNewActionInvalidateConfirmation() async throws {
        let system = System(), executor = ActionExecutor(registry: ToolRegistry(system: system))
        let action = AgentAction(toolID: .quitApplication, arguments: .application(app))
        let cancelled = try required(challenge(await executor.execute(action)))
        executor.cancelConfirmation()
        failed(await executor.confirm(cancelled))
        let stale = try required(challenge(await executor.execute(action)))
        _ = completed(await executor.execute(AgentAction(toolID: .openURL, arguments: arguments(.openURL))))
        failed(await executor.confirm(stale))
        XCTAssertEqual(system.calls.count, 1)
        XCTAssertEqual(system.calls.first?.0, .openURL)
    }
    func testLowConfidenceCanRequireConfirmationEvenForSafeTool() async throws {
        let system = System(), executor = ActionExecutor(registry: ToolRegistry(system: system))
        let prompt = try required(challenge(await executor.execute(AgentAction(toolID: .openURL, arguments: arguments(.openURL)), requireConfirmation: true)))
        XCTAssertTrue(system.calls.isEmpty)
        _ = completed(await executor.confirm(prompt))
    }
    func testConfirmationExpiresBeforeExecution() async throws {
        var now = Date(timeIntervalSince1970: 10)
        let system = System(), executor = ActionExecutor(registry: ToolRegistry(system: system), now: { now })
        let prompt = try required(challenge(await executor.execute(AgentAction(toolID: .lockMac, arguments: .none))))
        now = now.addingTimeInterval(121)
        failed(await executor.confirm(prompt))
        XCTAssertTrue(system.calls.isEmpty)
    }
    func testVerifiedReversibleActionExposesSingleUseGuardedUndo() async throws {
        let system = System(), executor = ActionExecutor(registry: ToolRegistry(system: system))
        var undoCount = 0
        system.performBody = { _, _ in ToolExecution(message: "Copied", verification: .verified, undo: { undoCount += 1; return .verified }) }
        let token = try required(completed(await executor.execute(AgentAction(toolID: .copyText, arguments: .text("owned")))))
        _ = completed(await executor.undo(token))
        failed(await executor.undo(token))
        XCTAssertEqual(undoCount, 1)
    }
    func testUndoRefusesExternalChangesAndExpires() async throws {
        var changed = false, undoCount = 0, now = Date(timeIntervalSince1970: 10)
        let system = System(), executor = ActionExecutor(registry: ToolRegistry(system: system), now: { now })
        system.performBody = { _, _ in ToolExecution(message: "Volume set", verification: .verified, undo: {
            if changed { throw ToolError.changedTarget }; undoCount += 1; return .verified
        }) }
        let token = try required(completed(await executor.execute(AgentAction(toolID: .setVolume, arguments: .volume(20)))))
        changed = true
        failed(await executor.undo(token))
        XCTAssertEqual(undoCount, 0)
        let expired = try required(completed(await executor.execute(AgentAction(toolID: .setVolume, arguments: .volume(30)))))
        now = now.addingTimeInterval(61)
        failed(await executor.undo(expired))
        XCTAssertEqual(undoCount, 0)
    }
    func testUnverifiedOrNonReversibleActionsDoNotAdvertiseUndo() async throws {
        for (id, proof) in [(NativeToolID.copyText, ToolVerification.unverified("Sent only")), (.openURL, .verified), (.quitApplication, .verified)] {
            let system = System(), executor = ActionExecutor(registry: ToolRegistry(system: system))
            system.performBody = { _, _ in ToolExecution(message: "Sent", verification: proof, undo: { XCTFail("Unsupported undo called"); return .verified }) }
            var result = await executor.execute(AgentAction(toolID: id, arguments: arguments(id)))
            if case .requiresConfirmation(let prompt) = result { result = await executor.confirm(prompt) }
            XCTAssertNil(completed(result))
        }
    }
    func testFailuresAndVerificationFailureAreTruthful() async {
        let system = System()
        system.performBody = { _, _ in throw ToolError.permission("Accessibility") }
        failed(await ActionExecutor(registry: ToolRegistry(system: system)).execute(AgentAction(toolID: .copyText, arguments: .text("text"))))
        system.performBody = nil
        failed(await ActionExecutor(registry: ToolRegistry(system: system), verifier: FailedVerifier()).execute(AgentAction(toolID: .copyText, arguments: .text("text"))))
        system.prepareBody = { _ in throw ToolError.changedTarget }
        failed(await ActionExecutor(registry: ToolRegistry(system: system)).execute(AgentAction(toolID: .writeNote, arguments: .currentNote("text"))))
        XCTAssertEqual(system.calls.count, 2)
    }
    func testCancellationBeforeInferenceOrActionPreventsOSCalls() async {
        let system = System(), executor = ActionExecutor(registry: ToolRegistry(system: system))
        let task = Task { @MainActor in
            await Task.yield()
            return await executor.execute(AgentAction(toolID: .copyText, arguments: .text("text")))
        }
        task.cancel()
        guard case .cancelled = await task.value else { return XCTFail("Expected cancellation") }
        XCTAssertTrue(system.calls.isEmpty)
    }
    func testCancellationDuringPreparationCannotLeavePendingConfirmation() async {
        let system = System(), executor = ActionExecutor(registry: ToolRegistry(system: system))
        var release: CheckedContinuation<Void, Never>?
        system.prepareBody = { action in await withCheckedContinuation { release = $0 }; return action }
        let task = Task { await executor.execute(AgentAction(toolID: .lockMac, arguments: .none)) }
        while release == nil { await Task.yield() }
        executor.cancelConfirmation()
        release?.resume()
        guard case .cancelled = await task.value else { return XCTFail("Cancelled preparation left a challenge") }
        XCTAssertTrue(system.calls.isEmpty)
    }
    func testConcurrentRequestsAreRejectedWithoutDuplicateExecution() async {
        let system = System(), executor = ActionExecutor(registry: ToolRegistry(system: system))
        var release: CheckedContinuation<Void, Never>?
        system.performBody = { _, _ in await withCheckedContinuation { release = $0 }; return ToolExecution(message: "Copied", verification: .verified) }
        let action = AgentAction(toolID: .copyText, arguments: .text("text"))
        let first = Task { await executor.execute(action) }
        while release == nil { await Task.yield() }
        failed(await executor.execute(action))
        release?.resume()
        _ = completed(await first.value)
        XCTAssertEqual(system.calls.count, 1)
    }
    func testAllLegacyCommandMappingsUseTheRegistryPreservingResolvedURLs() async {
        let system = System(), executor = ActionExecutor(registry: ToolRegistry(system: system)), commands = CommandMode()
        let url = URL(string: "https://open.spotify.com/search/Midnight%20City")!
        let cases: [(CommandIntent, NativeToolID)] = [
            (.openApplication(app), .openApplication), (.switchToApplication(app), .focusApplication), (.quitApplication(app), .quitApplication),
            (.mute, .mute), (.unmute, .unmute), (.lockScreen, .lockMac), (.sleepDisplay, .sleepDisplay),
            (.spotifyControl(.next), .spotifyTransport), (.spotifySearchAndPlay(query: "Midnight City", url: url), .openURL),
            (.openURL(url), .openURL), (.searchWeb(query: "Midnight City", providerName: "Spotify", url: url), .openURL)
        ]
        for (intent, id) in cases {
            var result = await commands.execute(intent, using: executor)
            if case .requiresConfirmation(let prompt) = result { result = await executor.confirm(prompt) }
            _ = completed(result)
            XCTAssertEqual(system.calls.last?.0, id)
            XCTAssertEqual(system.calls.last?.1, intent.agentAction.arguments)
        }
    }
    func testConservativeParserPreservesPayloadAndLeavesAmbiguityToDictation() {
        let cases: [(String, NativeToolID, ToolArguments)] = [
            ("volume up.", .volumeUp, .volume(10)), ("set volume to 40 percent", .setVolume, .volume(40)),
            ("copy to clipboard `x.y` $HOME; rm -rf /", .copyText, .text("`x.y` $HOME; rm -rf /")),
            ("replace selected text with No, use Swift.", .replaceSelection, .selection("No, use Swift.")),
            ("type at cursor Hello!", .typeText, .text("Hello!")), ("create reminder Buy milk", .createReminder, .reminder(title: "Buy milk")),
            ("create note Meeting: Call Sam.", .createNote, .note(title: "Meeting", body: "Call Sam.")),
            ("append to current note Done.", .appendNote, .currentNote("Done.")), ("write current note Revised.", .writeNote, .currentNote("Revised.")),
            ("take a screenshot", .screenshot, .screenshot()), ("reveal in finder /tmp/file.txt", .revealFile, .file(URL(fileURLWithPath: "/tmp/file.txt")))
        ]
        for (text, id, args) in cases {
            guard case .execute(.nativeAction(let action)) = CommandMode().resolve(text) else { XCTFail(text); continue }
            XCTAssertEqual(action.toolID, id); XCTAssertEqual(action.arguments, args)
        }
        for text in ["I want volume up tomorrow", "set volume to 200", "set volume to maybe 40", "reveal in finder guessed file", "create note : body", "replace selected text with ", "run rm -rf /"] {
            XCTAssertNil(NativeCommandParser.parse(text), text)
        }
    }
    func testDeterministicWebsiteAndSearchExtractionEscapesExactQuery() throws {
        XCTAssertEqual(MacNativeToolSystem.websiteURL("github")?.host, "github.com")
        XCTAssertEqual(MacNativeToolSystem.websiteURL("example dot org")?.absoluteString, "https://example.org")
        XCTAssertNil(MacNativeToolSystem.websiteURL("Unknown invented site"))
        let query = "a&b = Swift / 日本語"
        let url = try required(SearchProviderRegistry.shared.findProvider(for: "google")?.searchURL(for: query))
        XCTAssertTrue(url.absoluteString.contains("%26"))
        XCTAssertTrue(url.absoluteString.contains("%3D"))
        XCTAssertEqual(MacNativeToolSystem.escapeHTML("<&\"text>"), "&lt;&amp;&quot;text&gt;")
        XCTAssertEqual(MacNativeToolSystem.htmlBody("<script>\nA&B"), "<div>&lt;script&gt;</div><div>A&amp;B</div>")
    }
    func testNewToolsKeepDeterministicDecisionRiskMapping() throws {
        for text in ["append to current note Hello", "replace selected text with Hello", "write current note Hello"] {
            let resolution = CommandMode().resolve(text)
            let decisions = try DeterministicDecisionEngine.decisions(for: resolution, isFinal: true)
            XCTAssertEqual(decisions.risk?.value, .consequential)
        }
        XCTAssertEqual(try DeterministicDecisionEngine.decisions(for: CommandMode().resolve("create reminder Call Sam"), isFinal: true).intent?.value, .reminderAction)
    }
}

/// Exercise real production audio/Notes methods through mocked Apple Event transport.
private actor Automation: NativeScriptCalling {
    var volume = 50
    var muted = false
    var externalAudioChange = false
    var noteChanged = false
    var noteID = "test-note"
    var html = ""
    var plaintext = ""
    var calls: [(NativeScriptRunner.Script, String, [NativeScriptRunner.Value])] = []
    func call(_ kind: NativeScriptRunner.Script, handler: String, arguments: [NativeScriptRunner.Value]) async throws -> [String] {
        calls.append((kind, handler, arguments))
        switch handler {
        case "readAudio": return [String(volume), String(muted)]
        case "writeAudio":
            guard arguments.count == 4, case .integer(let value) = arguments[0], case .boolean(let flag) = arguments[1],
                  case .boolean(let changeVolume) = arguments[2], case .boolean(let changeMuted) = arguments[3] else { throw ToolError.invalidArguments }
            if !externalAudioChange { if changeVolume { volume = value }; if changeMuted { muted = flag } }; return []
        case "createNote":
            guard case .text(let body) = arguments.first else { throw ToolError.invalidArguments }
            html = body; return [noteID, html, plaintext, "test-folder"]
        case "undoCreated":
            guard !noteChanged else { throw ToolError.changedTarget }
            XCTAssertEqual(arguments, [.text(noteID), .text(html), .text("test-folder")])
            return []
        case "updateCurrent":
            guard !noteChanged else { throw ToolError.changedTarget }
            return [noteID, "Native normalized HTML", plaintext]
        case "renameCurrent":
            guard !noteChanged, case .text(let name) = arguments[2] else { throw ToolError.changedTarget }
            return [noteID, plaintext, name]
        default: throw ToolError.invalidArguments
        }
    }
    func changeAudio(volume: Int, muted: Bool) { self.volume = volume; self.muted = muted }
    func refuseAudioWrites() { externalAudioChange = true }
    func setPlaintext(_ text: String) { plaintext = text }
    func changeNote() { noteChanged = true }
    func latestArguments() -> [NativeScriptRunner.Value]? { calls.last?.2 }
}

@MainActor final class NativeAutomationTests: XCTestCase {
    func testTrustedScriptsCompileAgainstInstalledNativeDictionariesWithoutExecuting() throws {
        for kind in [NativeScriptRunner.Script.audio, .notes] {
            let script = try required(NSAppleScript(source: NativeScriptRunner.source(for: kind)))
            var error: NSDictionary?
            XCTAssertTrue(script.compileAndReturnError(&error), "\(error ?? [:])")
            XCTAssertNil(error)
        }
    }

    func testAppleEventDescriptorsRoundTripLiteralPayloadWithoutAnyMacAction() throws {
        let literal = "\"; do shell script \"rm -rf /\"; --\n$HOME `quoted` 日本語"
        let script = try required(NSAppleScript(source: """
        on echoPayload(value, amount, flag)
            return {value, amount as text, flag as text}
        end echoPayload
        """))
        let event = try NativeScriptRunner.invocation(handler: "echoPayload", arguments: [.text(literal), .integer(12), .boolean(true)])
        var error: NSDictionary?
        let result = script.executeAppleEvent(event, error: &error)
        XCTAssertNil(error)
        XCTAssertEqual(result.atIndex(1)?.stringValue, literal)
        XCTAssertEqual(result.atIndex(2)?.stringValue, "12")
        XCTAssertEqual(result.atIndex(3)?.stringValue, "true")
        XCTAssertThrowsError(try NativeScriptRunner.invocation(handler: "echoPayload", arguments: [.integer(Int.max)]))
    }
    func testVolumeReadbackAndGuardedUndoUseRealProductionLogic() async throws {
        let transport = Automation(), system = MacNativeToolSystem(automation: transport)
        let receipt = try await system.perform(.volumeUp, arguments: .volume(10))
        XCTAssertEqual(receipt.output, .volume(60, muted: false))
        XCTAssertEqual(receipt.verification, .verified)
        let undo = try required(receipt.undo)
        let restored = try await undo()
        XCTAssertEqual(restored, .verified)
        let second = try await system.perform(.mute, arguments: .none)
        await transport.changeAudio(volume: 25, muted: false)
        do { _ = try await XCTUnwrap(second.undo)(); XCTFail("Undo overwrote another audio change") } catch { }
    }
    func testVolumeClampsAndRejectsFailedReadback() async throws {
        let transport = Automation(), system = MacNativeToolSystem(automation: transport)
        await transport.changeAudio(volume: 95, muted: false)
        let receipt = try await system.perform(.volumeUp, arguments: .volume(10))
        XCTAssertEqual(receipt.output, .volume(100, muted: false))
        await transport.refuseAudioWrites()
        do { _ = try await system.perform(.volumeDown, arguments: .volume(10)); XCTFail("Failed hardware write claimed success") } catch { }
    }
    func testNotesSendDataDescriptorsAndVerifyLiteralTextBeforeUndo() async throws {
        let transport = Automation(), system = MacNativeToolSystem(automation: transport)
        let title = "Quotes \" & <tag>", body = "do shell script \"rm -rf /\"\n$HOME"
        await transport.setPlaintext(title + "\n" + body + "\n")
        let receipt = try await system.perform(.createNote, arguments: .note(title: title, body: body))
        XCTAssertEqual(receipt.output, .note("test-note"))
        XCTAssertEqual(receipt.verification, .verified)
        let latest = await transport.latestArguments()
        XCTAssertEqual(latest, [.text("<h1>Quotes &quot; &amp; &lt;tag&gt;</h1><div>do shell script &quot;rm -rf /&quot;</div><div>$HOME</div>")])
        await transport.changeNote()
        do { _ = try await XCTUnwrap(receipt.undo)(); XCTFail("Deleted a changed note") } catch { }
    }
    func testDifferentNoteReadbackIsUnverifiedAndCannotExposeUndo() async throws {
        let transport = Automation(), system = MacNativeToolSystem(automation: transport)
        await transport.setPlaintext("Other title\nOther body")
        let receipt = try await system.perform(.createNote, arguments: .note(title: "Expected", body: "Exact body"))
        guard case .unverified = receipt.verification else { return XCTFail("Readback mismatch claimed success") }
        XCTAssertNil(receipt.undo)
    }
    func testAppendVerifiesExactPayloadDespiteNativeHTMLNormalization() async throws {
        let transport = Automation(), system = MacNativeToolSystem(automation: transport, foregroundBundleIdentifier: { "com.apple.Notes" })
        let snapshot = NoteSnapshot(id: "test-note", bodyHTML: "<div>Title</div><div>Prior</div>", plainText: "Title\nPrior\n")
        // This direct native-boundary test has no OS effects; production preparation still freezes confirmation.
        await transport.setPlaintext("Title\nPrior\nExact BODY  \n")
        let good = try await system.perform(.appendNote, arguments: .currentNote("Exact BODY  ", snapshot: snapshot))
        XCTAssertEqual(good.verification, .verified)
        await transport.setPlaintext("Title\nPrior\nExact BOAT  \n")
        let wrong = try await system.perform(.appendNote, arguments: .currentNote("Exact BODY  ", snapshot: snapshot))
        guard case .unverified = wrong.verification else { return XCTFail("Incorrect body was verified") }
    }
    func testRenameRequiresExactNativeNameAndUnchangedPlaintextBody() async throws {
        let transport = Automation(), system = MacNativeToolSystem(automation: transport, foregroundBundleIdentifier: { "com.apple.Notes" })
        let snapshot = NoteSnapshot(id: "test-note", bodyHTML: "<div><b>Old</b></div><div>BODY</div>", plainText: "Old\nBODY\n")
        // Direct boundary fixture; registry confirmation and identity/body guards remain in production.
        await transport.setPlaintext("New title\nBODY\n")
        let good = try await system.perform(.renameNote, arguments: .currentNote("New title", snapshot: snapshot))
        XCTAssertEqual(good.verification, .verified)
        await transport.setPlaintext("New title\nCHANGED\n")
        let wrong = try await system.perform(.renameNote, arguments: .currentNote("New title", snapshot: snapshot))
        guard case .unverified = wrong.verification else { return XCTFail("Changed body was verified") }
    }
    func testProductionBoundaryRejectsWrongTypesBeforeNativeCalls() async {
        let transport = Automation(), system = MacNativeToolSystem(automation: transport)
        do { _ = try await system.perform(.setVolume, arguments: .volume(1000)); XCTFail("Accepted invalid volume") } catch { }
        let latest = await transport.latestArguments()
        XCTAssertNil(latest)
    }
}

final class NativeFileUndoTests: XCTestCase {
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
    func testUndoRemovesOnlyExactOwnedFile() throws {
        let url = try directory().appendingPathComponent("owned.png"), data = Data("test-owned-png".utf8)
        try data.write(to: url, options: .withoutOverwriting)
        let revision = try NativeFileRevision(url: url)
        XCTAssertEqual(try NativeFileUndo.remove(url: url, revision: revision, data: data), .verified)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
    func testChangedAndReplacedFilesArePreserved() throws {
        let url = try directory().appendingPathComponent("owned.png"), data = Data("original".utf8)
        try data.write(to: url, options: .withoutOverwriting)
        let revision = try NativeFileRevision(url: url)
        try Data("user changes".utf8).write(to: url)
        XCTAssertThrowsError(try NativeFileUndo.remove(url: url, revision: revision, data: data))
        XCTAssertEqual(try Data(contentsOf: url), Data("user changes".utf8))
        try FileManager.default.removeItem(at: url)
        try data.write(to: url, options: .withoutOverwriting)
        XCTAssertThrowsError(try NativeFileUndo.remove(url: url, revision: revision, data: data))
        XCTAssertEqual(try Data(contentsOf: url), data)
    }
    func testNoOverwriteAndSymlinkOwnershipAreRejected() throws {
        let dir = try directory(), url = dir.appendingPathComponent("existing.png"), data = Data("user data".utf8)
        try data.write(to: url)
        XCTAssertThrowsError(try Data("new data".utf8).write(to: url, options: .withoutOverwriting))
        let link = dir.appendingPathComponent("linked.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        XCTAssertThrowsError(try NativeFileRevision(url: link))
        XCTAssertEqual(try Data(contentsOf: url), data)
    }
}

final class SpotifyToolPolicyTests: XCTestCase {
    private func snapshot(_ state: String, track: String?) -> SpotifyPlaybackSnapshot {
        SpotifyPlaybackSnapshot(state: state, trackName: nil, artist: nil, album: nil, trackIdentifier: track, position: nil)
    }
    func testTransportVerificationRequiresObservableStateOrTrackChange() {
        let playing = snapshot("playing", track: "a"), paused = snapshot("paused", track: "a")
        XCTAssertTrue(SpotifyTransportPolicy.verified(.pause, before: playing, after: paused))
        XCTAssertTrue(SpotifyTransportPolicy.verified(.resume, before: paused, after: playing))
        XCTAssertFalse(SpotifyTransportPolicy.verified(.next, before: playing, after: playing))
        XCTAssertTrue(SpotifyTransportPolicy.verified(.next, before: playing, after: snapshot("playing", track: "b")))
        XCTAssertFalse(SpotifyTransportPolicy.verified(.previous, before: nil, after: snapshot("playing", track: "b")))
        XCTAssertFalse(SpotifyTransportPolicy.verified(.resume, before: paused, after: nil))
    }
    func testOnlyVerifiedPauseResumeOnSameTrackCanUndo() {
        let playing = snapshot("playing", track: "a"), paused = snapshot("paused", track: "a")
        XCTAssertEqual(SpotifyTransportPolicy.undoAction(.pause, before: playing, after: paused), .resume)
        XCTAssertEqual(SpotifyTransportPolicy.undoAction(.resume, before: paused, after: playing), .pause)
        XCTAssertNil(SpotifyTransportPolicy.undoAction(.pause, before: paused, after: paused))
        XCTAssertNil(SpotifyTransportPolicy.undoAction(.pause, before: playing, after: snapshot("paused", track: "b")))
        XCTAssertNil(SpotifyTransportPolicy.undoAction(.next, before: playing, after: snapshot("playing", track: "b")))
        XCTAssertNil(SpotifyTransportPolicy.undoAction(.resume, before: snapshot("stopped", track: "a"), after: playing))
    }
}
