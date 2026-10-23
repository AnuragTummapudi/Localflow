import AppKit
import Foundation
import Shared

/// A parsed voice command.
public enum CommandIntent: Equatable, Sendable {
    case nativeAction(AgentAction)
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

    /// Whole names declared by the installed bundle, never fuzzy/learned aliases.
    public var alternateNames: [String]

    /// Creates an app match.
    public init(name: String, bundleIdentifier: String?, url: URL?, confidence: Double, alternateNames: [String] = []) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.url = url
        self.confidence = confidence
        self.alternateNames = alternateNames
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
            URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
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
            let declaredName = bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            let alternateNames = declaredName.map { $0 == name ? [] : [$0] } ?? []
            return ApplicationMatch(name: name, bundleIdentifier: bundle?.bundleIdentifier, url: url, confidence: 1, alternateNames: alternateNames)
        }
    }
}

/// Parses and executes voice commands.
public final class CommandMode {
    /// Minimum confidence required for automatic execution.
    public let highConfidenceThreshold: Double

    private let catalog: ApplicationCatalog
    private let searchRegistry: SearchProviderRegistry
    private let memory: AgentMemory

    public var operationalMemory: AgentMemory { memory }

    /// Creates a command mode service.
    public init(
        catalog: ApplicationCatalog = LaunchServicesApplicationCatalog(),
        searchRegistry: SearchProviderRegistry = .shared,
        highConfidenceThreshold: Double = 0.82,
        memory: AgentMemory = AgentMemory()
    ) {
        self.memory = memory
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

        if let saved = lookup(memory.approvedCommands, commandPhrase) {
            var base = memory; base.approvedCommands = [:]
            let resolution = withMemory(base).resolve(saved, transcriptionConfidence: transcriptionConfidence)
            switch resolution {
            case .execute(let intent), .needsConfirmation(let intent):
                guard intent.agentAction.toolID.risk != .consequential else { return .notCommand }
            case .notCommand: return .notCommand
            }
            return resolution
        }
        for verb in ["open ", "launch ", "switch to ", "quit ", "go to ", "browse to ", "reveal in finder "] where commandPhrase.hasPrefix(verb) {
            let name = String(commandPhrase.dropFirst(verb.count))
            if verb != "quit ", let website = lookup(memory.websites, name), let url = URL(string: website),
               (try? ToolArguments.url(url).validate(for: .openURL)) != nil { return .execute(.openURL(url)) }
            if verb != "quit ", let path = lookup(memory.folders, name), path.hasPrefix("/") {
                return .execute(.nativeAction(AgentAction(toolID: .revealFile, arguments: .file(URL(fileURLWithPath: path)))))
            }
            let role = name.hasPrefix("my ") ? String(name.dropFirst(3)) : name
            if let appName = lookup(memory.applicationAliases, name) ?? memory.preferredApps[role] {
                let matches = catalog.installedApplications().filter { $0.name.caseInsensitiveCompare(appName) == .orderedSame || $0.bundleIdentifier == appName }
                guard Set(matches.map(\.id)).count == 1, var app = matches.first else { return .notCommand }
                app.confidence = min(1, Double(transcriptionConfidence ?? 1))
                let intent: CommandIntent = verb == "quit " ? .quitApplication(app) : verb == "switch to " ? .switchToApplication(app) : .openApplication(app)
                return app.confidence >= highConfidenceThreshold ? .execute(intent) : .needsConfirmation(intent)
            }
        }
        if let action = NativeCommandParser.parse(normalized, registry: searchRegistry) {
            return .execute(.nativeAction(canonicalizedPayload(action)))
        }

        if commandPhrase == "mute" { return .execute(.mute) }
        if commandPhrase == "unmute" { return .execute(.unmute) }
        if commandPhrase == "sleep display" { return .execute(.sleepDisplay) }
        if commandPhrase == "lock it" { return .execute(.lockScreen) }

        if let spotifyAction = Self.spotifyAction(for: commandPhrase) {
            return .execute(.spotifyControl(spotifyAction))
        }

        if let spotifySearch = searchRegistry.parseSpotifyPlayRequest(from: normalized) {
            let corrected = canonicalizedSearch(spotifySearch)
            return .execute(.searchWeb(query: corrected.query, providerName: corrected.providerName, url: corrected.url))
        }

        // 1. In-site search commands: "open [query] in/on [site]", "search [query] on [site]", "search for [query]"
        if let search = searchRegistry.parseSearch(from: normalized) {
            let corrected = canonicalizedSearch(search)
            let intent = CommandIntent.searchWeb(query: corrected.query, providerName: corrected.providerName, url: corrected.url)
            // Search is non-destructive; execute immediately without annoying confirmation modals
            return .execute(intent)
        }

        // 2. URL navigation commands: "open [URL]", "go to [URL]", "browse to [URL]"
        let urlVerbs = ["open ", "go to ", "browse to "]
        for verb in urlVerbs where lower.hasPrefix(verb) {
            let candidate = String(normalized.dropFirst(verb.count))
            let literal = Self.removingTerminalPunctuation(from: candidate.trimmingCharacters(in: .whitespacesAndNewlines))
            let mapped = lookup(memory.payloadVocabulary ?? [:], literal) ?? candidate
            if let url = Self.parseURL(from: mapped) {
                return .execute(.openURL(url))
            }
        }

        for verb in urlVerbs where lower.hasPrefix(verb) {
            let name = Self.removingTerminalPunctuation(from: String(normalized.dropFirst(verb.count)))
            if searchRegistry.findProvider(for: name) != nil {
                return .execute(.nativeAction(AgentAction(toolID: .openWebsite, arguments: .website(name))))
            }
        }

        let verbs: [(String, (ApplicationMatch) -> CommandIntent)] = [
            ("switch to ", { .switchToApplication($0) }),
            ("launch ", { .openApplication($0) }),
            ("open ", { .openApplication($0) }),
            ("quit ", { .quitApplication($0) })
        ]

        for (verb, makeIntent) in verbs where lower.hasPrefix(verb) {
            let phrase = Self.removingTerminalPunctuation(from: String(lower.dropFirst(verb.count))).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let match = bestApplicationMatch(for: phrase, transcriptionConfidence: transcriptionConfidence) else { return .notCommand }
            let intent = makeIntent(match)
            let exact = catalog.installedApplications().filter { app in
                ([app.name] + app.alternateNames).contains { $0.caseInsensitiveCompare(phrase) == .orderedSame }
            }
            // A similarity score is a suggestion, never authoritative identity.
            // Exact alternate bundle names are allowed; partial/fuzzy/duplicate
            // names require the existing frozen-target confirmation flow.
            return Set(exact.map(\.id)).count == 1 && match.confidence >= highConfidenceThreshold
                ? .execute(intent) : .needsConfirmation(intent)
        }

        return .notCommand
    }

