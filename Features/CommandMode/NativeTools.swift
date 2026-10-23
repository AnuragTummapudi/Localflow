import Foundation
import TextInjection

public enum ToolRisk: String, Sendable { case safe, reversible, consequential }
public enum ToolArgumentKind: String, Sendable {
    case application, url, search, website, text, selection, volume, reminder, note, currentNote, spotify, screenshot, file, none, semantic
}

/// Stable identifiers are independent of speech wording and model output.
public enum NativeToolID: String, CaseIterable, Sendable {
    case openApplication = "application.open", focusApplication = "application.focus", quitApplication = "application.quit"
    case openURL = "web.open_url", searchWeb = "web.search", searchProvider = "web.search_provider", openWebsite = "web.open_website"
    case typeText = "text.type", replaceSelection = "text.replace_selection", copyText = "text.copy"
    case volumeUp = "system.volume_up", volumeDown = "system.volume_down", setVolume = "system.volume_set"
    case mute = "system.mute", unmute = "system.unmute", sleepDisplay = "system.sleep_display", lockMac = "system.lock"
    case createReminder = "reminder.create", createNote = "note.create", appendNote = "note.append_current", writeNote = "note.write_current", renameNote = "note.rename_current"
    case spotifyTransport = "spotify.transport", spotifySearch = "spotify.search"
    case screenshot = "utility.screenshot", revealFile = "utility.reveal"

    case projectResolve = "project.resolve", projectOpen = "project.open", projectSearch = "project.search"
    case projectOpenFile = "project.openFile", projectReveal = "project.reveal"
    case fileSearch = "file.search", fileOpen = "file.open", fileReveal = "file.reveal"
    case workflowList = "workflow.list", workflowRun = "workflow.run", workflowStop = "workflow.stop"
    case serviceWait = "service.wait", serviceStatus = "service.status"
    case editorOpenProject = "editor.openProject", editorOpenFile = "editor.openFile", editorRevealSymbol = "editor.revealSymbol"

    case uiObserve = "ui.observe", uiFocus = "ui.focus", uiPress = "ui.press", uiSetValue = "ui.setValue"
    case uiSelect = "ui.select", uiScroll = "ui.scroll", uiRaiseWindow = "ui.raiseWindow"

