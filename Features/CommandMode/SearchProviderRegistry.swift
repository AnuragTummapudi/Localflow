import AppKit
import Foundation
import Shared

/// A registered search engine or platform destination.
public struct SearchProvider: Sendable, Equatable {
    /// The unique identifier of the provider.
    public let id: String

    /// Human-friendly display name (e.g. "YouTube", "Google").
    public let name: String

    /// Case-insensitive aliases and domain variations (e.g. ["youtube", "youtube.com", "yt", "youtu.be"]).
    public let aliases: [String]

    /// URL template with `{q}` placeholder for the encoded query string.
    public let urlTemplate: String

    /// Optional native macOS URL scheme template (e.g. "spotify:search:{q}").
    /// If an installed desktop app handles this scheme, it opens directly into the app.
    public let appSchemeTemplate: String?

    /// Creates a search provider.
    public init(id: String, name: String, aliases: [String], urlTemplate: String, appSchemeTemplate: String? = nil) {
        self.id = id
        self.name = name
        self.aliases = aliases
        self.urlTemplate = urlTemplate
        self.appSchemeTemplate = appSchemeTemplate
    }

    /// Constructs the destination URL for a given search query.
    public func searchURL(for query: String) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Safely percent-encode query value, ensuring sub-delimiters (+, &, #, =, ?) are encoded
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "!*'();:@&=+$,/?#[]%")
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }

        // 1. If native app scheme is supported and an app is installed to open it on this Mac, prefer native app
        if let appSchemeTemplate {
            let appURLString = appSchemeTemplate.replacingOccurrences(of: "{q}", with: encoded)
            if let appURL = URL(string: appURLString),
               NSWorkspace.shared.urlForApplication(toOpen: appURL) != nil {
                return appURL
            }
        }

        // 2. Fall back to standard web destination
        let urlString = urlTemplate.replacingOccurrences(of: "{q}", with: encoded)
        return URL(string: urlString)
    }
}

/// A parsed search command with extracted query, provider, and destination URL.
public struct ParsedSearchCommand: Sendable, Equatable {
    /// The search terms (e.g. "firebasechannel", "swift concurrency").
    public let query: String

    /// The name of the target search provider (e.g. "YouTube", "Google", "stripe.com").
    public let providerName: String

    /// The ready-to-open destination search URL.
    public let url: URL

    /// Creates a parsed search command.
    public init(query: String, providerName: String, url: URL) {
        self.query = query
        self.providerName = providerName
        self.url = url
    }
}

/// Registry of search providers and NLP query routing.
public final class SearchProviderRegistry: @unchecked Sendable {
    /// The shared singleton instance with default providers.
    public static let shared = SearchProviderRegistry()

    private var providers: [SearchProvider]
    private let lock = NSLock()

    /// Creates a registry initialized with default search providers.
    public init(providers: [SearchProvider] = SearchProviderRegistry.defaultProviders) {
        self.providers = providers
    }

