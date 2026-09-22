import AppKit
import Carbon.HIToolbox
import Foundation
import Shared

/// A parsed voice command.
public enum CommandIntent: Equatable, Sendable {
    case openApplication(ApplicationMatch)
    case quitApplication(ApplicationMatch)
    case switchToApplication(ApplicationMatch)
    case mute
    case unmute
    case sleepDisplay
    case lockScreen
    case spotifyControl(SpotifyPlaybackAction)
    case spotifySearchAndPlay(query: String, url: URL)
    case openURL(URL)
    case searchWeb(query: String, providerName: String, url: URL)
}

/// A candidate application match for a command utterance.
public struct ApplicationMatch: Equatable, Identifiable, Sendable {
    /// The stable identifier for UI lists.
    public var id: String { bundleIdentifier ?? name }

    /// The app display name.
    public var name: String

    /// The app bundle identifier, if known.
    public var bundleIdentifier: String?

    /// The app URL, if known.
    public var url: URL?

    /// Confidence from 0 to 1.
    public var confidence: Double

    /// Creates an app match.
    public init(name: String, bundleIdentifier: String?, url: URL?, confidence: Double) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.url = url
        self.confidence = confidence
    }
}

/// The result of command parsing.
public enum CommandResolution: Equatable, Sendable {
    case notCommand
    case execute(CommandIntent)
    case needsConfirmation(CommandIntent)
}

/// Enumerates installed applications for command matching.
public protocol ApplicationCatalog {
    /// Returns known installed applications.
    func installedApplications() -> [ApplicationMatch]
}

/// A LaunchServices-backed application catalog.
public struct LaunchServicesApplicationCatalog: ApplicationCatalog {
    /// Creates a LaunchServices catalog.
    public init() {}

    /// Returns installed applications found in common application directories.
    public func installedApplications() -> [ApplicationMatch] {
        let directories = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]
        let resourceKeys: [URLResourceKey] = [.isApplicationKey, .localizedNameKey]
        return directories.flatMap { directory in
            (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: resourceKeys)) ?? []
        }
        .filter { ($0.pathExtension as NSString).caseInsensitiveCompare("app") == .orderedSame }
        .map { url in
            let bundle = Bundle(url: url)
            let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url.deletingPathExtension().lastPathComponent
            return ApplicationMatch(name: name, bundleIdentifier: bundle?.bundleIdentifier, url: url, confidence: 1)
        }
    }
}

/// Parses and executes voice commands.
public final class CommandMode {
    /// Minimum confidence required for automatic execution.
    public let highConfidenceThreshold: Double

    private let catalog: ApplicationCatalog
    private let searchRegistry: SearchProviderRegistry

    /// Creates a command mode service.
    public init(
        catalog: ApplicationCatalog = LaunchServicesApplicationCatalog(),
        searchRegistry: SearchProviderRegistry = .shared,
        highConfidenceThreshold: Double = 0.82
    ) {
        self.catalog = catalog
        self.searchRegistry = searchRegistry
        self.highConfidenceThreshold = highConfidenceThreshold
    }