    public var argumentKind: ToolArgumentKind {
        if isAccessibility { return .semantic }
        switch self {
        case .uiObserve, .uiFocus, .uiPress, .uiSetValue, .uiSelect, .uiScroll, .uiRaiseWindow: return .semantic
        case .openApplication, .focusApplication, .quitApplication: return .application
        case .openURL: return .url
        case .searchWeb, .searchProvider, .spotifySearch: return .search
        case .openWebsite: return .website
        case .typeText, .copyText: return .text
        case .replaceSelection: return .selection
        case .volumeUp, .volumeDown, .setVolume: return .volume
        case .createReminder: return .reminder
        case .createNote: return .note
        case .appendNote, .writeNote, .renameNote: return .currentNote
        case .spotifyTransport: return .spotify
        case .screenshot: return .screenshot
        case .revealFile: return .file
        case .mute, .unmute, .sleepDisplay, .lockMac: return .none
        case .projectResolve, .projectOpen, .projectSearch, .projectOpenFile, .projectReveal, .fileSearch, .fileOpen, .fileReveal,
             .workflowList, .workflowRun, .workflowStop, .serviceWait, .serviceStatus, .editorOpenProject, .editorOpenFile, .editorRevealSymbol: return .semantic
        }
    }
    public var risk: ToolRisk {
        if isAccessibility { return [.uiObserve, .uiFocus, .uiScroll, .uiRaiseWindow].contains(self) ? .safe : .consequential }
        switch self {
        case .quitApplication, .replaceSelection, .sleepDisplay, .lockMac, .appendNote, .writeNote, .renameNote, .workflowRun, .workflowStop: return .consequential
        case .openURL, .searchWeb, .searchProvider, .openWebsite, .spotifySearch, .revealFile,
             .projectResolve, .projectSearch, .projectReveal, .fileSearch, .fileReveal, .workflowList, .serviceWait, .serviceStatus, .editorRevealSymbol: return .safe
        default: return .reversible
        }
    }
    public var description: String {
        if isAccessibility { return "Semantic UI " + uiAction }
        switch self {
        case .uiObserve, .uiFocus, .uiPress, .uiSetValue, .uiSelect, .uiScroll, .uiRaiseWindow: return "Semantic UI " + uiAction
        case .openApplication: return "Open application"
        case .focusApplication: return "Focus application"
        case .quitApplication: return "Quit application"
        case .openURL: return "Open URL"
        case .searchWeb: return "Search web"
        case .searchProvider: return "Search provider"
        case .openWebsite: return "Open website"
        case .typeText: return "Type at cursor"
        case .replaceSelection: return "Replace selected text"
        case .copyText: return "Copy to clipboard"
        case .volumeUp: return "Increase volume"
        case .volumeDown: return "Decrease volume"
        case .setVolume: return "Set volume"
        case .mute: return "Mute audio"
        case .unmute: return "Unmute audio"
        case .sleepDisplay: return "Sleep display"
        case .lockMac: return "Lock Mac"
        case .createReminder: return "Create reminder"
        case .createNote: return "Create note"
        case .appendNote: return "Append to current note"
        case .writeNote: return "Write current note"
        case .renameNote: return "Rename current note"
        case .spotifyTransport: return "Spotify playback"
        case .spotifySearch: return "Search Spotify"
        case .screenshot: return "Take screenshot"
        case .revealFile: return "Reveal in Finder"
        case .projectResolve: return "Resolve explicit saved project by name or alias"
        case .projectOpen, .editorOpenProject: return "Open saved project in its configured editor"
        case .projectSearch, .fileSearch: return "Search filenames and text within an explicit saved project"
        case .projectOpenFile, .fileOpen, .editorOpenFile: return "Open a file within a saved project"
        case .projectReveal, .fileReveal: return "Reveal saved project or its file in Finder"
        case .workflowList: return "List explicitly approved project workflows"
        case .workflowRun: return "Start a saved approved workflow; user confirmation required"
        case .workflowStop: return "Stop only a LocalFlow-owned saved workflow; user confirmation required"
        case .serviceWait: return "Wait for a saved loopback service to respond; bounded timeout"
        case .serviceStatus: return "Check saved loopback service status"
        case .editorRevealSymbol: return "Find a symbol in saved project text; returns paths and lines"
        }
    }
}

public struct NoteSnapshot: Equatable, Sendable {
    public let id: String
    public let bodyHTML: String
    public let plainText: String?
    public init(id: String, bodyHTML: String, plainText: String? = nil) { self.id = id; self.bodyHTML = bodyHTML; self.plainText = plainText }
}

/// Exact slots come from deterministic parsers/capture, never generated by the decision model.
public enum ToolArguments: Equatable, Sendable {
    case application(ApplicationMatch, processID: Int32? = nil)
    case url(URL)
    case search(query: String, provider: String)
    case website(String)
    case text(String, targetProcessID: Int32? = nil)
    case selection(String, snapshot: SelectedTextSnapshot? = nil)
    case volume(Int)
    case reminder(title: String, notes: String? = nil, due: Date? = nil)
    case note(title: String, body: String)
    case currentNote(String, snapshot: NoteSnapshot? = nil)
    case spotify(SpotifyPlaybackAction)
    case screenshot(destination: URL? = nil, displayID: UInt32? = nil)
    case file(URL)
    case none
    case semantic(SemanticToolArguments)