    /// Built-in search providers.
    public static var defaultProviders: [SearchProvider] {
        [
            SearchProvider(
                id: "youtube",
                name: "YouTube",
                aliases: ["youtube", "youtube.com", "yt", "youtu.be", "youtube dot com"],
                urlTemplate: "https://www.youtube.com/results?search_query={q}"
            ),
            SearchProvider(
                id: "google",
                name: "Google",
                aliases: ["google", "google.com", "goog", "google dot com"],
                urlTemplate: "https://www.google.com/search?q={q}"
            ),
            SearchProvider(
                id: "github",
                name: "GitHub",
                aliases: ["github", "github.com", "gh", "github dot com"],
                urlTemplate: "https://github.com/search?q={q}"
            ),
            SearchProvider(
                id: "reddit",
                name: "Reddit",
                aliases: ["reddit", "reddit.com", "reddit dot com"],
                urlTemplate: "https://www.reddit.com/search/?q={q}"
            ),
            SearchProvider(
                id: "x",
                name: "X",
                aliases: ["twitter", "x", "twitter.com", "x.com", "twitter dot com"],
                urlTemplate: "https://x.com/search?q={q}"
            ),
            SearchProvider(
                id: "amazon",
                name: "Amazon",
                aliases: ["amazon", "amazon.com", "amazon dot com"],
                urlTemplate: "https://www.amazon.com/s?k={q}"
            ),
            SearchProvider(
                id: "wikipedia",
                name: "Wikipedia",
                aliases: ["wikipedia", "wikipedia.org", "wiki", "wikipedia dot org"],
                urlTemplate: "https://en.wikipedia.org/w/index.php?search={q}"
            ),
            SearchProvider(
                id: "duckduckgo",
                name: "DuckDuckGo",
                aliases: ["duckduckgo", "duckduckgo.com", "ddg", "duck duck go"],
                urlTemplate: "https://duckduckgo.com/?q={q}"
            ),
            SearchProvider(
                id: "stackoverflow",
                name: "Stack Overflow",
                aliases: ["stackoverflow", "stackoverflow.com", "stack overflow"],
                urlTemplate: "https://stackoverflow.com/search?q={q}"
            ),
            SearchProvider(
                id: "spotify",
                name: "Spotify",
                aliases: ["spotify", "spotify.com"],
                urlTemplate: "https://open.spotify.com/search/{q}",
                appSchemeTemplate: "spotify:search:{q}"
            ),
            SearchProvider(
                id: "applemusic",
                name: "Apple Music",
                aliases: ["apple music", "music", "music.apple.com"],
                urlTemplate: "https://music.apple.com/search?term={q}",
                appSchemeTemplate: "music://music.apple.com/search?term={q}"
            ),
            SearchProvider(
                id: "perplexity",
                name: "Perplexity",
                aliases: ["perplexity", "perplexity.ai"],
                urlTemplate: "https://www.perplexity.ai/search?q={q}"
            ),
            SearchProvider(
                id: "googlemaps",
                name: "Google Maps",
                aliases: ["google maps", "maps", "maps.google.com"],
                urlTemplate: "https://www.google.com/maps/search/{q}"
            )
        ]
    }

    /// Registers or updates a search provider.
    public func register(_ provider: SearchProvider) {
        lock.lock()
        defer { lock.unlock() }
        providers.removeAll { $0.id == provider.id }
        providers.append(provider)
    }

    /// Finds a registered provider matching the given alias or domain name.
    public func findProvider(for target: String) -> SearchProvider? {
        let normalized = Self.normalizeTargetString(target)
        lock.lock()
        defer { lock.unlock() }

        return providers.first { provider in
            provider.aliases.contains { alias in
                let normAlias = Self.normalizeTargetString(alias)
                return normAlias == normalized
            }
        }
    }