    /// Resolves a transcript into dictation or a command action.
    public func resolve(_ transcript: String, transcriptionConfidence: Float? = nil) -> CommandResolution {
        let normalized = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = normalized.lowercased()
        let commandPhrase = Self.removingTerminalPunctuation(from: lower)
        guard !lower.isEmpty else { return .notCommand }

        if commandPhrase == "mute" { return .execute(.mute) }
        if commandPhrase == "unmute" { return .execute(.unmute) }
        if commandPhrase == "sleep display" { return .execute(.sleepDisplay) }
        if commandPhrase == "lock it" { return .execute(.lockScreen) }

        if let spotifyAction = Self.spotifyAction(for: commandPhrase) {
            return .execute(.spotifyControl(spotifyAction))
        }

        if let spotifySearch = searchRegistry.parseSpotifyPlayRequest(from: normalized) {
            return .execute(.spotifySearchAndPlay(query: spotifySearch.query, url: spotifySearch.url))
        }

        // 1. In-site search commands: "open [query] in/on [site]", "search [query] on [site]", "search for [query]"
        if let search = searchRegistry.parseSearch(from: normalized) {
            let intent = CommandIntent.searchWeb(query: search.query, providerName: search.providerName, url: search.url)
            // Search is non-destructive; execute immediately without annoying confirmation modals
            return .execute(intent)
        }

        // 2. URL navigation commands: "open [URL]", "go to [URL]", "browse to [URL]"
        let urlVerbs = ["open ", "go to ", "browse to "]
        for verb in urlVerbs where lower.hasPrefix(verb) {
            let candidate = String(normalized.dropFirst(verb.count))
            if let url = Self.parseURL(from: candidate) {
                return .execute(.openURL(url))
            }
        }

        let verbs: [(String, (ApplicationMatch) -> CommandIntent)] = [
            ("switch to ", { .switchToApplication($0) }),
            ("launch ", { .openApplication($0) }),
            ("open ", { .openApplication($0) }),
            ("quit ", { .quitApplication($0) })
        ]

        for (verb, makeIntent) in verbs where lower.hasPrefix(verb) {
            let phrase = String(lower.dropFirst(verb.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let match = bestApplicationMatch(for: phrase, transcriptionConfidence: transcriptionConfidence) else { return .notCommand }
            let intent = makeIntent(match)
            return match.confidence >= highConfidenceThreshold ? .execute(intent) : .needsConfirmation(intent)
        }

        return .notCommand
    }

    /// Extracts and parses an in-site search command from spoken or typed text like "open firebasechannel in youtube.com".
    public static func parseSearch(from rawText: String, registry: SearchProviderRegistry = .shared) -> ParsedSearchCommand? {
        registry.parseSearch(from: rawText)
    }

    /// Extracts and validates a destination URL from spoken or typed text like "youtube.com", "https://google.com", "youtube dot com", etc.
    public static func parseURL(from rawText: String) -> URL? {
        var text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip trailing sentence punctuation commonly added by dictation engines
        while text.hasSuffix(".") || text.hasSuffix(",") || text.hasSuffix("!") || text.hasSuffix("?") {
            text.removeLast()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !text.isEmpty else { return nil }

        // Normalize spoken URL patterns:
        // Spoken " dot " -> "."
        text = text.replacingOccurrences(of: "(?i)\\s+dot\\s+", with: ".", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)^dot\\s+", with: ".", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)\\s+dot$", with: ".", options: .regularExpression)
        // Spoken " slash " -> "/"
        text = text.replacingOccurrences(of: "(?i)\\s+slash\\s+", with: "/", options: .regularExpression)
        // Spoken spaces around dots: "youtube . com" -> "youtube.com"
        text = text.replacingOccurrences(of: "\\s*\\.\\s*", with: ".", options: .regularExpression)
        // Clean "https : // " or "http : // "
        text = text.replacingOccurrences(of: "(?i)https?\\s*:\\s*/\\s*/\\s*", with: "https://", options: .regularExpression)

        // 1. Explicit scheme present
        if text.lowercased().hasPrefix("http://") || text.lowercased().hasPrefix("https://") {
            if let url = URL(string: text), url.host != nil {
                return url
            }
        }

        // 2. Localhost patterns: "localhost:3000", "localhost"
        if text.lowercased().hasPrefix("localhost") {
            if let url = URL(string: "http://" + text) {
                return url
            }
        }

        // 3. Domains starting with www.
        if text.lowercased().hasPrefix("www.") {
            if let url = URL(string: "https://" + text), url.host != nil {
                return url
            }
        }

        // 4. Standard domain format: [subdomain.]domain.tld[:port][/path]
        // Must contain at least one dot, no spaces in host, and a valid TLD
        let domainRegex = "^[a-zA-Z0-9][-a-zA-Z0-9]*(\\.[a-zA-Z0-9][-a-zA-Z0-9]*)+(:[0-9]+)?(/.*)?$"
        if text.range(of: domainRegex, options: .regularExpression) != nil {
            if let url = URL(string: "https://" + text), url.host != nil {
                return url
            }
        }

        return nil
    }

    /// Executes a previously resolved command intent.
    public func execute(_ intent: CommandIntent) {
        switch intent {
        case .openApplication(let match), .switchToApplication(let match):
            if let url = match.url {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        case .quitApplication(let match):
            NSWorkspace.shared.runningApplications
                .first { $0.bundleIdentifier == match.bundleIdentifier || $0.localizedName == match.name }?
                .terminate()
        case .mute:
            setMuted(true)
        case .unmute:
            setMuted(false)
        case .sleepDisplay:
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            task.arguments = ["displaysleepnow"]
            try? task.run()
        case .lockScreen:
            lockScreen()
        case .spotifyControl(let action):
            _ = SpotifyPlaybackController.perform(action)
        case .spotifySearchAndPlay(let query, let url):
            // DictationCoordinator owns the product-facing asynchronous path. Keep this
            // compatibility path for explicitly confirmed commands without inventing success UI.
            _ = url
            Task { @MainActor in
                _ = await SpotifyPlaybackController.searchAndPlayTopResult(query: query) { _ in }
            }
        case .openURL(let url), .searchWeb(_, _, let url):
            let openAction = {
                NSWorkspace.shared.open(url)
            }
            if Thread.isMainThread {
                _ = openAction()
            } else {
                DispatchQueue.main.sync {
                    _ = openAction()
                }
            }
        }
    }

    /// Runs native Spotify Quick Search and returns only after playback has been verified or a
    /// truthful terminal failure/unverified state is known.
    @MainActor
    public func playSpotify(
        query: String,
        progress: @escaping @MainActor (SpotifyPlaybackProgress) -> Void
    ) async -> SpotifyPlaybackOutcome {
        await SpotifyPlaybackController.searchAndPlayTopResult(query: query, progress: progress)
    }

    private static func spotifyAction(for transcript: String) -> SpotifyPlaybackAction? {
        switch transcript {
        case "resume spotify", "play spotify", "resume spotify music": .resume
        case "pause spotify", "pause spotify music": .pause
        case "next spotify track", "skip spotify track", "skip song on spotify": .next
        case "previous spotify track", "previous song on spotify", "go back on spotify": .previous
        default: nil
        }
    }

    private static func removingTerminalPunctuation(from text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func bestApplicationMatch(for phrase: String, transcriptionConfidence: Float?) -> ApplicationMatch? {
        catalog.installedApplications()
            .map { app -> ApplicationMatch in
                var copy = app
                let appConfidence = Self.confidence(phrase: phrase, candidate: app.name.lowercased())
                if let transcriptionConfidence {
                    copy.confidence = min(appConfidence, Double(transcriptionConfidence))
                } else {
                    copy.confidence = appConfidence
                }
                return copy
            }
            .max { $0.confidence < $1.confidence }
    }

    private static func confidence(phrase: String, candidate: String) -> Double {
        if phrase == candidate { return 1 }
        if candidate.contains(phrase) || phrase.contains(candidate) { return 0.9 }
        let distance = levenshtein(phrase, candidate)
        let length = max(phrase.count, candidate.count)
        guard length > 0 else { return 0 }
        return max(0, 1 - Double(distance) / Double(length))
    }

    private static func levenshtein(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs)
        let b = Array(rhs)
        var previous = Array(0...b.count)
        for (i, ca) in a.enumerated() {
            var current = [i + 1]
            for (j, cb) in b.enumerated() {
                current.append(ca == cb ? previous[j] : min(previous[j], previous[j + 1], current[j]) + 1)
            }
            previous = current
        }
        return previous.last ?? 0
    }

    private func setMuted(_ muted: Bool) {
        let script = "set volume output muted \(muted ? "true" : "false")"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        try? task.run()
    }

    /// Invokes macOS's native Lock Screen shortcut without AppleScript or Automation access.
    private func lockScreen() {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_Q), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_Q), keyDown: false)
        else { return }

        source.localEventsSuppressionInterval = 0
        let flags: CGEventFlags = [.maskCommand, .maskControl]
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
    }
}
