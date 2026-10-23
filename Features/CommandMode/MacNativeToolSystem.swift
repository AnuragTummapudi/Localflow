import AppKit
import Shared
import Carbon.HIToolbox
import EventKit
import ImageIO
import ScreenCaptureKit
import TextInjection
import UniformTypeIdentifiers

/// AppKit ownership stays on the main actor. Blocking Apple Events are serialized off it.
@MainActor public final class MacNativeToolSystem: NativeToolSystem {
    private var preferredBrowser: (() -> String?)?
    private let accessibility = SemanticAccessibilityService()
    private let semantic: SemanticToolSystem
    private let injection: TextInjection
    private let scripts: any NativeScriptCalling
    private let reminders = EKEventStore()
    private let search: SearchProviderRegistry
    private let foregroundBundleIdentifier: @MainActor () -> String?
    public convenience init(injection: TextInjection = TextInjection(), search: SearchProviderRegistry = .shared, preferredBrowser: (() -> String?)? = nil, memory: @escaping @MainActor () -> AgentMemory = { AgentMemory() }) {
        self.init(injection: injection, search: search, automation: nil, memory: memory)
        self.preferredBrowser = preferredBrowser
    }
    init(injection: TextInjection = TextInjection(), search: SearchProviderRegistry = .shared, automation: (any NativeScriptCalling)?,
         memory: @escaping @MainActor () -> AgentMemory = { AgentMemory() },
         foregroundBundleIdentifier: @escaping @MainActor () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }) {
        self.semantic = SemanticToolSystem(memory: memory)
        self.injection = injection; self.search = search; self.scripts = automation ?? NativeScriptRunner()
        self.foregroundBundleIdentifier = foregroundBundleIdentifier
    }

    public func invalidateUIObservation() { accessibility.invalidate() }
    public func terminateOwnedProcesses() { semantic.stopAllImmediately(); accessibility.invalidate() }

    public func prepare(_ action: AgentAction) async throws -> AgentAction {
        if action.toolID.isAccessibility { return try accessibility.prepare(action) }
        if action.toolID.argumentKind == .semantic { return try semantic.prepare(action) }
        switch action.arguments {
        case .application(let app, _) where action.toolID == .quitApplication:
            guard let running = runningApplication(app) else { throw ToolError.unavailable("\(app.name) is not running.") }
            return action.prepared(arguments: .application(app, processID: running.processIdentifier))
        case .text(let text, nil) where action.toolID == .typeText:
            guard let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier != Bundle.main.bundleIdentifier else { throw ToolError.unavailable("No foreground text target.") }
            return action.prepared(arguments: .text(text, targetProcessID: front.processIdentifier))
        case .selection(let text, nil):
            switch await injection.captureCurrentSelection() {
            case .captured(let snapshot): return action.prepared(arguments: .selection(text, snapshot: snapshot))
            case .permissionDenied: throw ToolError.permission("Accessibility")
            default: throw ToolError.unavailable("Select editable text before replacing it.")
            }
        case .currentNote(let text, nil):
            guard foregroundBundleIdentifier() == "com.apple.Notes" else { throw ToolError.unavailable("Select a note in Notes first.") }
            let values = try await scripts.call(.notes, handler: "captureCurrent", arguments: [])
            guard values.count == 3 else { throw ToolError.unavailable("Select exactly one unlocked, unshared note.") }
            return action.prepared(arguments: .currentNote(text, snapshot: NoteSnapshot(id: values[0], bodyHTML: values[1], plainText: values[2])))
        default: return action
        }
    }

    public func effectiveRisk(for action: AgentAction) -> ToolRisk { action.toolID.isAccessibility ? accessibility.risk(for: action) : action.toolID.risk }

    public func perform(_ id: NativeToolID, arguments: ToolArguments) async throws -> ToolExecution {
        if id.isAccessibility { return try await accessibility.perform(id, arguments: arguments) }
        if id.argumentKind == .semantic { return try await semantic.perform(id, arguments: arguments) }
        try Task.checkCancellation()
        try arguments.validate(for: id)
        switch (id, arguments) {
        case (.openApplication, .application(let app, _)), (.focusApplication, .application(let app, _)):
            return try await openApplication(app, focusOnly: id == .focusApplication)
        case (.quitApplication, .application(let app, let pid)):
            guard let pid, let target = NSRunningApplication(processIdentifier: pid), !target.isTerminated,
                  matches(target, app) else { throw ToolError.changedTarget }
            guard target.terminate() else { throw ToolError.unavailable("\(app.name) declined to quit.") }
            for _ in 0..<20 {
                if target.isTerminated { return ToolExecution(message: "\(app.name) quit", verification: .verified) }
                if Task.isCancelled { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return ToolExecution(message: "Quit requested for \(app.name)", verification: .unverified("The app may be waiting for a save dialog."))
        case (.openURL, .url(let url)): return try await openURL(url)
        case (.searchWeb, .search(let query, let provider)), (.searchProvider, .search(let query, let provider)), (.spotifySearch, .search(let query, let provider)):
            guard let destination = search.findProvider(for: id == .spotifySearch ? "spotify" : provider)?.searchURL(for: query) else { throw ToolError.unavailable("Unknown search provider.") }
            return try await openURL(destination, message: "Search opened")
        case (.openWebsite, .website(let domain)):
            guard let url = Self.websiteURL(domain, registry: search) else { throw ToolError.invalidArguments }
            return try await openURL(url)
        case (.typeText, .text(let text, let pid)):
            guard let pid, let target = NSRunningApplication(processIdentifier: pid), !target.isTerminated,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { throw ToolError.changedTarget }
            if let selected = injection.selectedText(preferredPID: pid), !selected.isEmpty {
                throw ToolError.unavailable("Text is selected. Use Replace Selected Text and confirm the replacement.")
            }
            guard try await injection.insert(text, into: target) == .inserted else { throw ToolError.unavailable("No editable text target.") }
            return ToolExecution(message: "Text sent", output: .text, verification: .unverified("Paste was sent; this editor does not expose a verified receipt."))
        case (.replaceSelection, .selection(let text, let snapshot)):
            guard let snapshot else { throw ToolError.invalidArguments }
            switch await injection.replaceCapturedSelection(snapshot, with: text) {
            case .verified: return ToolExecution(message: "Selected text replaced", output: .text, verification: .verified)
            case .sentUnverified: return ToolExecution(message: "Replacement sent", output: .text, verification: .unverified("The editor did not expose readback."))
            case .selectionChanged, .targetChanged: throw ToolError.changedTarget
            default: throw ToolError.unavailable("This selection could not be safely replaced.")
            }
        case (.copyText, .text(let text, _)): return try copyText(text)
        case (.volumeUp, .volume(let step)), (.volumeDown, .volume(let step)), (.setVolume, .volume(let step)):
            let before = try await audioSnapshot()
            let value = id == .setVolume ? step : min(100, max(0, before.volume + (id == .volumeUp ? step : -step)))
            return try await setAudio(before: before, after: AudioSnapshot(volume: value, muted: before.muted), changeVolume: true, changeMuted: false)
        case (.mute, .none), (.unmute, .none):
            let before = try await audioSnapshot()
            return try await setAudio(before: before, after: AudioSnapshot(volume: before.volume, muted: id == .mute), changeVolume: false, changeMuted: true)
        case (.sleepDisplay, .none):
            // Fixed allowlisted native utility, no shell, user text, or arbitrary arguments.
            try await Self.sleepDisplay()
            return ToolExecution(message: "Display sleep requested", verification: .unverified("macOS does not provide a public per-request sleep receipt."))
        case (.lockMac, .none):
            guard CGPreflightPostEventAccess() else { throw ToolError.permission("Accessibility") }
            guard let source = CGEventSource(stateID: .hidSystemState),
                  let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_Q), keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_Q), keyDown: false) else { throw ToolError.unavailable("Unable to send the native Lock Screen shortcut.") }
            source.localEventsSuppressionInterval = 0
            down.flags = [.maskCommand, .maskControl]; up.flags = down.flags
            down.post(tap: .cgAnnotatedSessionEventTap); up.post(tap: .cgAnnotatedSessionEventTap)
            return ToolExecution(message: "Lock requested", verification: .unverified("The native shortcut was sent; lock state is not publicly verifiable."))
        case (.createReminder, .reminder(let title, let notes, let due)): return try await createReminder(title: title, notes: notes, due: due)
        case (.createNote, .note(let title, let body)):
            let html = "<h1>\(Self.escapeHTML(title))</h1>\(Self.htmlBody(body))"
            let receipt = try await scripts.call(.notes, handler: "createNote", arguments: [.text(html)])
            guard receipt.count == 4, !receipt[0].isEmpty, !receipt[3].isEmpty else { throw ToolError.unavailable("Notes did not return a creation receipt.") }
            let expected = (title + (body.isEmpty ? "" : "\n" + body)).trimmingCharacters(in: .whitespacesAndNewlines)
            let verified = receipt[2].trimmingCharacters(in: .whitespacesAndNewlines) == expected
            let noteID = receipt[0], ownedBody = receipt[1], ownedFolder = receipt[3]
            return ToolExecution(message: verified ? "Note created" : "Note creation requested", output: .note(noteID),
                                 verification: verified ? .verified : .unverified("Notes returned different text; inspect the note."), undo: verified ? { [self] in
                _ = try await scripts.call(.notes, handler: "undoCreated", arguments: [.text(noteID), .text(ownedBody), .text(ownedFolder)])
                return .verified
            } : nil)
        case (.appendNote, .currentNote(let text, let snapshot)), (.writeNote, .currentNote(let text, let snapshot)):
            guard let snapshot, foregroundBundleIdentifier() == "com.apple.Notes" else { throw ToolError.changedTarget }
            // Rich content/attachments are never silently flattened by a write operation.
            guard !snapshot.bodyHTML.localizedCaseInsensitiveContains("<object"), !snapshot.bodyHTML.localizedCaseInsensitiveContains("<img"),
                  !snapshot.bodyHTML.localizedCaseInsensitiveContains("<table") else { throw ToolError.unavailable("This note has rich content. Edit it directly in Notes.") }
            let html = id == .appendNote ? snapshot.bodyHTML + Self.htmlBody(text) : Self.htmlBody(text)
            let receipt = try await scripts.call(.notes, handler: "updateCurrent", arguments: [.text(snapshot.id), .text(snapshot.bodyHTML), .text(html)])
            guard receipt.count == 3, receipt[0] == snapshot.id else { throw ToolError.changedTarget }
            let expected = id == .writeNote ? text : snapshot.plainText.map {
                let before = Self.notePlaintext($0)
                return before.isEmpty ? text : before + "\n" + text
            }
            let verified = expected.map { Self.notePlaintext(receipt[2]) == $0 } ?? (receipt[1] == html)
            return ToolExecution(message: "Note updated", output: .note(snapshot.id), verification: verified ? .verified : .unverified("Notes returned different text; inspect the note."))
        case (.renameNote, .currentNote(let title, let snapshot)):
            guard let snapshot, foregroundBundleIdentifier() == "com.apple.Notes" else { throw ToolError.changedTarget }
            guard !snapshot.bodyHTML.localizedCaseInsensitiveContains("<object"), !snapshot.bodyHTML.localizedCaseInsensitiveContains("<img"),
                  !snapshot.bodyHTML.localizedCaseInsensitiveContains("<table"), let before = snapshot.plainText else {
                throw ToolError.unavailable("This note cannot be safely renamed. Edit its title directly in Notes.")
            }
            let expected = Self.noteTitleReplacementPlaintext(before, title: title)
            let receipt = try await scripts.call(.notes, handler: "renameCurrent", arguments: [.text(snapshot.id), .text(snapshot.bodyHTML), .text(title)])
            guard receipt.count == 3, receipt[0] == snapshot.id else { throw ToolError.changedTarget }
            return ToolExecution(message: "Note title updated", output: .note(snapshot.id),
                verification: Self.notePlaintext(receipt[1]) == expected && receipt[2] == title ? .verified : .unverified("Notes returned a different title or body; inspect the note."))
        case (.spotifyTransport, .spotify(let action)): return try await spotify(action)
        case (.screenshot, .screenshot(let destination, let displayID)): return try await screenshot(destination: destination, displayID: displayID)
        case (.revealFile, .file(let url)):
            guard FileManager.default.fileExists(atPath: url.path) else { throw ToolError.unavailable("The file or folder does not exist.") }
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return ToolExecution(message: "Reveal requested in Finder", output: .file(url), verification: .unverified("Finder received the reveal request; selection is not read back."))
        default: throw ToolError.invalidArguments
        }
    }

    public static func websiteURL(_ raw: String, registry: SearchProviderRegistry = .shared) -> URL? {
        if let parsed = CommandMode.parseURL(from: raw) { return parsed }
        guard let provider = registry.findProvider(for: raw), let url = provider.searchURL(for: "localflow"),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.path = ""; components.query = nil; components.fragment = nil
        return components.url
    }
    static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    static func htmlBody(_ text: String) -> String { text.components(separatedBy: .newlines).map { "<div>\(escapeHTML($0))</div>" }.joined() }

    private func matches(_ running: NSRunningApplication, _ app: ApplicationMatch) -> Bool {
        if let bundleID = app.bundleIdentifier { return running.bundleIdentifier == bundleID }
        if let url = app.url { return running.bundleURL?.standardizedFileURL == url.standardizedFileURL }
        return false
    }
    private func runningApplication(_ app: ApplicationMatch) -> NSRunningApplication? { NSWorkspace.shared.runningApplications.first { matches($0, app) } }
    private func openApplication(_ app: ApplicationMatch, focusOnly: Bool) async throws -> ToolExecution {
        let before = NSWorkspace.shared.frontmostApplication
        let target: NSRunningApplication
        if let running = runningApplication(app), focusOnly { target = running }
        else {
            // Retain CommandMode's switch-to behavior: launch the installed app when absent.
            guard let url = app.url ?? app.bundleIdentifier.flatMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }),
                  url.isFileURL, url.pathExtension.lowercased() == "app", FileManager.default.fileExists(atPath: url.path),
                  app.bundleIdentifier == nil || Bundle(url: url)?.bundleIdentifier == app.bundleIdentifier else { throw ToolError.unavailable("The application is not installed.") }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            target = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
        if Task.isCancelled {
            return ToolExecution(message: "Application launch requested", output: .application(target.processIdentifier), verification: .unverified("The native request was delivered before cancellation."))
        }
        // A launch request can already have focused the target. A second activate()
        // may return false even though the requested state is observable; read it back.
        let activationAccepted = target.isActive || target.activate(from: .current, options: [])
        for _ in 0..<20 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier { break }
            if Task.isCancelled { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        let verified = NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier
        if !verified && !activationAccepted {
            throw ToolError.unavailable("macOS declined activation of \(app.name). Open it once and retry.")
        }
        let undo: (() async throws -> ToolVerification)?
        if verified, let before, before.processIdentifier != target.processIdentifier, !before.isTerminated {
            undo = {
                guard !before.isTerminated, NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else { throw ToolError.changedTarget }
                guard before.activate(options: []) else { throw ToolError.unavailable("The previous app could not be focused.") }
                for _ in 0..<10 {
                    if NSWorkspace.shared.frontmostApplication?.processIdentifier == before.processIdentifier { return .verified }
                    try await Task.sleep(for: .milliseconds(50))
                }
                return .unverified("Focus restoration requested.")
            }
        } else { undo = nil }
        return ToolExecution(message: verified ? "\(app.name) focused" : "\(app.name) activation requested", output: .application(target.processIdentifier),
                             verification: verified ? .verified : .unverified("Activation has not been observed."), undo: undo)
    }
    private func openURL(_ url: URL, message: String = "Website opened") async throws -> ToolExecution {
        try ToolArguments.url(url).validate(for: .openURL)
        if let preference = preferredBrowser?(), !preference.isEmpty {
            let catalog = LaunchServicesApplicationCatalog().installedApplications()
            let matches = catalog.filter { $0.bundleIdentifier == preference || $0.name.caseInsensitiveCompare(preference) == .orderedSame }
            guard Set(matches.map(\.id)).count == 1, let browser = matches.first,
                  let appURL = browser.url ?? browser.bundleIdentifier.flatMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }) else {
                throw ToolError.unavailable("Preferred browser is not installed. Update Agent settings.")
            }
            try Task.checkCancellation()
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
            return ToolExecution(message: message, output: .openedURL(url), verification: .unverified("The preferred browser accepted the URL; page loading is not verified."))
        }
        guard NSWorkspace.shared.open(url) else { throw ToolError.unavailable("No application accepted the URL.") }
        return ToolExecution(message: message, output: .openedURL(url), verification: .unverified("The browser accepted the URL; page loading is not verified."))
    }
    private func copyText(_ text: String) throws -> ToolExecution {
        let pasteboard = NSPasteboard.general
        let originalItems = pasteboard.pasteboardItems ?? []
        let old = originalItems.map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        }
        let restorable = zip(originalItems, old).allSatisfy { $0.types.count == $1.count }
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string), pasteboard.string(forType: .string) == text else { throw ToolError.unavailable("Clipboard write failed.") }
        let ownedCount = pasteboard.changeCount
        return ToolExecution(message: "Copied to clipboard", output: .clipboard, verification: .verified, undo: restorable ? {
            guard pasteboard.changeCount == ownedCount else { throw ToolError.changedTarget }
            pasteboard.clearContents()
            let items = old.map { values -> NSPasteboardItem in
                let item = NSPasteboardItem(); for (type, data) in values { item.setData(data, forType: type) }; return item
            }
            guard items.isEmpty || pasteboard.writeObjects(items) else { throw ToolError.unavailable("Clipboard restoration failed.") }
            let restored = (pasteboard.pasteboardItems ?? []).map { item in
                Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
            }
            return restored == old ? .verified : .failed("Clipboard restoration could not be verified.")
        } : nil)
    }
    private struct AudioSnapshot: Equatable { let volume: Int; let muted: Bool }
    private func audioSnapshot() async throws -> AudioSnapshot {
        let values = try await scripts.call(.audio, handler: "readAudio", arguments: [])
        guard values.count == 2, let volume = Int(values[0]), (0...100).contains(volume), ["true", "false"].contains(values[1]) else { throw ToolError.unavailable("Audio state could not be read.") }
        return AudioSnapshot(volume: volume, muted: values[1] == "true")
    }
    private func writeAudio(_ state: AudioSnapshot, changeVolume: Bool, changeMuted: Bool) async throws {
        _ = try await scripts.call(.audio, handler: "writeAudio", arguments: [.integer(state.volume), .boolean(state.muted), .boolean(changeVolume), .boolean(changeMuted)])
    }
    private func setAudio(before: AudioSnapshot, after: AudioSnapshot, changeVolume: Bool, changeMuted: Bool) async throws -> ToolExecution {
        try await writeAudio(after, changeVolume: changeVolume, changeMuted: changeMuted)
        let observed = try await audioSnapshot()
        guard (!changeVolume || observed.volume == after.volume), (!changeMuted || observed.muted == after.muted) else { throw ToolError.unavailable("The output device did not accept the audio change.") }
        let restored = AudioSnapshot(volume: changeVolume ? before.volume : observed.volume, muted: changeMuted ? before.muted : observed.muted)
        return ToolExecution(message: observed.muted ? "Audio muted" : "Volume \(observed.volume)%", output: .volume(observed.volume, muted: observed.muted), verification: .verified,
                             undo: restored == observed ? nil : { [self] in
            guard try await audioSnapshot() == observed else { throw ToolError.changedTarget }
            try await writeAudio(restored, changeVolume: changeVolume, changeMuted: changeMuted)
            return try await audioSnapshot() == restored ? .verified : .failed("Audio restoration could not be verified.")
        })
    }
    private static func sleepDisplay() async throws {
        try await Task.detached(priority: .userInitiated) { try runDisplaySleep() }.value
    }
    nonisolated private static func runDisplaySleep() throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset"); task.arguments = ["displaysleepnow"]
        task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
        try task.run()
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        while task.isRunning, DispatchTime.now().uptimeNanoseconds < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if task.isRunning {
            task.terminate()
            throw ToolError.unavailable("The display sleep request timed out.")
        }
        guard task.terminationStatus == 0 else { throw ToolError.unavailable("Display sleep request failed.") }
    }
    private func createReminder(title: String, notes: String?, due: Date?) async throws -> ToolExecution {
        guard try await reminders.requestFullAccessToReminders() else { throw ToolError.permission("Reminders") }
        try Task.checkCancellation()
        guard let calendar = reminders.defaultCalendarForNewReminders(), calendar.allowsContentModifications else { throw ToolError.unavailable("No writable Reminders list is available.") }
        let item = EKReminder(eventStore: reminders)
        item.calendar = calendar; item.title = title; item.notes = notes
        if let due { item.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .timeZone], from: due) }
        try reminders.save(item, commit: true)
        let identifier = item.calendarItemIdentifier
        let calendarID = calendar.calendarIdentifier
        let expectedDue = item.dueDateComponents
        reminders.reset() // Read persisted state, not the object just saved.
        guard let saved = reminders.calendarItem(withIdentifier: identifier) as? EKReminder,
              saved.title == title, saved.notes == notes, saved.dueDateComponents == expectedDue else { throw ToolError.unavailable("Reminder creation could not be verified.") }
        let modified = saved.lastModifiedDate, created = saved.creationDate
        let supportsUndo = modified != nil && created != nil && saved.priority == 0 && saved.location == nil && saved.url == nil
            && saved.startDateComponents == nil && (saved.alarms?.isEmpty ?? true) && (saved.recurrenceRules?.isEmpty ?? true)
        return ToolExecution(message: "Reminder created", output: .reminder(identifier), verification: .verified, undo: supportsUndo ? { [self] in
            reminders.reset() // Invalidate caches before checking edits made by other apps.
            guard let current = reminders.calendarItem(withIdentifier: identifier) as? EKReminder,
                  current.title == title, current.notes == notes, current.dueDateComponents == expectedDue,
                  !current.isCompleted, current.calendar.calendarIdentifier == calendarID,
                  current.lastModifiedDate == modified, current.creationDate == created,
                  current.priority == 0, current.location == nil, current.url == nil, current.startDateComponents == nil,
                  (current.alarms?.isEmpty ?? true), (current.recurrenceRules?.isEmpty ?? true) else { throw ToolError.changedTarget }
            try reminders.remove(current, commit: true)
            reminders.reset()
            return reminders.calendarItem(withIdentifier: identifier) == nil ? .verified : .failed("Reminder removal could not be verified.")
        } : nil)
    }
    /// Notes adds one terminal line feed to its plaintext API. Preserve every other byte,
    /// including internal blank lines, indentation, punctuation and trailing spaces.
    static func notePlaintext(_ text: String) -> String { text.hasSuffix("\n") ? String(text.dropLast()) : text }
    static func noteTitleReplacementPlaintext(_ before: String, title: String) -> String {
        let plain = notePlaintext(before)
        return title + (plain.firstIndex(of: "\n").map { String(plain[$0...]) } ?? "")
    }
    private func spotify(_ action: SpotifyPlaybackAction) async throws -> ToolExecution {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") != nil else { throw ToolError.unavailable("Spotify is not installed.") }
        let before = await SpotifyPlaybackVerifier.snapshot()
        try Task.checkCancellation()
        guard await Task.detached(priority: .userInitiated, operation: { SpotifyPlaybackController.perform(action) }).value else {
            if await NativePermissionReadiness.automationStatus(bundleIdentifier: "com.spotify.client") == -1743 {
                throw ToolError.permission("Automation → Spotify")
            }
            throw ToolError.unavailable("Spotify did not accept the playback command.")
        }
        for _ in 0..<8 {
            let after = await SpotifyPlaybackVerifier.snapshot()
            if SpotifyTransportPolicy.verified(action, before: before, after: after) {
                let undo: (() async throws -> ToolVerification)?
                if let before, let after, let inverse = SpotifyTransportPolicy.undoAction(action, before: before, after: after) {
                    undo = {
                        guard let current = await SpotifyPlaybackVerifier.snapshot(),
                              current.state.caseInsensitiveCompare(after.state) == .orderedSame,
                              current.trackIdentifier == after.trackIdentifier else { throw ToolError.changedTarget }
                        guard await Task.detached(priority: .userInitiated, operation: { SpotifyPlaybackController.perform(inverse) }).value else { throw ToolError.unavailable("Spotify did not accept Undo.") }
                        for _ in 0..<8 {
                            if let restored = await SpotifyPlaybackVerifier.snapshot(), restored.trackIdentifier == before.trackIdentifier,
                               restored.state.caseInsensitiveCompare(before.state) == .orderedSame { return .verified }
                            if Task.isCancelled { break }
                            try? await Task.sleep(for: .milliseconds(125))
                        }
                        return .unverified("Spotify Undo was sent; playback state could not be verified.")
                    }
                } else { undo = nil }
                return ToolExecution(message: "Spotify updated", output: .media, verification: .verified, undo: undo)
            }
            if Task.isCancelled { break }
            try? await Task.sleep(for: .milliseconds(125))
        }
        return ToolExecution(message: "Spotify command sent", output: .media, verification: .unverified("Spotify playback change could not be verified."))
    }
    private func screenshot(destination: URL?, displayID: UInt32?) async throws -> ToolExecution {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else { throw ToolError.permission("Screen Recording") }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard let display = content.displays.first(where: { $0.displayID == (displayID ?? CGMainDisplayID()) }) else { throw ToolError.unavailable("The requested display is unavailable.") }
        let island = content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier && $0.title == "LocalFlow Island" }
        let filter = SCContentFilter(display: display, excludingWindows: island)
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(filter.contentRect.width * CGFloat(filter.pointPixelScale)))
        configuration.height = max(1, Int(filter.contentRect.height * CGFloat(filter.pointPixelScale)))
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        try Task.checkCancellation()
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LocalFlow/Screenshots", isDirectory: true)
        if destination == nil { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let output = destination ?? directory.appendingPathComponent("Screenshot-\(UUID().uuidString).png")
        let data = try await Task.detached(priority: .utility) { () throws -> Data in
            let buffer = NSMutableData()
            guard let encoder = CGImageDestinationCreateWithData(buffer, UTType.png.identifier as CFString, 1, nil) else { throw ToolError.unavailable("PNG encoding failed.") }
            CGImageDestinationAddImage(encoder, image, nil)
            guard CGImageDestinationFinalize(encoder) else { throw ToolError.unavailable("PNG encoding failed.") }
            return buffer as Data
        }.value
        try Task.checkCancellation()
        let revision = try await Task.detached(priority: .utility) {
            // O_EXCL through withoutOverwriting protects existing files and symlinks.
            try data.write(to: output, options: .withoutOverwriting)
            guard let source = CGImageSourceCreateWithURL(output as CFURL, nil), CGImageSourceGetCount(source) == 1 else { throw ToolError.unavailable("Screenshot readback failed.") }
            return try NativeFileRevision(url: output)
        }.value
        return ToolExecution(message: "Screenshot saved", output: .file(output), verification: .verified, undo: {
            try await Task.detached(priority: .utility) { try NativeFileUndo.remove(url: output, revision: revision, data: data) }.value
        })
    }
}

