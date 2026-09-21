import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import OSLog

public enum SpotifyPlaybackAction: Equatable, Sendable {
    case resume, pause, next, previous
}

public enum SpotifyPlaybackProgress: Equatable, Sendable {
    case searching, startingPlayback
}

public enum SpotifyPlaybackOutcome: Equatable, Sendable {
    case verified(track: String?, artist: String?)
    case commandSentUnverified
    case accessibilityRequired
    case spotifyUnavailable
    case activationFailed
    case resultNotFound
    case playbackNotVerified
    case alreadyInProgress
}

struct SpotifyPlaybackSnapshot: Equatable, Sendable {
    let state: String
    let trackName: String?
    let artist: String?
    let album: String?
    let trackIdentifier: String?
    let position: Double?
    var isPlaying: Bool { state.caseInsensitiveCompare("playing") == .orderedSame }
}

enum SpotifyActivationStrategy: String, Sendable {
    case accessibilityPress = "AXPress"
    case keyboard = "Keyboard"
}

enum SpotifyPlaybackVerifier {
    enum Verification: Sendable {
        case verified(SpotifyPlaybackSnapshot)
        case notVerified
        case unavailable
    }

    static func snapshot() async -> SpotifyPlaybackSnapshot? {
        await Task.detached(priority: .utility) {
            let source = """
            tell application id "com.spotify.client"
                if it is not running then return ""
                set fieldSeparator to ASCII character 30
                set stateText to (player state as text)
                set trackName to ""
                set artistName to ""
                set albumName to ""
                set trackID to ""
                set positionText to ""
                try
                    set currentItem to current track
                    set trackName to name of currentItem
                    set artistName to artist of currentItem
                    set albumName to album of currentItem
                    set trackID to spotify url of currentItem
                    set positionText to (player position as text)
                end try
                return stateText & fieldSeparator & trackName & fieldSeparator & artistName & fieldSeparator & albumName & fieldSeparator & trackID & fieldSeparator & positionText
            end tell
            """
            var error: NSDictionary?
            guard let value = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue,
                  !value.isEmpty else { return nil }
            let fields = value.components(separatedBy: String(UnicodeScalar(30)))
            guard let state = fields.first, !state.isEmpty else { return nil }
            func field(_ index: Int) -> String? {
                guard fields.indices.contains(index), !fields[index].isEmpty else { return nil }
                return fields[index]
            }
            return SpotifyPlaybackSnapshot(
                state: state,
                trackName: field(1),
                artist: field(2),
                album: field(3),
                trackIdentifier: field(4),
                position: field(5).flatMap(Double.init)
            )
        }.value
    }

    static func waitForPlayback(
        before: SpotifyPlaybackSnapshot?,
        query: String,
        timeoutNanoseconds: UInt64 = 2_500_000_000
    ) async -> Verification {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        var observedMetadata = false
        var priorSample: SpotifyPlaybackSnapshot?
        while DispatchTime.now().uptimeNanoseconds < deadline {
            guard !Task.isCancelled else { return .notVerified }
            if let sample = await snapshot() {
                observedMetadata = true
                if isVerified(before: before, after: sample, priorSample: priorSample, query: query) {
                    return .verified(sample)
                }
                priorSample = sample
            }
            try? await Task.sleep(nanoseconds: 140_000_000)
        }
        return observedMetadata ? .notVerified : .unavailable
    }

    static func isVerified(
        before: SpotifyPlaybackSnapshot?,
        after: SpotifyPlaybackSnapshot,
        priorSample: SpotifyPlaybackSnapshot?,
        query: String
    ) -> Bool {
        guard after.isPlaying else { return false }
        if let before {
            let identifierChanged = nonempty(before.trackIdentifier) != nonempty(after.trackIdentifier)
            let metadataChanged = normalized(before.trackName) != normalized(after.trackName)
                || normalized(before.artist) != normalized(after.artist)
            if identifierChanged || metadataChanged { return true }
            if !before.isPlaying { return true }
        }
        let metadata = [after.trackName, after.artist].compactMap { $0 }.joined(separator: " ")
        if queryMatchScore(query: query, candidate: metadata) >= 0.5 { return true }
        if let priorSample,
           priorSample.isPlaying,
           normalized(priorSample.trackIdentifier) == normalized(after.trackIdentifier),
           let firstPosition = priorSample.position,
           let secondPosition = after.position,
           secondPosition > firstPosition + 0.05,
           queryMatchScore(query: query, candidate: metadata) >= 0.5 { return true }
        return false
    }