    public func validate(for id: NativeToolID) throws {
        func nonempty(_ text: String) throws {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 100_000 else { throw ToolError.invalidArguments }
        }
        switch (id, self) {
        case (.openApplication, .application(let app, _)), (.focusApplication, .application(let app, _)), (.quitApplication, .application(let app, _)):
            try nonempty(app.name)
            guard app.bundleIdentifier != nil || app.url?.isFileURL == true else { throw ToolError.invalidArguments }
        case (.openURL, .url(let url)):
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host, !host.isEmpty,
                  url.user == nil, url.password == nil else { throw ToolError.invalidArguments }
        case (.searchWeb, .search(let query, let provider)), (.searchProvider, .search(let query, let provider)), (.spotifySearch, .search(let query, let provider)):
            try nonempty(query); try nonempty(provider)
        case (.openWebsite, .website(let domain)): try nonempty(domain)
        case (.typeText, .text(let text, _)), (.copyText, .text(let text, _)), (.replaceSelection, .selection(let text, _)),
             (.appendNote, .currentNote(let text, _)), (.writeNote, .currentNote(let text, _)), (.renameNote, .currentNote(let text, _)): try nonempty(text)
        case (.setVolume, .volume(let value)): guard (0...100).contains(value) else { throw ToolError.invalidArguments }
        case (.volumeUp, .volume(let value)), (.volumeDown, .volume(let value)): guard (1...100).contains(value) else { throw ToolError.invalidArguments }
        case (.createReminder, .reminder(let title, let notes, _)): try nonempty(title); if let notes { guard notes.utf8.count <= 100_000 else { throw ToolError.invalidArguments } }
        case (.createNote, .note(let title, let body)): try nonempty(title); guard body.utf8.count <= 100_000 else { throw ToolError.invalidArguments }
        case (.spotifyTransport, .spotify): break
        case (.screenshot, .screenshot(let destination, _)):
            if let destination { guard destination.isFileURL, destination.pathExtension.lowercased() == "png" else { throw ToolError.invalidArguments } }
        case (.revealFile, .file(let url)): guard url.isFileURL else { throw ToolError.invalidArguments }
        case (.mute, .none), (.unmute, .none), (.sleepDisplay, .none), (.lockMac, .none): break
        case (_, .semantic(let value)) where id.argumentKind == .semantic: try value.validateShape(for: id)
        default: throw ToolError.invalidArguments
        }
    }
}

public struct AgentAction: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let toolID: NativeToolID
    public let arguments: ToolArguments
    public init(id: UUID = UUID(), toolID: NativeToolID, arguments: ToolArguments) {
        self.id = id; self.toolID = toolID; self.arguments = arguments
    }
    public func prepared(arguments: ToolArguments) -> AgentAction { AgentAction(id: id, toolID: toolID, arguments: arguments) }
}

public enum ToolError: Error, LocalizedError {
    case invalidArguments, unavailable(String), changedTarget, permission(String), busy
    public var errorDescription: String? {
        switch self {
        case .invalidArguments: return "Invalid arguments for this tool."
        case .unavailable(let detail): return detail
        case .changedTarget: return "The target changed. Nothing was overwritten."
        case .permission(let permission): return "Permission required: enable \(permission) for LocalFlow in System Settings → Privacy & Security, then retry the command."
        case .busy: return "Another native action is still running."
        }
    }
}

public enum ToolVerification: Equatable, Sendable {
    case verified
    case unverified(String)
    case failed(String)
}
public enum ToolOutput: Equatable, Sendable {
    case none, application(Int32), openedURL(URL), text, clipboard, volume(Int, muted: Bool)
    case reminder(String), note(String), file(URL), media
    case semantic([String: PlannerValue])
}

/// Undo closures own exact before/after snapshots. Production guards external changes before restoring.
@MainActor public struct ToolExecution {
    public let message: String
    public let output: ToolOutput
    public let verification: ToolVerification
    public let undo: (() async throws -> ToolVerification)?
    public init(message: String, output: ToolOutput = .none, verification: ToolVerification,
                undo: (() async throws -> ToolVerification)? = nil) {
        self.message = message; self.output = output; self.verification = verification; self.undo = undo
    }
}

@MainActor public protocol AgentTool {
    var id: NativeToolID { get }
    var description: String { get }
    var risk: ToolRisk { get }
    var argumentKind: ToolArgumentKind { get }
    var requiresConfirmation: Bool { get }
    func prepare(_ action: AgentAction) async throws -> AgentAction
    func execute(_ arguments: ToolArguments) async throws -> ToolExecution
}