    /// Normalizes spoken target strings: removes punctuation, turns "dot" into ".", removes extra spaces.
    public static func normalizeTargetString(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while text.hasSuffix(".") || text.hasSuffix(",") || text.hasSuffix("!") || text.hasSuffix("?") {
            text.removeLast()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        text = text.replacingOccurrences(of: "(?i)\\s+dot\\s+", with: ".", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)^dot\\s+", with: ".", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)\\s+dot$", with: ".", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s*\\.\\s*", with: ".", options: .regularExpression)
        return text
    }

    /// Strips leading command trigger verbs (e.g. "open ", "search for ", "search ", "find ", "look up ").
    public static func stripTriggerVerb(from text: String) -> (verb: String, remainder: String)? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = normalized.lowercased()

        let verbs = [
            "search for ",
            "look up ",
            "find ",
            "search ",
            "open ",
            "browse to ",
            "go to "
        ]

        for verb in verbs where lower.hasPrefix(verb) {
            let remainder = String(normalized.dropFirst(verb.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return (verb.trimmingCharacters(in: .whitespaces), remainder)
        }
        return nil
    }

    /// Parses an utterance like "open firebasechannel in youtube.com" into a search command.
    public func parseSearch(from text: String) -> ParsedSearchCommand? {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasSuffix(".") || cleaned.hasSuffix(",") || cleaned.hasSuffix("!") || cleaned.hasSuffix("?") {
            cleaned.removeLast()
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let (verb, remainder) = Self.stripTriggerVerb(from: cleaned), !remainder.isEmpty else {
            return nil
        }

        // Find preposition candidates (" in ", " on ", " at ")
        let prepositions = [" in ", " on ", " at "]
        let lowerRemainder = remainder.lowercased()

        // Find all occurrences of prepositions with their ranges
        var matchRanges: [(range: Range<String.Index>, preposition: String)] = []
        for prep in prepositions {
            var searchStartIndex = lowerRemainder.startIndex
            while let range = lowerRemainder.range(of: prep, range: searchStartIndex..<lowerRemainder.endIndex) {
                matchRanges.append((range: range, preposition: prep))
                searchStartIndex = range.upperBound
            }
        }

        // Sort by position from right-to-left so nested prepositions in query are preserved
        // (e.g. "open how to center a div in css on google")
        matchRanges.sort { $0.range.lowerBound > $1.range.lowerBound }

        for (range, _) in matchRanges {
            let queryPart = String(remainder[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let targetPart = String(remainder[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)

            guard !queryPart.isEmpty, !targetPart.isEmpty else { continue }

            let normalizedTarget = Self.normalizeTargetString(targetPart)

            // 1. Check known search providers
            if let provider = findProvider(for: normalizedTarget),
               let url = provider.searchURL(for: queryPart) {
                return ParsedSearchCommand(query: queryPart, providerName: provider.name, url: url)
            }

            // 2. Check if target is an explicit web domain (e.g. "stripe.com", "apple.com")
            if isDomainString(normalizedTarget) {
                // Fallback for custom domains: Google site-scoped search guarantees results for any domain
                var allowed = CharacterSet.urlQueryAllowed
                allowed.remove(charactersIn: "!*'();:@&=+$,/?#[]%")
                let queryEscaped = queryPart.addingPercentEncoding(withAllowedCharacters: allowed) ?? queryPart
                let domainEscaped = normalizedTarget.addingPercentEncoding(withAllowedCharacters: allowed) ?? normalizedTarget
                let urlString = "https://www.google.com/search?q=site:\(domainEscaped)+\(queryEscaped)"

                if let url = URL(string: urlString) {
                    return ParsedSearchCommand(query: queryPart, providerName: normalizedTarget, url: url)
                }
            }
        }

        // 3. Fallback: If the user explicitly used "search" or "search for" without a target platform,
        // default to Google search (e.g. "search swift concurrency")
        if verb == "search" || verb == "search for" || verb == "look up" {
            let defaultProvider = findProvider(for: "google") ?? Self.defaultProviders[1]
            if let url = defaultProvider.searchURL(for: remainder) {
                return ParsedSearchCommand(query: remainder, providerName: defaultProvider.name, url: url)
            }
        }

        return nil
    }

    /// Parses a playback-shaped request such as "play Midnight City by M83 on Spotify" or
    /// the concise local command "play Glory" when Spotify is installed.
    public func parseSpotifyPlayRequest(from text: String) -> ParsedSearchCommand? {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = cleaned.last, ".,!?".contains(last) {
            cleaned.removeLast()
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let lower = cleaned.lowercased()
        guard lower.hasPrefix("play ") else { return nil }

        let remainder = String(cleaned.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerRemainder = remainder.lowercased()
        for suffix in [" on spotify", " in spotify"] where lowerRemainder.hasSuffix(suffix) {
            let query = String(remainder.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty,
                  let spotify = findProvider(for: "spotify"),
                  let url = spotify.searchURL(for: query) else { return nil }
            return ParsedSearchCommand(query: query, providerName: spotify.name, url: url)
        }
        if !remainder.isEmpty,
           NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") != nil,
           let spotify = findProvider(for: "spotify"),
           let url = spotify.searchURL(for: remainder) {
            return ParsedSearchCommand(query: remainder, providerName: spotify.name, url: url)
        }
        return nil
    }

    private func isDomainString(_ string: String) -> Bool {
        let domainRegex = "^[a-zA-Z0-9][-a-zA-Z0-9]*(\\.[a-zA-Z0-9][-a-zA-Z0-9]*)+(:[0-9]+)?(/.*)?$"
        return string.range(of: domainRegex, options: .regularExpression) != nil
    }
}