    static func queryMatchScore(query: String, candidate: String) -> Double {
        let queryTokens = significantTokens(query)
        guard !queryTokens.isEmpty else { return 0 }
        let candidateTokens = Set(significantTokens(candidate))
        return Double(queryTokens.filter(candidateTokens.contains).count) / Double(queryTokens.count)
    }

    private static func significantTokens(_ value: String) -> [String] {
        value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 && !["play", "spotify", "song", "track", "by", "on", "in", "the"].contains($0) }
    }

    private static func normalized(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

@MainActor
private final class SpotifyAutomationService {
    private static let bundleIdentifier = "com.spotify.client"

    struct SearchResults {
        let firstActionableElement: AXUIElement?
        let keyboardNavigationReady: Bool
    }

    private struct AccessibilityNode {
        let element: AXUIElement
        let role: String
        let label: String
        let context: String
        let enabled: Bool
        let actions: [String]
        let traversalIndex: Int
    }

    func activateSpotify() async -> NSRunningApplication? {
        var running = NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == Self.bundleIdentifier && !$0.isTerminated
        }
        if running == nil {
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier) else {
                return nil
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            running = try? await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        }
        guard let spotify = running, !spotify.isTerminated else { return nil }
        _ = spotify.activate(options: [.activateAllWindows])
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == spotify.processIdentifier { return spotify }
            try? await Task.sleep(nanoseconds: 75_000_000)
        }
        return nil
    }

    func prepareQuickSearch(in spotify: NSRunningApplication, query: String) async -> Bool {
        if let focused = focusedElement(in: spotify.processIdentifier), isEditableSearchElement(focused) {
            return await replaceSearchQuery(query, in: focused)
        }
        for attempt in 0..<2 {
            guard postKey(CGKeyCode(kVK_ANSI_K), flags: .maskCommand) else { return false }
            if let focused = await waitForEditableSearch(in: spotify.processIdentifier),
               await replaceSearchQuery(query, in: focused) { return true }
            if attempt == 0 { try? await Task.sleep(nanoseconds: 100_000_000) }
        }
        return false
    }

    func waitForResults(in spotify: NSRunningApplication, query: String) async -> SearchResults? {
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_500_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            guard !Task.isCancelled else { return nil }
            if let result = resultState(from: accessibilityNodes(in: spotify.processIdentifier), query: query) {
                return result
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    func activateFirstResult(_ results: SearchResults, strategy: SpotifyActivationStrategy) async -> Bool {
        switch strategy {
        case .accessibilityPress:
            guard let element = results.firstActionableElement else { return false }
            for attempt in 0..<3 {
                let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
                if result == .success { return true }
                guard result == .cannotComplete, attempt < 2 else { return false }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            return false
        case .keyboard:
            guard results.keyboardNavigationReady,
                  postKey(CGKeyCode(kVK_DownArrow), flags: []) else { return false }
            try? await Task.sleep(nanoseconds: 90_000_000)
            // Spotify Quick Search labels Return as “Open” and Shift-Return as “Play”.
            // Move focus from the editable search field into the ready result list before using
            // that shortcut. Activating with plain Return is the original failure mode: Spotify
            // opens the result, but the track never starts.
            return postKey(CGKeyCode(kVK_Return), flags: .maskShift)
        }
    }

    private func waitForEditableSearch(in pid: pid_t) async -> AXUIElement? {
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_100_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if let element = focusedElement(in: pid), isEditableSearchElement(element) { return element }
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
        return nil
    }

    private func replaceSearchQuery(_ query: String, in element: AXUIElement) async -> Bool {
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue,
           AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, query as CFString) == .success {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
               let current = value as? String,
               current.trimmingCharacters(in: .whitespacesAndNewlines) == query.trimmingCharacters(in: .whitespacesAndNewlines) {
                return true
            }
        }
        return await pasteReplacingExistingQuery(query)
    }

    private func pasteReplacingExistingQuery(_ query: String) async -> Bool {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard)
        pasteboard.clearContents()
        guard pasteboard.setString(query, forType: .string) else { return false }
        let transactionChangeCount = pasteboard.changeCount
        guard postKey(CGKeyCode(kVK_ANSI_A), flags: .maskCommand),
              postKey(CGKeyCode(kVK_ANSI_V), flags: .maskCommand) else {
            if pasteboard.changeCount == transactionChangeCount { snapshot.restore(to: pasteboard) }
            return false
        }
        try? await Task.sleep(nanoseconds: 220_000_000)
        if pasteboard.changeCount == transactionChangeCount { snapshot.restore(to: pasteboard) }
        return true
    }

    private struct PasteboardSnapshot {
        let items: [NSPasteboardItem]
        init(_ pasteboard: NSPasteboard) {
            items = (pasteboard.pasteboardItems ?? []).map { source in
                let copy = NSPasteboardItem()
                for type in source.types {
                    if let data = source.data(forType: type) { copy.setData(data, forType: type) }
                }
                return copy
            }
        }
        func restore(to pasteboard: NSPasteboard) {
            pasteboard.clearContents()
            if !items.isEmpty { pasteboard.writeObjects(items) }
        }
    }

    private func focusedElement(in pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value else { return nil }
        return (value as! AXUIElement)
    }

    private func isEditableSearchElement(_ element: AXUIElement) -> Bool {
        let role = stringAttribute(kAXRoleAttribute as String, from: element) ?? ""
        let subrole = stringAttribute(kAXSubroleAttribute as String, from: element) ?? ""
        let label = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXPlaceholderValueAttribute]
            .compactMap { stringAttribute($0 as String, from: element) }.joined(separator: " ").lowercased()
        let textRole = role == kAXTextFieldRole as String || role == kAXTextAreaRole as String
            || role == kAXComboBoxRole as String || subrole.lowercased().contains("search")
        var settable = DarwinBoolean(false)
        let canSetValue = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success
            && settable.boolValue
        return textRole && (canSetValue || label.contains("search"))
    }

    private func accessibilityNodes(in pid: pid_t) -> [AccessibilityNode] {
        let app = AXUIElementCreateApplication(pid)
        var windowValue: CFTypeRef?
        let root: AXUIElement
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
           let windowValue { root = (windowValue as! AXUIElement) } else { root = app }
        var result: [AccessibilityNode] = []
        var visited = Set<CFHashCode>()
        collectNodes(from: root, depth: 0, ancestorContext: "", visited: &visited, result: &result)
        return result
    }

    private func collectNodes(
        from element: AXUIElement,
        depth: Int,
        ancestorContext: String,
        visited: inout Set<CFHashCode>,
        result: inout [AccessibilityNode]
    ) {
        guard depth <= 9, result.count < 420, visited.insert(CFHash(element)).inserted else { return }
        let ownLabel = labels(of: element)
        let context = [ancestorContext, ownLabel].filter { !$0.isEmpty }.joined(separator: " ")
        result.append(AccessibilityNode(
            element: element,
            role: stringAttribute(kAXRoleAttribute as String, from: element) ?? "",
            label: ownLabel,
            context: context,
            enabled: boolAttribute(kAXEnabledAttribute as String, from: element) ?? true,
            actions: actionNames(of: element),
            traversalIndex: result.count
        ))
        for child in children(of: element).prefix(80) {
            collectNodes(from: child, depth: depth + 1, ancestorContext: context, visited: &visited, result: &result)
            if result.count >= 420 { break }
        }
    }

    private func resultState(from nodes: [AccessibilityNode], query: String) -> SearchResults? {
        let excluded = ["pause", "next", "previous", "back", "forward", "close", "clear", "home"]
        var ranked: [(node: AccessibilityNode, score: Int)] = []
        var semanticEvidence = false
        for node in nodes {
            let label = node.label.lowercased()
            let context = node.context.lowercased()
            let match = SpotifyPlaybackVerifier.queryMatchScore(query: query, candidate: "\(label) \(context)")
            let resultRole = node.role == kAXRowRole as String || node.role == "AXLink"
                || node.role == kAXGroupRole as String || node.role == kAXButtonRole as String
            if match > 0, resultRole { semanticEvidence = true }
            guard node.enabled, node.actions.contains(kAXPressAction as String), resultRole,
                  !excluded.contains(where: { label == $0 || label.hasPrefix("\($0) ") }) else { continue }
            var score = Int(match * 100)
            if node.role == kAXRowRole as String { score += 55 }
            if node.role == "AXLink" { score += 45 }
            if node.role == kAXButtonRole as String { score += 20 }
            if label.contains("play") { score += 80 }
            if context.contains(query.lowercased()) { score += 35 }
            score -= min(node.traversalIndex / 12, 30)
            if match > 0 || label.contains("play") { ranked.append((node, score)) }
        }
        let candidate = ranked.max {
            $0.score == $1.score
                ? $0.node.traversalIndex > $1.node.traversalIndex
                : $0.score < $1.score
        }?.node.element
        guard candidate != nil || semanticEvidence else { return nil }
        return SearchResults(firstActionableElement: candidate, keyboardNavigationReady: true)
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        for attribute in [kAXChildrenAttribute, kAXVisibleChildrenAttribute, kAXContentsAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
               let children = value as? [AXUIElement], !children.isEmpty { return children }
        }
        return []
    }

    private func labels(of element: AXUIElement) -> String {
        [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXValueAttribute]
            .compactMap { stringAttribute($0 as String, from: element) }.joined(separator: " ")
    }

    private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func boolAttribute(_ attribute: String, from element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? Bool
    }

    private func actionNames(of element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    private func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return false }
        source.localEventsSuppressionInterval = 0
        down.flags = flags
        up.flags = flags
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
        return true
    }
}