/// Injectable OS boundary; the production implementation uses native Mac services.
@MainActor public protocol NativeToolSystem {
    func terminateOwnedProcesses()
    func invalidateUIObservation()
    func effectiveRisk(for action: AgentAction) -> ToolRisk
    func prepare(_ action: AgentAction) async throws -> AgentAction
    func perform(_ id: NativeToolID, arguments: ToolArguments) async throws -> ToolExecution
}

extension NativeToolSystem {
    public func terminateOwnedProcesses() {}
    public func invalidateUIObservation() {}
    public func effectiveRisk(for action: AgentAction) -> ToolRisk { action.toolID.risk }
}

@MainActor private struct NativeAgentTool: AgentTool {
    let id: NativeToolID
    let system: any NativeToolSystem
    var description: String { id.description }
    var risk: ToolRisk { id.risk }
    var argumentKind: ToolArgumentKind { id.argumentKind }
    var requiresConfirmation: Bool { risk == .consequential }
    func prepare(_ action: AgentAction) async throws -> AgentAction {
        guard action.toolID == id else { throw ToolError.invalidArguments }
        return try await system.prepare(action)
    }
    func execute(_ arguments: ToolArguments) async throws -> ToolExecution {
        try arguments.validate(for: id)
        return try await system.perform(id, arguments: arguments)
    }
}

@MainActor public final class ToolRegistry {
    private let system: any NativeToolSystem
    public func terminateOwnedProcesses() { system.terminateOwnedProcesses() }
    public func invalidateUIObservation() { system.invalidateUIObservation() }
    private let tools: [NativeToolID: any AgentTool]
    public var allTools: [any AgentTool] { NativeToolID.allCases.compactMap { tools[$0] } }
    public init(system: any NativeToolSystem) {
        self.system = system
        tools = Dictionary(uniqueKeysWithValues: NativeToolID.allCases.map { ($0, NativeAgentTool(id: $0, system: system) as any AgentTool) })
    }
    public convenience init() { self.init(system: MacNativeToolSystem()) }
    public func tool(_ id: NativeToolID) -> any AgentTool { tools[id]! }
    public func effectiveRisk(for action: AgentAction) -> ToolRisk { system.effectiveRisk(for: action) }
}

@MainActor public protocol ActionVerifier {
    func verify(_ action: AgentAction, execution: ToolExecution) async -> ToolVerification
}
/// Native implementations read back state before producing this receipt. Unobservable requests remain unverified.
@MainActor public struct NativeActionVerifier: ActionVerifier {
    public init() {}
    public func verify(_ action: AgentAction, execution: ToolExecution) async -> ToolVerification { execution.verification }
}

public struct ToolConfirmation: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let action: AgentAction
}
public struct ToolUndoToken: Equatable, Sendable { public let id: UUID }
public enum ToolResult {
    case completed(message: String, output: ToolOutput, verification: ToolVerification, undo: ToolUndoToken?)
    case requiresConfirmation(ToolConfirmation)
    case failed(String)
    case cancelled
}