/// Only fixed handlers can execute. User text travels as Apple Event descriptors, never script source.
protocol NativeScriptCalling: Sendable {
    func call(_ kind: NativeScriptRunner.Script, handler: String, arguments: [NativeScriptRunner.Value]) async throws -> [String]
}
actor NativeScriptRunner: NativeScriptCalling {
    enum Value: Equatable, Sendable { case text(String), integer(Int), boolean(Bool) }
    enum Script: Hashable, Sendable { case audio, notes }
    private var compiled: [Script: NSAppleScript] = [:]
    func call(_ kind: Script, handler: String, arguments: [Value]) throws -> [String] {
        try Task.checkCancellation()
        let script: NSAppleScript
        var error: NSDictionary?
        if let cached = compiled[kind] { script = cached }
        else {
            guard let created = NSAppleScript(source: Self.source(for: kind)), created.compileAndReturnError(&error) else { throw ToolError.unavailable("Native automation could not be compiled.") }
            compiled[kind] = created
            script = created
        }
        let event = try Self.invocation(handler: handler, arguments: arguments)
        try Task.checkCancellation()
        let result = script.executeAppleEvent(event, error: &error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int
            if code == -1743 { throw ToolError.permission(kind == .notes ? "Automation → Notes" : "Automation for system audio") }
            if code == -1712 {
                throw ToolError.unavailable(kind == .notes
                    ? "Notes did not respond within 5 seconds. Open Notes, dismiss any setup or account dialog, then retry. Completion could not be verified."
                    : "System audio did not respond within 5 seconds. Retry the command. Completion could not be verified.")
            }
            if code == -1728 && kind == .notes {
                throw ToolError.unavailable("Notes could not resolve the requested note or folder. Open Notes and select a valid note. Completion could not be verified.")
            }
            // Do not include errors containing private note/text contents in logs or UI.
            throw ToolError.unavailable(code == -2700 ? "The selected note changed, is locked, shared, or has attachments." : "Native automation failed (\(code ?? 0)).")
        }
        guard result.numberOfItems > 0 else { return [] }
        return (1...result.numberOfItems).compactMap { result.atIndex($0)?.stringValue }
    }
    static func invocation(handler: String, arguments: [Value]) throws -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor.appleEvent(withEventClass: AEEventClass(kASAppleScriptSuite), eventID: AEEventID(kASSubroutineEvent), targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: handler.lowercased()), forKeyword: AEKeyword(keyASSubroutineName))
        let list = NSAppleEventDescriptor.list()
        for (offset, value) in arguments.enumerated() {
            let descriptor: NSAppleEventDescriptor
            switch value {
            case .text(let text): descriptor = NSAppleEventDescriptor(string: text)
            case .integer(let number):
                guard let integer = Int32(exactly: number) else { throw ToolError.invalidArguments }
                descriptor = NSAppleEventDescriptor(int32: integer)
            case .boolean(let flag): descriptor = NSAppleEventDescriptor(boolean: flag)
            }
            list.insert(descriptor, at: offset + 1)
        }
        event.setParam(list, forKeyword: AEKeyword(keyDirectObject))
        return event
    }
    static func source(for kind: Script) -> String { kind == .audio ? audio : notes }
    private static let audio = """
    on readAudio()
        set settings to get volume settings
        return {(output volume of settings) as text, (output muted of settings) as text}
    end readAudio
    on writeAudio(amount, mutedFlag, changeVolume, changeMuted)
        if changeVolume then set volume output volume amount
        if changeMuted then set volume output muted mutedFlag
        return {}
    end writeAudio
    """
    private static let notes = """
    on captureCurrent()
        with timeout of 5 seconds
            tell application id "com.apple.Notes"
                set chosen to selection
                if (count chosen) is not 1 then error "Unsafe selection" number -2700
                set n to item 1 of chosen
                if password protected of n or shared of n or (count attachments of n) > 0 then error "Unsafe note" number -2700
                return {id of n, body of n, plaintext of n}
            end tell
        end timeout
    end captureCurrent
    on createNote(htmlText)
        with timeout of 5 seconds
            tell application id "com.apple.Notes"
                set destination to default folder of default account
                if shared of destination then error "Shared folder" number -2700
                set destinationID to id of destination
                set n to make new note at destination with properties {body:htmlText}
                show n
                return {id of n, body of n, plaintext of n, destinationID}
            end tell
        end timeout
    end createNote
    on undoCreated(expectedID, expectedBody, expectedFolder)
        with timeout of 5 seconds
            tell application id "com.apple.Notes"
                set destination to folder id expectedFolder
                if not (exists (note id expectedID of destination)) then error "Moved note" number -2700
                set n to note id expectedID of destination
                considering case, diacriticals, hyphens, punctuation, white space
                    if body of n is not expectedBody or shared of n or password protected of n or (count attachments of n) > 0 then error "Changed note" number -2700
                end considering
                delete n
                -- Notes retains deleted objects in Recently Deleted. Verify removal
                -- from the exact original folder, preserving normal recoverability.
                if exists (note id expectedID of destination) then error "Removal not verified" number -2700
                return {}
            end tell
        end timeout
    end undoCreated
    on updateCurrent(expectedID, expectedBody, newBody)
        with timeout of 5 seconds
            tell application id "com.apple.Notes"
                set chosen to selection
                if (count chosen) is not 1 then error "Unsafe selection" number -2700
                set n to item 1 of chosen
                considering case, diacriticals, hyphens, punctuation, white space
                    if id of n is not expectedID or body of n is not expectedBody then error "Changed note" number -2700
                end considering
                if password protected of n or shared of n or (count attachments of n) > 0 then error "Unsafe note" number -2700
                set body of n to newBody
                return {id of n, body of n, plaintext of n}
            end tell
        end timeout
    end updateCurrent
    on renameCurrent(expectedID, expectedBody, newTitle)
        with timeout of 5 seconds
            tell application id "com.apple.Notes"
                set chosen to selection
                if (count chosen) is not 1 then error "Unsafe selection" number -2700
                set n to item 1 of chosen
                considering case, diacriticals, hyphens, punctuation, white space
                    if id of n is not expectedID or body of n is not expectedBody then error "Changed note" number -2700
                end considering
                if password protected of n or shared of n or (count attachments of n) > 0 then error "Unsafe note" number -2700
                set name of n to newTitle
                return {id of n, plaintext of n, name of n}
            end tell
        end timeout
    end renameCurrent
    """
}
