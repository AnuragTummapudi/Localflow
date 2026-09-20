import Foundation
import Shared

/// Deterministic, local, rule-based speech hygiene pass.
/// Runs on transcribed text before SmartFormatting's app-specific styling and before TextInjection.
public final class SpeechCleanup: Sendable {
    public let rules: SpeechCleanupRules

    /// Creates a SpeechCleanup instance with the specified or bundled rules.
    public init(rules: SpeechCleanupRules = .load()) {
        self.rules = rules
    }

    /// Cleans the transcribed speech text using the configured rules and options.
    ///
    /// Pipeline order:
    /// 1. Self-Correction Triggers (Rule 4)
    /// 2. Filler Word Removal (Rule 1)
    /// 3. Repeated Word Collapse (Rule 2)
    /// 4. Sentence Boundary Capitalization (Rule 3)
    public func clean(
        _ text: String,
        options: SpeechCleanupOptions = .init(),
        vocabularyStore: VocabularyStore? = nil
    ) -> String {
        guard options.isEnabled else { return text }
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return result }

        // Rule 4: Explicit Self-Correction Triggers
        if options.handleSelfCorrections {
            result = applySelfCorrections(result)
        }

        // Rule 1: Filler Word Removal
        if options.removeFillerWords {
            result = applyFillerRemoval(result)
        }

        // Rule 2: Repeated Word Collapse
        if options.collapseRepeatedWords {
            result = applyRepeatedWordCollapse(result)
        }

        // Rule 3: Capitalization at Sentence Boundaries
        result = applySentenceCapitalization(result, vocabularyStore: vocabularyStore)

        // Final normalization of whitespace and punctuation spacing
        result = normalizePunctuationAndSpacing(result)

