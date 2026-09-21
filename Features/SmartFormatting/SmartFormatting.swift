import AppKit
import Foundation
import Shared

/// Configuration options for SmartFormatting.
public struct SmartFormattingOptions: Sendable {
    public var isEnabled: Bool
    public var autocorrectEnabled: Bool
    public var smartPunctuationEnabled: Bool

    public init(
        isEnabled: Bool = true,
        autocorrectEnabled: Bool = true,
        smartPunctuationEnabled: Bool = true
    ) {
        self.isEnabled = isEnabled
        self.autocorrectEnabled = autocorrectEnabled
        self.smartPunctuationEnabled = smartPunctuationEnabled
    }

    public init(settings: LocalFlowSettings) {
        self.isEnabled = settings.smartFormattingEnabled
        self.autocorrectEnabled = settings.smartFormattingAutocorrect
        self.smartPunctuationEnabled = settings.smartFormattingSmartPunctuation
    }
}

/// Applies intelligent local formatting, spelling autocorrection, typography hygiene,
/// and Wispr Flow-style Smart Polish before or during text injection.
public final class SmartFormatting {
    private let settings: LocalFlowSettings
    private let spellChecker = NSSpellChecker.shared

    // Precompiled regular expressions for high performance
    private static let multipleWhitespaceRegex = try! NSRegularExpression(pattern: "[ \\t]+", options: [])
    private static let spaceBeforePunctuationRegex = try! NSRegularExpression(pattern: "\\s+([,.:;?!])", options: [])
    private static let spaceAfterPunctuationRegex = try! NSRegularExpression(pattern: "([,.:;?!])([A-Za-z0-9])", options: [])
    private static let emDashRegex = try! NSRegularExpression(pattern: "\\s*--\\s*|\\s+-\\s+", options: [])
    private static let ellipsisRegex = try! NSRegularExpression(pattern: "\\.{3,}", options: [])
    private static let standalonePronounIRegex = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9_])i(?![A-Za-z0-9_])", options: [])

    // Common spoken contractions that dictation engines sometimes miss apostrophes for
    private static let commonContractions: [String: String] = [
        "didnt": "didn't",
        "dont": "don't",
        "cant": "can't",
        "wont": "won't",
        "isnt": "isn't",
        "arent": "aren't",
        "wasnt": "wasn't",
        "werent": "weren't",
        "hasnt": "hasn't",
        "havent": "haven't",
        "hadnt": "hadn't",
        "couldnt": "couldn't",
        "shouldnt": "shouldn't",
        "wouldnt": "wouldn't",
        "thats": "that's",
        "whats": "what's",
        "wheres": "where's",
        "whos": "who's",
        "hows": "how's",
        "lets": "let's",
        "im": "I'm",
        "ive": "I've",
        "ill": "I'll",
        "id": "I'd",
        "youre": "you're",
        "youve": "you've",
        "youll": "you'll",
        "youd": "you'd",
        "theyre": "they're",
        "theyve": "they've",
        "theyll": "they'll",
        "theyd": "they'd",
        "weve": "we've",
        "weill": "we'll"
    ]

    /// Stable corrections for common dictation and keyboard transpositions.
    /// NSSpellChecker can vary with the installed language dictionary, so these high-
    /// confidence corrections make the instant fallback dependable even offline.
    private static let commonTypos: [String: String] = [
        "recieved": "received",
        "recieve": "receive",
        "teh": "the",
        "adn": "and",
        "seperate": "separate",
        "definately": "definitely",
        "occured": "occurred",
        "untill": "until",
        "wierd": "weird",
        "alot": "a lot",
        "thier": "their",
        "becuase": "because",
        "succesful": "successful",
        "accomodate": "accommodate",
        "goverment": "government"
    ]

    // Common question starter phrases
    private static let questionStarters: [String] = [
        "can you", "could you", "would you", "will you",
        "should we", "shall we",
        "why is", "why are", "why did", "why do", "why does",
        "how is", "how are", "how do", "how does", "how can", "how could",
        "what is", "what are", "what was", "what were", "what do", "what does",
        "where is", "where are", "where was", "where were",
        "when is", "when are", "when was", "when will",
        "who is", "who are", "who was",
        "is it", "is this", "is that", "are you", "are they", "are we",
        "do you", "did you", "have you", "has anyone"
    ]

    /// Creates a SmartFormatting service.
    public init(settings: LocalFlowSettings = .shared) {
        self.settings = settings
    }

    /// Formats text using the frontmost application's bundle identifier.
    public func format(
        _ text: String,
        frontmostBundleIdentifier: String? = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
        options: SmartFormattingOptions? = nil,
        vocabularyStore: VocabularyStore? = nil
    ) -> String {
        let profile = profile(for: frontmostBundleIdentifier)
        return format(text, profile: profile, options: options, vocabularyStore: vocabularyStore)
    }

    /// Returns the formatting profile for a bundle identifier.
    public func profile(
        for bundleIdentifier: String?,
        applicationName: String? = nil,
        activeDomain: String? = nil
    ) -> SmartFormattingProfile {
        let identifier = bundleIdentifier?.lowercased() ?? ""
        let name = applicationName?.lowercased() ?? ""
        let domain = activeDomain?.lowercased() ?? ""
        if identifier.contains("slack") || name == "slack" || domain == "app.slack.com" { return .slack }
        if identifier.contains("gmail") || name.contains("gmail") || domain == "mail.google.com" { return .gmail }
        return .neutral
    }

    /// Formats text for a specific profile and optional settings.
    public func format(
        _ text: String,
        profile: SmartFormattingProfile,
        options: SmartFormattingOptions? = nil,
        vocabularyStore: VocabularyStore? = nil
    ) -> String {
        let opts = options ?? SmartFormattingOptions(settings: settings)
        guard opts.isEnabled else {
            return cleanupWhitespace(text)
        }

        var processed = cleanupWhitespace(text)
        guard !processed.isEmpty else { return "" }
        let protection = protectTechnicalLiterals(in: processed)
        processed = protection.text

        // 1. Spelling & contraction autocorrection
        if opts.autocorrectEnabled {
            processed = applySpellingAndContractions(processed, vocabularyStore: vocabularyStore)
        }

        // 2. Smart punctuation & typography
        if opts.smartPunctuationEnabled {
            processed = applySmartPunctuation(processed)
        }

        // 3. Question mark detection
        processed = applyQuestionMarkDetection(processed)

        // 4. Capitalization hygiene (sentence boundaries & "I")
        processed = applyCapitalization(processed)

        // 5. Profile-specific layout and semantics
        return restoreTechnicalLiterals(in: applyProfile(processed, profile: profile), literals: protection.literals)
    }

    /// Wispr Flow-style Smart Polish entrypoint: runs full speech hygiene, typo/spelling correction,
    /// smart punctuation, and profile formatting. Ideal for the Option+1 shortcut.
    public func polish(
        _ text: String,
        frontmostBundleIdentifier: String? = nil,
        profile: SmartFormattingProfile? = nil,
        options: SmartFormattingOptions? = nil,
        vocabularyStore: VocabularyStore? = nil
    ) -> String {
        let targetProfile = profile ?? (frontmostBundleIdentifier != nil ? self.profile(for: frontmostBundleIdentifier) : .neutral)
        let _ = options ?? SmartFormattingOptions(settings: settings)

        var processed = cleanupWhitespace(text)
        guard !processed.isEmpty else { return "" }
        let protection = protectTechnicalLiterals(in: processed)
        processed = protection.text

        // Step A: Contractions & autocorrection pass
        processed = applySpellingAndContractions(processed, vocabularyStore: vocabularyStore)

        // Step B: Smart typography & quotes
        processed = applySmartPunctuation(processed)

        // Step C: Question mark detection
        processed = applyQuestionMarkDetection(processed)

        // Step D: Sentence casing & 'I' pronoun
        processed = applyCapitalization(processed)

        // Step E: destination application
        return restoreTechnicalLiterals(in: applyProfile(processed, profile: targetProfile), literals: protection.literals)
    }

    // MARK: - Internal Passes

    private func cleanupWhitespace(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(location: 0, length: (trimmed as NSString).length)
        return Self.multipleWhitespaceRegex.stringByReplacingMatches(
            in: trimmed,
            options: [],
            range: range,
            withTemplate: " "
        )
    }

    private func protectTechnicalLiterals(in text: String) -> (text: String, literals: [String]) {
        let pattern = #"https?://[^\s]+|(?:\./|/)?[\w-]+(?:/[\w.-]+)+|--[\w-]+|\b\w+[_.]\w+(?:[./]\w+)*\b|\b[a-z]+[A-Z]\w*\b"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let source = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
        var output = text
        var literals: [String] = []
        for match in matches.reversed() {
            let literal = source.substring(with: match.range)
            let index = literals.count
            literals.append(literal)
            if let range = Range(match.range, in: output) {
                output.replaceSubrange(range, with: "\u{E000}\(index)\u{E001}")
            }
        }
        return (output, literals)
    }

    private func restoreTechnicalLiterals(in text: String, literals: [String]) -> String {
        var output = text
        for (index, literal) in literals.enumerated() {
            output = output.replacingOccurrences(of: "\u{E000}\(index)\u{E001}", with: literal)
        }
        return output
    }

    private func applySpellingAndContractions(_ text: String, vocabularyStore: VocabularyStore?) -> String {
        let tokens = text.components(separatedBy: " ")
        var correctedTokens: [String] = []

        let customWords: Set<String> = {
            guard let vocabularyStore else { return Set() }
            var set = Set<String>()
            for entry in vocabularyStore.entries {
                set.insert(entry.phrase.lowercased())
                if !entry.replacement.isEmpty {
                    set.insert(entry.replacement.lowercased())
                }
            }
            return set
        }()

        for rawToken in tokens {
            // Split trailing/leading punctuation to inspect the core word
            let (leadingPunct, coreWord, trailingPunct) = splitPunctuation(rawToken)
            guard !coreWord.isEmpty else {
                correctedTokens.append(rawToken)
                continue
            }

            let lowerCore = coreWord.lowercased()

            // If user explicitly added this word to custom dictionary or it's an all-caps acronym, preserve it
            if customWords.contains(lowerCore) || isAcronym(coreWord) || isTechnicalLiteral(coreWord) {
                correctedTokens.append(rawToken)
                continue
            }

            // Check known spoken contraction without apostrophe
            if let contraction = Self.commonContractions[lowerCore] {
                let fixed = matchCasing(source: coreWord, target: contraction)
                correctedTokens.append(leadingPunct + fixed + trailingPunct)
                continue
            }

            if let typoFix = Self.commonTypos[lowerCore] {
                let fixed = matchCasing(source: coreWord, target: typoFix)
                correctedTokens.append(leadingPunct + fixed + trailingPunct)
                continue
            }

            // Check standalone 'i'
            if lowerCore == "i" {
                correctedTokens.append(leadingPunct + "I" + trailingPunct)
                continue
            }

            // Check typo / spelling via NSSpellChecker
            let wordRange = NSRange(location: 0, length: (coreWord as NSString).length)
            if let correction = spellChecker.correction(forWordRange: wordRange, in: coreWord, language: "en", inSpellDocumentWithTag: 0),
               !correction.isEmpty {
                let fixed = matchCasing(source: coreWord, target: correction)
                correctedTokens.append(leadingPunct + fixed + trailingPunct)
                continue
            }

            correctedTokens.append(rawToken)
        }

        return correctedTokens.joined(separator: " ")
    }

    private func isTechnicalLiteral(_ word: String) -> Bool {
        word.contains("/") || word.contains("\\") || word.contains("_") || word.contains("-")
            || word.contains(".") || word.contains("@") || word.contains(":")
            || word.hasPrefix("$") || word.hasPrefix("--")
            || word.dropFirst().contains(where: { $0.isUppercase })
    }

    private func applySmartPunctuation(_ text: String) -> String {
        var output = text

        // Remove space before punctuation: "hello , world" -> "hello, world"
        output = Self.spaceBeforePunctuationRegex.stringByReplacingMatches(
            in: output,
            options: [],
            range: NSRange(location: 0, length: (output as NSString).length),
            withTemplate: "$1"
        )

        // Ensure single space after punctuation when directly followed by letter (except within decimals/urls)
        let punctRegex = try! NSRegularExpression(pattern: "([,:;.?!])([A-Za-z])", options: [])
        output = punctRegex.stringByReplacingMatches(
            in: output,
            options: [],
            range: NSRange(location: 0, length: (output as NSString).length),
            withTemplate: "$1 $2"
        )

        // Em dash conversion: " -- " or " - " between words -> " — "
        output = Self.emDashRegex.stringByReplacingMatches(
            in: output,
            options: [],
            range: NSRange(location: 0, length: (output as NSString).length),
            withTemplate: " — "
        )

        // Ellipsis normalization
        output = Self.ellipsisRegex.stringByReplacingMatches(
            in: output,
            options: [],
            range: NSRange(location: 0, length: (output as NSString).length),
            withTemplate: "…"
        )

        // Smart curly double quotes: pair matching
        output = convertToCurlyDoubleQuotes(output)

        return output
    }

    private func convertToCurlyDoubleQuotes(_ text: String) -> String {
        var result = ""
        var openQuote = true
        for char in text {
            if char == "\"" {
                if openQuote {
                    result.append("“")
                } else {
                    result.append("”")
                }
                openQuote.toggle()
            } else {
                result.append(char)
            }
        }
        return result
    }

    private func applyCapitalization(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        // Capitalize standalone 'i' -> 'I'
        let output = Self.standalonePronounIRegex.stringByReplacingMatches(
            in: text,
            options: [],
            range: NSRange(location: 0, length: (text as NSString).length),
            withTemplate: "I"
        )

        // Capitalize sentence beginnings after . ! ? and newlines
        let chars = Array(output)
        var result: [Character] = []
        result.reserveCapacity(chars.count)

        var shouldCapitalize = true
        var i = 0

        while i < chars.count {
            let c = chars[i]
            if shouldCapitalize && c.isLetter {
                result.append(Character(c.uppercased()))
                shouldCapitalize = false
            } else {
                result.append(c)
                if c == "." || c == "!" || c == "?" || c == "\n" {
                    shouldCapitalize = true
                } else if !c.isWhitespace && c != "\"" && c != "“" && c != "”" && c != "'" && c != "‘" && c != "’" {
                    shouldCapitalize = false
                }
            }
            i += 1
        }

        return String(result)
    }

    private func applyQuestionMarkDetection(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        // If already ends in punctuation, do not change
        if let last = trimmed.last, [".", "!", "?", "…"].contains(String(last)) {
            return text
        }

        // Find the start of the final clause/sentence (after last ., !, or newline)
        let lastSentence: String
        if let lastBoundary = trimmed.lastIndex(where: { $0 == "." || $0 == "!" || $0 == "\n" }) {
            let afterBoundary = trimmed[trimmed.index(after: lastBoundary)...]
            lastSentence = afterBoundary.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            lastSentence = trimmed
        }

        let lower = lastSentence.lowercased()
        for starter in Self.questionStarters {
            if lower.hasPrefix(starter + " ") || lower == starter {
                return trimmed + "?"
            }
        }

        return text
    }

    private func applyProfile(_ text: String, profile: SmartFormattingProfile) -> String {
        switch profile {
        case .neutral, .gmail:
            return sentenceCase(text)
        case .slack:
            // Relax trailing period on single-sentence chat messages (casual messaging convention)
            var formatted = text
            if !formatted.contains("\n") && formatted.hasSuffix(".") && !formatted.hasSuffix("...") && !formatted.hasSuffix("…") {
                formatted.removeLast()
            }
            return formatted
        }
    }

    private func sentenceCase(_ text: String) -> String {
        guard let first = text.first else { return text }
        var output = String(first).uppercased() + text.dropFirst()
        if ![".", "!", "?", "…", "”", "\""].contains(output.last.map(String.init) ?? "") {
            output += "."
        }
        return output
    }

    private func containsEnumeration(_ text: String) -> Bool {
        let lower = text.lowercased()
        let triggers = [" first ", " second ", " third ", " next ", " then ", " finally "]
        var count = 0
        for trigger in triggers {
            if lower.contains(trigger) {
                count += 1
            }
        }
        return count >= 2
    }

    private func notesFormat(_ text: String) -> String {
        let separators = [" first ", " second ", " third ", " next ", " then ", " also ", " finally "]
        var formatted = text
        for separator in separators {
            formatted = formatted.replacingOccurrences(of: separator, with: "\n- ", options: [.caseInsensitive])
        }
        if formatted.contains("\n- ") && !formatted.hasPrefix("- ") {
            formatted = "- " + formatted
        }
        return formatted
    }

    // MARK: - Helper Utilities

    private func splitPunctuation(_ token: String) -> (leading: String, core: String, trailing: String) {
        var leading = ""
        var core = ""
        var trailing = ""

        let chars = Array(token)
        var startIdx = 0
        while startIdx < chars.count && isBoundaryPunctuation(chars[startIdx]) {
            leading.append(chars[startIdx])
            startIdx += 1
        }

        var endIdx = chars.count - 1
        while endIdx >= startIdx && isBoundaryPunctuation(chars[endIdx]) {
            trailing = String(chars[endIdx]) + trailing
            endIdx -= 1
        }

        if startIdx <= endIdx {
            core = String(chars[startIdx...endIdx])
        }

        return (leading, core, trailing)
    }

    private func isBoundaryPunctuation(_ c: Character) -> Bool {
        c == "(" || c == ")" || c == "[" || c == "]" || c == "{" || c == "}" ||
        c == "<" || c == ">" || c == "," || c == "." || c == "!" || c == "?" ||
        c == ":" || c == ";" || c == "\"" || c == "“" || c == "”"
    }

    private func isAcronym(_ word: String) -> Bool {
        word.count >= 2 && word.allSatisfy { $0.isUppercase && $0.isLetter }
    }

    private func matchCasing(source: String, target: String) -> String {
        guard let firstSource = source.first, let firstTarget = target.first else { return target }
        if firstSource.isUppercase {
            return String(firstTarget).uppercased() + target.dropFirst()
        }
        return target
    }
}