/// One execution path for CommandMode and future callers. Confirmations are single-use and bound to frozen slots.
@MainActor public final class ActionExecutor {
    public let registry: ToolRegistry
    private let verifier: any ActionVerifier
    private let now: () -> Date
    private var confirmation: ToolConfirmation?
    private var confirmationExpiry = Date.distantPast
    private var preparationID = UUID()
    private var undos: [UUID: (Date, () async throws -> ToolVerification)] = [:]
    private var busy = false
    public init(registry: ToolRegistry? = nil, verifier: (any ActionVerifier)? = nil, now: @escaping () -> Date = Date.init) {
        self.registry = registry ?? ToolRegistry(); self.verifier = verifier ?? NativeActionVerifier(); self.now = now
    }
    public func execute(_ action: AgentAction, requireConfirmation: Bool = false, onPerform: (() -> Void)? = nil) async -> ToolResult {
        guard !busy else { return .failed(ToolError.busy.localizedDescription) }
        busy = true
        defer { busy = false }
        confirmation = nil
        let preparation = UUID()
        preparationID = preparation
        do {
            try Task.checkCancellation()
            try action.arguments.validate(for: action.toolID)
            let tool = registry.tool(action.toolID)
            let prepared = try await tool.prepare(action)
            guard prepared.id == action.id, prepared.toolID == action.toolID else { throw ToolError.invalidArguments }
            guard preparationID == preparation else { throw CancellationError() }
            try prepared.arguments.validate(for: action.toolID)
            try Task.checkCancellation()
            if registry.effectiveRisk(for: prepared) == .consequential || requireConfirmation {
                let challenge = ToolConfirmation(id: UUID(), action: prepared)
                confirmation = challenge
                confirmationExpiry = now().addingTimeInterval(120)
                let id = challenge.id
                Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(120)) } catch { return }
                    if self?.confirmation?.id == id { self?.confirmation = nil }
                }
                return .requiresConfirmation(challenge)
            }
            return try await run(prepared, onPerform: onPerform)
        } catch is CancellationError { return .cancelled }
        catch { return .failed(error.localizedDescription) }
    }
    public func confirm(_ challenge: ToolConfirmation, onPerform: (() -> Void)? = nil) async -> ToolResult {
        guard !busy else { return .failed(ToolError.busy.localizedDescription) }
        guard confirmation == challenge, confirmationExpiry > now() else { return .failed("This confirmation is no longer valid.") }
        confirmation = nil
        busy = true
        defer { busy = false }
        do { try Task.checkCancellation(); return try await run(challenge.action, onPerform: onPerform) }
        catch is CancellationError { return .cancelled }
        catch { return .failed(error.localizedDescription) }
    }
    public func cancelConfirmation() { confirmation = nil; preparationID = UUID(); registry.invalidateUIObservation() }
    /// A developer preview must not revoke a newer native action's grant.
    @discardableResult public func cancelConfirmation(matching challenge: ToolConfirmation) -> Bool {
        guard confirmation == challenge else { return false }
        cancelConfirmation()
        return true
    }
#if DEBUG
    /// Developer reality gate: exercise the real single-use confirmation grant,
    /// consume it, and deliberately never call the native effect.
    public func validateConfirmationWithoutPerforming(_ challenge: ToolConfirmation) -> Bool {
        guard !busy, confirmation == challenge, confirmationExpiry > now() else { return false }
        confirmation = nil
        return true
    }
#endif
    public func undo(_ token: ToolUndoToken) async -> ToolResult {
        guard !busy else { return .failed(ToolError.busy.localizedDescription) }
        guard let (expiry, operation) = undos.removeValue(forKey: token.id), expiry > now() else { return .failed("Undo is no longer available.") }
        busy = true
        defer { busy = false }
        do {
            try Task.checkCancellation()
            let result = try await operation()
            if case .failed(let detail) = result { return .failed(detail) }
            return .completed(message: "Action undone", output: .none, verification: result, undo: nil)
        } catch { return .failed(error.localizedDescription) }
    }
    private func run(_ action: AgentAction, onPerform: (() -> Void)? = nil) async throws -> ToolResult {
        let tool = registry.tool(action.toolID)
        try Task.checkCancellation()
        onPerform?()
        let execution = try await tool.execute(action.arguments)
        let verification = await verifier.verify(action, execution: execution)
        if case .failed(let detail) = verification { return .failed(detail) }
        // After an effect, return its truthful receipt even if the caller was cancelled.
        // Cancellation cannot retract a native request already delivered.
        undos = undos.filter { $0.value.0 > now() }
        var token: ToolUndoToken?
        if tool.risk == .reversible, verification == .verified, let undo = execution.undo {
            let id = UUID(); undos[id] = (now().addingTimeInterval(60), undo); token = ToolUndoToken(id: id)
            // Release clipboard/file/selection snapshots at expiry even if no further command arrives.
            Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                self?.undos.removeValue(forKey: id)
            }
        }
        return .completed(message: execution.message, output: execution.output, verification: verification, undo: token)
    }
}