/// Coordinates native Spotify search, first-result activation, and playback verification.
public enum SpotifyPlaybackController {
    private static let log = Logger(subsystem: "dev.localflow.LocalFlow", category: "Spotify")
    @MainActor
    private static var searchInProgress = false

    @discardableResult
    public static func perform(_ action: SpotifyPlaybackAction) -> Bool {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") != nil else { return false }
        let command: String
        switch action {
        case .resume: command = "play"
        case .pause: command = "pause"
        case .next: command = "next track"
        case .previous: command = "previous track"
        }
        let source = "tell application id \"com.spotify.client\" to \(command)"
        var error: NSDictionary?
        return NSAppleScript(source: source)?.executeAndReturnError(&error) != nil
    }

    @MainActor
    public static func searchAndPlayTopResult(
        query: String,
        progress: @escaping @MainActor (SpotifyPlaybackProgress) -> Void
    ) async -> SpotifyPlaybackOutcome {
        guard !searchInProgress else {
            log.notice("request-suppressed reason=already-in-progress")
            return .alreadyInProgress
        }
        searchInProgress = true
        defer { searchInProgress = false }

        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return .resultNotFound }
        log.info("play-command query-length=\(query.count, privacy: .public)")
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") != nil else {
            log.error("final=failure stage=installation reason=not-installed")
            return .spotifyUnavailable
        }
        guard AXIsProcessTrusted() else {
            log.error("final=failure stage=permission reason=accessibility")
            return .accessibilityRequired
        }

        progress(.searching)
        let automation = SpotifyAutomationService()
        guard let spotify = await automation.activateSpotify() else {
            log.error("final=failure stage=activation reason=not-frontmost")
            return .activationFailed
        }
        log.info("spotify-frontmost=true")
        let before = await SpotifyPlaybackVerifier.snapshot()
        var firstStrategy: SpotifyActivationStrategy?

        for attempt in 0..<2 {
            guard !Task.isCancelled else { return .playbackNotVerified }
            guard await automation.prepareQuickSearch(in: spotify, query: query) else {
                log.error("attempt=\(attempt + 1, privacy: .public) stage=quick-search result=failure")
                continue
            }
            log.info("attempt=\(attempt + 1, privacy: .public) quick-search-focused=true query-inserted=true")
            guard let results = await automation.waitForResults(in: spotify, query: query) else {
                log.error("attempt=\(attempt + 1, privacy: .public) stage=result-readiness result=timeout")
                continue
            }
            log.info("attempt=\(attempt + 1, privacy: .public) result-tree-ready=true actionable=\(results.firstActionableElement != nil, privacy: .public)")

            let strategy: SpotifyActivationStrategy
            if attempt == 0 {
                strategy = results.firstActionableElement == nil ? .keyboard : .accessibilityPress
                firstStrategy = strategy
            } else {
                strategy = firstStrategy == .accessibilityPress ? .keyboard : .accessibilityPress
                if strategy == .accessibilityPress, results.firstActionableElement == nil { continue }
            }

            progress(.startingPlayback)
            guard await automation.activateFirstResult(results, strategy: strategy) else {
                log.error("attempt=\(attempt + 1, privacy: .public) stage=result-activation strategy=\(strategy.rawValue, privacy: .public) result=failure")
                continue
            }
            log.info("attempt=\(attempt + 1, privacy: .public) activation-strategy=\(strategy.rawValue, privacy: .public) result=sent")
            switch await SpotifyPlaybackVerifier.waitForPlayback(before: before, query: query) {
            case .verified(let snapshot):
                log.info("final=success player-state=playing")
                return .verified(track: snapshot.trackName, artist: snapshot.artist)
            case .unavailable:
                log.notice("final=unverified reason=local-scripting-unavailable")
                return .commandSentUnverified
            case .notVerified:
                log.error("attempt=\(attempt + 1, privacy: .public) stage=playback-verification result=failure")
            }
        }
        log.error("final=failure stage=playback-verification reason=exhausted-attempts")
        return .playbackNotVerified
    }
}