    /// Apply configured terms only after slots have been extracted. Headers, tool
    /// identity, captured targets and native safety metadata are never rewritten.
    public func canonicalizedPayload(_ action: AgentAction) -> AgentAction {
        let mappings = memory.payloadVocabulary ?? [:]
        guard !mappings.isEmpty else { return action }
        func corrected(_ value: String) -> String { PayloadCanonicalizer.apply(value, mappings: mappings) }
        let args: ToolArguments
        switch action.arguments {
        case .note(let title, let body): args = .note(title: corrected(title), body: corrected(body))
        case .reminder(let title, let notes, let due): args = .reminder(title: corrected(title), notes: notes.map(corrected), due: due)
        case .currentNote(let body, let snapshot): args = .currentNote(corrected(body), snapshot: snapshot)
        case .text(let text, let pid): args = .text(corrected(text), targetProcessID: pid)
        case .selection(let text, let snapshot): args = .selection(corrected(text), snapshot: snapshot)
        case .search(let query, let provider): args = .search(query: corrected(query), provider: provider)
        default: return action
        }
        // An invalid explicit mapping fails closed; never execute the original
        // payload after promising a configured correction.
        return action.prepared(arguments: args)
    }
    private func canonicalizedSearch(_ search: ParsedSearchCommand) -> ParsedSearchCommand {
        let query = PayloadCanonicalizer.apply(search.query, mappings: memory.payloadVocabulary ?? [:])
        guard query != search.query else { return search }
        if let provider = searchRegistry.findProvider(for: search.providerName), let url = provider.searchURL(for: query) {
            return ParsedSearchCommand(query: query, providerName: search.providerName, url: url)
        }
        // The parser's registered Google site-search fallback keeps the exact
        // spoken domain. Only an explicitly mapped query is changed.
        if search.url.scheme == "https", search.url.host == "www.google.com", search.url.path == "/search",
           let existing = URLComponents(url: search.url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value,
           existing == "site:\(search.providerName)+\(search.query)",
           let google = searchRegistry.findProvider(for: "google"),
           let url = google.searchURL(for: "site:\(search.providerName) \(query)") {
            return ParsedSearchCommand(query: query, providerName: search.providerName, url: url)
        }
        return search
    }

    /// Snapshot installed apps once per explicit agent session, not on every ASR update.
    public func forAgentSession(memory: AgentMemory? = nil) -> CommandMode {
        struct SnapshotCatalog: ApplicationCatalog {
            let apps: [ApplicationMatch]
            func installedApplications() -> [ApplicationMatch] { apps }
        }
        return CommandMode(catalog: SnapshotCatalog(apps: catalog.installedApplications()),
                           searchRegistry: searchRegistry, highConfidenceThreshold: highConfidenceThreshold, memory: memory ?? self.memory)
    }

    public func withMemory(_ memory: AgentMemory) -> CommandMode {
        CommandMode(catalog: catalog, searchRegistry: searchRegistry, highConfidenceThreshold: highConfidenceThreshold, memory: memory)
    }
    private func lookup<T>(_ values: [String: T], _ key: String) -> T? {
        values.first { AgentMemory.key($0.key) == AgentMemory.key(key) }?.value
    }
    /// Expand only whole explicit workflow invocations. Payloads remain indivisible.
    public func segments(_ text: String, continuous: Bool = false) throws -> [SpeechCommandSegment] {
        try expand(text, visited: [], depth: 0, continuous: continuous)
    }
    private func expand(_ text: String, visited: Set<String>, depth: Int, continuous: Bool) throws -> [SpeechCommandSegment] {
        guard depth < 8 else { throw AgentMemoryError.invalid("Workflow nesting exceeds 8 levels.") }
        let key = Self.removingTerminalPunctuation(from: AgentMemory.key(text))
        let name = lookup(memory.workflows, key) != nil ? key : key.hasPrefix("run ") ? String(key.dropFirst(4)) : key
        if let steps = lookup(memory.workflows, name) {
            guard !visited.contains(name), (1...20).contains(steps.count) else { throw AgentMemoryError.invalid("Workflow contains a cycle or has no steps.") }
            var next = visited; next.insert(name)
            let parts = try steps.flatMap { try expand($0, visited: next, depth: depth + 1, continuous: false) }
            guard parts.count <= 40 else { throw AgentMemoryError.invalid("Workflow exceeds 40 actions.") }
            // Saved plans always wait for final ASR, including their app-open steps.
            return parts.map { SpeechCommandSegment(text: $0.text, endWord: Int.max, closed: false) }
        }
        let parts = SpeechCommandSegmenter.segments(text, continuous: continuous)
        return try parts.flatMap { part -> [SpeechCommandSegment] in
            let partKey = Self.removingTerminalPunctuation(from: AgentMemory.key(part.text))
            if lookup(memory.workflows, partKey) != nil || (partKey.hasPrefix("run ") && lookup(memory.workflows, String(partKey.dropFirst(4))) != nil) {
                return try expand(part.text, visited: visited, depth: depth + 1, continuous: continuous)
            }
            return [part]
        }
    }
    public func validateOperationalMemory(_ value: AgentMemory) throws {
        try value.validate()
        let configured = withMemory(value)
        for name in value.workflows.keys {
            for segment in try configured.segments(name) {
                let parsed = SpeechCommandSegmenter.noteAction(segment.text).map { CommandResolution.execute(.nativeAction($0)) } ?? configured.resolve(segment.text)
                switch parsed {
                case .execute: continue
                case .notCommand, .needsConfirmation:
                    throw AgentMemoryError.invalid("Unsupported or ambiguous workflow command: \(segment.text)")
                }
            }
        }
        for command in value.approvedCommands.values {
            var base = value; base.approvedCommands = [:]
            let parsed = withMemory(base).resolve(command)
            switch parsed {
            case .execute(let intent), .needsConfirmation(let intent):
                guard intent.agentAction.toolID.risk != .consequential else { throw AgentMemoryError.invalid("Consequential commands cannot become approved mappings.") }
            case .notCommand: throw AgentMemoryError.invalid("Approved mappings need a supported single command.")
            }
        }
    }

    /// A user-configured alias is exact authority at final ASR, but does not add
    /// literal app-name evidence to the speculative partial gate.
    public func isConfiguredApplicationOpen(_ text: String, action: AgentAction) -> Bool {
        guard action.toolID == .openApplication, case .application(let app, _) = action.arguments else { return false }
        let key = Self.removingTerminalPunctuation(from: AgentMemory.key(text))
        if let saved = lookup(memory.approvedCommands, key) {
            var base = memory; base.approvedCommands = [:]
            switch withMemory(base).resolve(saved) {
            case .execute(let intent):
                if case .application(let target, _) = intent.agentAction.arguments { return target.id == app.id && target.confidence == 1 }
            default: break
            }
        }
        guard let verb = ["open ", "launch "].first(where: { key.hasPrefix($0) }) else { return false }
        let name = String(key.dropFirst(verb.count))
        let role = name.hasPrefix("my ") ? String(name.dropFirst(3)) : name
        guard let configured = lookup(memory.applicationAliases, name) ?? memory.preferredApps[role] else { return false }
        let matches = catalog.installedApplications().filter { $0.name.caseInsensitiveCompare(configured) == .orderedSame || $0.bundleIdentifier == configured }
        return Set(matches.map(\.id)).count == 1 && matches.first?.id == app.id && app.confidence == 1
    }

    /// Speculation requires a whole installed app name and a unique identity, never fuzzy matching.
    public func isExactApplicationOpen(_ text: String, action: AgentAction) -> Bool {
        guard action.toolID == .openApplication, case .application(let app, _) = action.arguments else { return false }
        let lower = Self.removingTerminalPunctuation(from: text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
        guard let verb = ["open ", "launch "].first(where: { lower.hasPrefix($0) }) else { return false }
        let name = String(lower.dropFirst(verb.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = catalog.installedApplications().filter { ([ $0.name ] + $0.alternateNames).contains { $0.lowercased() == name } }
        return Set(matches.map(\.id)).count == 1 && matches.first?.id == app.id && app.confidence == 1
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
        text = text.replacingOccurrences(of: "(?i)^(https?)\\s*:\\s*/\\s*/\\s*", with: "$1://", options: .regularExpression)

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

    /// All parsed commands use the same typed native tool executor and risk policy.
    @MainActor
    public func execute(_ intent: CommandIntent, using executor: ActionExecutor, requireConfirmation: Bool = false) async -> ToolResult {
        await executor.execute(intent.agentAction, requireConfirmation: requireConfirmation)
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
                let appConfidence = ([app.name] + app.alternateNames).map { Self.confidence(phrase: phrase, candidate: $0.lowercased()) }.max() ?? 0
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

}