        return result
    }

    // MARK: - Rule 4: Self-Correction Triggers

    /// Detects phrases like "no actually", "no wait", "scratch that", "actually", "I mean".
    /// Discards the clause immediately preceding it back to the nearest natural boundary,
    /// removes the trigger, and keeps what follows.
    private func applySelfCorrections(_ input: String) -> String {
        var text = input

        // Sort triggers by descending length so "no actually" matches before "actually"
        let triggers = rules.selfCorrectionTriggers.sorted { $0.count > $1.count }

        for trigger in triggers {
            // Match trigger with flexible boundary and optional leading comma
            // e.g. "5pm, no actually 6pm", "5pm no actually 6pm", "Send email. Scratch that, send to Mary"
            let escaped = NSRegularExpression.escapedPattern(for: trigger)
            let pattern = "(?i)(?:,\\s*|\\s+|^)\(escaped)(?:,\\s*|\\s+|$)"

            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }

            var searchRange = NSRange(location: 0, length: (text as NSString).length)
            while let match = regex.firstMatch(in: text, options: [], range: searchRange) {
                let matchRange = match.range
                var nsText = text as NSString

                // Disambiguation for "I mean":
                // If "I mean" is used as a parenthetical verbal tic (flanked by commas with continuation content),
                // do not treat as self-correction here; Rule 1 will handle it as filler.
                if trigger.lowercased() == "i mean" && isParentheticalFiller(in: text, matchRange: matchRange) {
                    let nextLocation = matchRange.location + matchRange.length
                    if nextLocation < nsText.length {
                        searchRange = NSRange(location: nextLocation, length: nsText.length - nextLocation)
                        continue
                    } else {
                        break
                    }
                }

                // Find the nearest natural boundary preceding the trigger
                let preTriggerText = nsText.substring(to: matchRange.location)
                let replacementStart = findNearestBoundaryIndex(in: preTriggerText)

                let prefix = (preTriggerText as NSString).substring(to: replacementStart)
                let postTriggerIndex = matchRange.location + matchRange.length
                let suffix = postTriggerIndex < nsText.length ? nsText.substring(from: postTriggerIndex) : ""

                // Assemble cleaned result
                var cleaned = prefix
                if !cleaned.isEmpty && !cleaned.hasSuffix(" ") && !suffix.isEmpty && !suffix.hasPrefix(" ") {
                    cleaned += " "
                }
                cleaned += suffix

                text = cleaned
                nsText = text as NSString
                searchRange = NSRange(location: 0, length: nsText.length)
            }
        }

        return text
    }

    /// Finds the cutoff point in `preText` to discard the preceding thought.
    /// Returns the character index in `preText` up to which text should be kept.
    private func findNearestBoundaryIndex(in preText: String) -> Int {
        let ns = preText as NSString
        guard ns.length > 0 else { return 0 }

        // Look backwards for sentence-ending punctuation (. ! ?)
        let sentenceTerminators = CharacterSet(charactersIn: ".!?")
        var lastTerminatorIdx = -1

        for i in (0..<ns.length).reversed() {
            let char = ns.character(at: i)
            if let scalar = UnicodeScalar(char), sentenceTerminators.contains(scalar) {
                lastTerminatorIdx = i
                break
            }
        }

        if lastTerminatorIdx != -1 {
            // Keep up to and including the sentence terminator and any trailing space
            var keepEnd = lastTerminatorIdx + 1
            while keepEnd < ns.length && ns.character(at: keepEnd) == 32 { // space
                keepEnd += 1
            }
            // If the preceding sentence terminator is right before the trigger with only whitespace/comma,
            // the user just completed a full sentence and said "Scratch that, ...".
            // In that case, discard that previous sentence!
            let between = ns.substring(from: keepEnd).trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",")))
            if between.isEmpty {
                // Discard the previous sentence as well
                return findNearestBoundaryIndex(in: ns.substring(to: lastTerminatorIdx))
            }
            return keepEnd
        }

        // No sentence boundary precedes this trigger — discard back to start of transcript
        return 0
    }

    /// Disambiguates "I mean": returns true if "I mean" is parenthetical filler rather than self-correction.
    private func isParentheticalFiller(in text: String, matchRange: NSRange) -> Bool {
        let ns = text as NSString
        let before = matchRange.location > 0 ? ns.substring(to: matchRange.location) : ""
        let after = (matchRange.location + matchRange.length) < ns.length ? ns.substring(from: matchRange.location + matchRange.length) : ""

        // If surrounded by commas: ", I mean,"
        let hasLeadingComma = before.trimmingCharacters(in: .whitespaces).hasSuffix(",")
        let hasTrailingComma = after.trimmingCharacters(in: .whitespaces).hasPrefix(",")

        if hasLeadingComma && hasTrailingComma {
            return true
        }

        // If at sentence start followed by a comma: "I mean, it's fine"
        if (before.trimmingCharacters(in: .whitespaces).isEmpty || before.hasSuffix(". ") || before.hasSuffix("! ") || before.hasSuffix("? ")) && hasTrailingComma {
            return true
        }

        return false
    }

    // MARK: - Rule 1: Filler Word Removal

    /// Strips standalone filler words and pause-bounded contextual fillers.
    private func applyFillerRemoval(_ input: String) -> String {
        var text = input

        // 1. Standalone fillers ("um", "uh", "uhh", "erm", "ah", "ahh")
        for filler in rules.standaloneFillers {
            let esc = NSRegularExpression.escapedPattern(for: filler)

            // Sentence start with optional comma: "^um, " or "^um "
            text = text.replacingOccurrences(
                of: "(?i)^\\s*\(esc)[,\\s]+",
                with: "",
                options: .regularExpression
            )

            // After sentence ending punctuation: ". Um, " -> ". "
            text = text.replacingOccurrences(
                of: "(?i)([.!?]\\s*)\(esc)[,\\s]+",
                with: "$1",
                options: .regularExpression
            )

            // Surrounded by commas inside sentence: ", um," -> ","
            text = text.replacingOccurrences(
                of: "(?i),\\s*\(esc)\\s*,",
                with: ",",
                options: .regularExpression
            )

            // Between words with spaces: "think um we" -> "think we"
            text = text.replacingOccurrences(
                of: "(?i)\\b\\s+\(esc)\\b(?=\\s+)",
                with: "",
                options: .regularExpression
            )

            // At sentence end: ", um." -> "." or " um." -> "."
            text = text.replacingOccurrences(
                of: "(?i)[,\\s]+\(esc)(?=[.!?]|$)",
                with: "",
                options: .regularExpression
            )
        }

        // 2. Contextual fillers ("like", "you know", "i mean")
        for rule in rules.contextualFillers {
            let esc = NSRegularExpression.escapedPattern(for: rule.phrase)

            if rule.requirePunctuationBoundary {
                // Strict pause/comma boundaries to avoid touching verbs ("I like apples", "Do you know")
                // Surrounded by commas: ", like," -> ","
                text = text.replacingOccurrences(
                    of: "(?i),\\s*\(esc)\\s*,",
                    with: ",",
                    options: .regularExpression
                )

                // At start of sentence followed by comma: "Like, we went" -> "We went"
                text = text.replacingOccurrences(
                    of: "(?i)^\\s*\(esc),\\s*",
                    with: "",
                    options: .regularExpression
                )

                // After sentence punctuation followed by comma: ". You know, we" -> ". We"
                text = text.replacingOccurrences(
                    of: "(?i)([.!?]\\s*)\(esc),\\s*",
                    with: "$1",
                    options: .regularExpression
                )

                // Before sentence end: ", you know." -> "."
                text = text.replacingOccurrences(
                    of: "(?i),\\s*\(esc)(?=[.!?]|$)",
                    with: "",
                    options: .regularExpression
                )
            }
        }

        return text
    }

    // MARK: - Rule 2: Repeated Word Collapse

    /// Detects immediate word repetition ("the the", "I I", "is is") and collapses to single instance,
    /// preserving the leading word's casing.
    private func applyRepeatedWordCollapse(_ input: String) -> String {
        var text = input

        // Match adjacent duplicate words separated by whitespace: (\b[a-zA-Z0-9']+\b)\s+\1\b
        let pattern = "(?i)\\b([a-zA-Z0-9']+)\\s+(\\1)\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }

        var changed = true
        var passes = 0
        while changed && passes < 10 {
            changed = false
            passes += 1
            let ns = text as NSString
            if let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)) {
                let firstWordRange = match.range(at: 1)
                let firstWord = ns.substring(with: firstWordRange)
                text = ns.replacingCharacters(in: match.range, with: firstWord)
                changed = true
            }
        }

        return text
    }

    // MARK: - Rule 3: Sentence Boundary Capitalization

    /// Capitalizes the first word of the transcript and words immediately following sentence-ending punctuation (. ! ?),
    /// while respecting explicit custom vocabulary entries from VocabularyStore.
    private func applySentenceCapitalization(_ input: String, vocabularyStore: VocabularyStore?) -> String {
        var text = input
        guard !text.isEmpty else { return text }

        let customPhrases = vocabularyStore?.entries.map { $0.phrase } ?? []

        // 1. Capitalize first word of the transcript
        text = capitalizeLeadingWord(in: text, customPhrases: customPhrases)

        // 2. Capitalize after sentence-ending punctuation (. ! ?)
        let pattern = "([.!?])\\s+([a-zA-Z0-9]+)"
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let ns = text as NSString
            let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)).reversed()
            var mutable = text
            for match in matches {
                let punctRange = match.range(at: 1)
                let wordRange = match.range(at: 2)
                let punct = (mutable as NSString).substring(with: punctRange)
                let word = (mutable as NSString).substring(with: wordRange)

                let replacementWord = formatBoundaryWord(word, customPhrases: customPhrases)
                if replacementWord != word {
                    let replaceRange = NSRange(location: punctRange.location, length: (match.range.location + match.range.length) - punctRange.location)
                    mutable = (mutable as NSString).replacingCharacters(in: replaceRange, with: "\(punct) \(replacementWord)")
                }
            }
            text = mutable
        }

        return text
    }

    private func capitalizeLeadingWord(in text: String, customPhrases: [String]) -> String {
        let pattern = "^(\\s*)([a-zA-Z0-9]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length)) else {
            return text
        }
        let leadingSpace = (text as NSString).substring(with: match.range(at: 1))
        let firstWord = (text as NSString).substring(with: match.range(at: 2))

        let replacement = formatBoundaryWord(firstWord, customPhrases: customPhrases)
        return (text as NSString).replacingCharacters(in: match.range, with: leadingSpace + replacement)
    }

    private func formatBoundaryWord(_ word: String, customPhrases: [String]) -> String {
        // If the word matches a custom vocabulary entry (e.g. "iOS", "macOS", "eBay", "ABGen"),
        // respect the user's explicit casing!
        if let match = customPhrases.first(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) {
            return match
        }

        // Otherwise capitalize the first letter
        guard let first = word.first else { return word }
        return first.uppercased() + word.dropFirst()
    }

    // MARK: - Normalization Helpers

    private func normalizePunctuationAndSpacing(_ input: String) -> String {
        var text = input

        // Double commas ", ," -> ","
        text = text.replacingOccurrences(of: ",\\s*,", with: ",", options: .regularExpression)
        // Comma right after sentence end ". ," -> "."
        text = text.replacingOccurrences(of: "([.!?])\\s*,", with: "$1", options: .regularExpression)
        // Comma before period ", \\." -> "."
        text = text.replacingOccurrences(of: ",\\s*\\.", with: ".", options: .regularExpression)
        // Space before comma or period " ," -> ","
        text = text.replacingOccurrences(of: "\\s+([,.:;!?])", with: "$1", options: .regularExpression)
        // Multiple spaces -> single space
        text = text.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Options to toggle individual speech cleanup rules.
public struct SpeechCleanupOptions: Sendable, Equatable {
    public var isEnabled: Bool
    public var removeFillerWords: Bool
    public var collapseRepeatedWords: Bool
    public var handleSelfCorrections: Bool

    public init(
        isEnabled: Bool = true,
        removeFillerWords: Bool = true,
        collapseRepeatedWords: Bool = true,
        handleSelfCorrections: Bool = true
    ) {
        self.isEnabled = isEnabled
        self.removeFillerWords = removeFillerWords
        self.collapseRepeatedWords = collapseRepeatedWords
        self.handleSelfCorrections = handleSelfCorrections
    }

    public init(settings: LocalFlowSettings) {
        self.isEnabled = settings.cleanSpeechEnabled
        self.removeFillerWords = settings.removeFillerWords
        self.collapseRepeatedWords = settings.collapseRepeatedWords
        self.handleSelfCorrections = settings.handleSelfCorrections
    }
}
