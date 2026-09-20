import AppKit
import ApplicationServices
import Foundation
import Shared

/// Locally controls the installed Spotify desktop app with its published AppleScript player
/// controls and its Accessibility tree. It never requires Spotify credentials or a Web API.
public enum SpotifyPlaybackAction: Equatable, Sendable {
    case resume
    case pause
    case next
    case previous
}

public enum SpotifyPlaybackController {
    private enum SearchFailure: LocalizedError {
        case accessibilityNotGranted, spotifyNotRunning, resultNotExposed
        var errorDescription: String? {
            switch self {
            case .accessibilityNotGranted: return "Accessibility permission is required to play Spotify search results."
            case .spotifyNotRunning: return "Spotify did not open."
            case .resultNotExposed: return "Spotify did not expose a playable search result."
            }
        }
    }
    /// Sends a fixed AppleScript command to Spotify. The command text never contains user input.
    @discardableResult
    public static func perform(_ action: SpotifyPlaybackAction) -> Bool {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") != nil else {
            return false
        }

        let command: String
        switch action {
        case .resume: command = "play"
        case .pause: command = "pause"
        case .next: command = "next track"
        case .previous: command = "previous track"
        }

        let source = """
        tell application id "com.spotify.client"
            \(command)
        end tell
        """
        var error: NSDictionary?
        return NSAppleScript(source: source)?.executeAndReturnError(&error) != nil
    }

    /// Opens Spotify's native search, then presses the first accessible result play button.
    ///
    /// The desktop app exposes player controls through AppleScript but does not provide a
    /// "search by name and play" command. Accessibility UI automation lets LocalFlow use the
    /// same top result the user sees, with the search screen kept intact as a safe fallback when
    /// Spotify does not expose an actionable result button on a particular app version.
    public static func searchAndPlayTopResult(query: String, searchURL: URL) {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") != nil else {
            NSWorkspace.shared.open(searchURL)
            return
        }

        Task { @MainActor in
            do {
                try await openAndPlayTopSearchResult(query: query, searchURL: searchURL)
                AgentDebugLog.write(hypothesisId: "spotify", location: "SpotifyPlaybackController", message: "Pressed accessible top search result", data: ["query": query])
            } catch {
                AgentDebugLog.write(hypothesisId: "spotify", location: "SpotifyPlaybackController", message: "Could not play search result", data: ["query": query, "error": error.localizedDescription])
            }
        }
    }

    @MainActor
    private static func openAndPlayTopSearchResult(query: String, searchURL: URL) async throws {
        guard AXIsProcessTrusted() else { throw SearchFailure.accessibilityNotGranted }
        guard NSWorkspace.shared.open(searchURL) else { throw SearchFailure.spotifyNotRunning }

        // Spotify renders results asynchronously. Poll its semantic tree rather than sleeping or
        // clicking screen coordinates; the first usable matching result is the one the user sees.
        for _ in 0..<18 {
            guard let spotify = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.spotify.client" }),
                  !spotify.isTerminated else {
                try await Task.sleep(nanoseconds: 150_000_000)
                continue
            }
            _ = spotify.activate(options: [.activateAllWindows])
            if pressTopSearchResult(in: spotify, matching: query) { return }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        throw SearchFailure.resultNotExposed
    }

    private static func pressTopSearchResult(in spotify: NSRunningApplication, matching query: String) -> Bool {
        let root = AXUIElementCreateApplication(spotify.processIdentifier)
        var candidates: [(element: AXUIElement, score: Int)] = []
        collectPlayButtons(from: root, depth: 0, context: "", matching: query.lowercased(), into: &candidates)

        guard let candidate = candidates.max(by: { $0.score < $1.score }) else {
            return false
        }
        return AXUIElementPerformAction(candidate.element, kAXPressAction as CFString) == .success
    }

    private static func collectPlayButtons(
        from element: AXUIElement,
        depth: Int,
        context: String,
        matching query: String,
        into candidates: inout [(element: AXUIElement, score: Int)]
    ) {
        guard depth < 10 else { return }

        let role = stringAttribute(kAXRoleAttribute as String, from: element) ?? ""
        let ownLabel = [
            stringAttribute(kAXTitleAttribute as String, from: element),
            stringAttribute(kAXDescriptionAttribute as String, from: element),
            stringAttribute(kAXHelpAttribute as String, from: element)
        ].compactMap { $0 }.joined(separator: " ")
        let semanticContext = "\(context) \(ownLabel)".lowercased()
        if role == kAXButtonRole as String {
            let label = [
                stringAttribute(kAXTitleAttribute as String, from: element),
                stringAttribute(kAXDescriptionAttribute as String, from: element),
                stringAttribute(kAXHelpAttribute as String, from: element)
            ]
            .compactMap { $0 }
            .joined(separator: " ").lowercased()

            if label.contains("play"), actionNames(of: element).contains(kAXPressAction as String) {
                // Prefer labels tied to the spoken name. Generic player-bar play controls are
                // deliberately ignored until a semantic result button is actually exposed.
                let queryWords = query.split(whereSeparator: \.isWhitespace).map(String.init)
                let matches = queryWords.filter { semanticContext.contains($0) }.count
                if matches > 0 { candidates.append((element, matches)) }
            }
        }

        for attribute in [kAXChildrenAttribute, kAXVisibleChildrenAttribute, kAXContentsAttribute] {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
                  let children = value as? [AXUIElement]
            else { continue }
            for child in children {
                collectPlayButtons(from: child, depth: depth + 1, context: semanticContext, matching: query, into: &candidates)
            }
        }
    }

    private static func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func actionNames(of element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }
}
