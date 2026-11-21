import Foundation
import Combine

/// A shared store for custom vocabulary entries and shortcuts.
public final class VocabularyStore: ObservableObject, @unchecked Sendable {
    /// Starter entry for new installs. Keep this generic: it ships to every user.
    public static let defaultSeedEntries: [VocabularyEntry] = [
        VocabularyEntry(phrase: "btw", replacement: "by the way", isFavorite: false, hasSparkle: false),
    ]

    /// The persisted vocabulary entries.
    @Published public private(set) var entries: [VocabularyEntry]

    private let settings: LocalFlowSettings

    /// Creates a vocabulary store backed by shared settings.
    public init(settings: LocalFlowSettings = .shared) {
        self.settings = settings
        let stored = settings.customVocabulary
        if stored.isEmpty {
            self.entries = Self.defaultSeedEntries
            settings.customVocabulary = Self.defaultSeedEntries
        } else {
            self.entries = stored
        }
    }

    /// Adds a word or phrase correction.
    public func add(
        phrase: String,
        replacement: String = "",
        isFavorite: Bool = false,
        hasSparkle: Bool = false
    ) {
        let trimmedPhrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPhrase.isEmpty else { return }
        let entry = VocabularyEntry(
            phrase: trimmedPhrase,
            replacement: replacement.trimmingCharacters(in: .whitespacesAndNewlines),
            isFavorite: isFavorite,
            hasSparkle: hasSparkle
        )
        entries.append(entry)
        persist()
    }

    /// Learns a correction the user made after a dictation. Returns false when nothing new was added.
    /// Case-only fixes store the spelling; other fixes map the misheard word to the correction.
    @discardableResult
    public func learn(_ correction: LearnedCorrection) -> Bool {
        let heard = correction.heard.lowercased()
        let caseOnly = heard == correction.corrected.lowercased()
        // Skip if this word is already known (as a word, or as the target of a mapping) or the mishearing is mapped.
        let known = entries.contains { entry in
            let phrase = entry.phrase.lowercased()
            return (!caseOnly && phrase == heard)
                || entry.phrase == correction.corrected
                || entry.replacement == correction.corrected && phrase == heard
        }
        guard !known else { return false }
        entries.append(VocabularyEntry(
            phrase: caseOnly ? correction.corrected : correction.heard,
            replacement: caseOnly ? "" : correction.corrected,
            isLearned: true
        ))
        persist()
        return true
    }

    /// Updates an existing vocabulary entry.
    public func update(entry: VocabularyEntry) {
        if let idx = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[idx] = entry
            persist()
        }
    }

    /// Toggles the favorite status of an entry.
    public func toggleFavorite(id: UUID) {
        if let idx = entries.firstIndex(where: { $0.id == id }) {
            entries[idx].isFavorite.toggle()
            persist()
        }
    }

    /// Removes vocabulary entries at the supplied offsets.
    public func remove(at offsets: IndexSet) {
        for offset in offsets.sorted(by: >) {
            entries.remove(at: offset)
        }
        persist()
    }

    /// Removes a specific entry by its ID.
    public func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        persist()
    }

    /// Applies custom vocabulary replacements and corrections to transcribed text.
    public func apply(to text: String) -> String {
        guard !text.isEmpty, !entries.isEmpty else { return text }

        // Sort: favorites first, then longer phrases first to prevent partial clobbering
        let sorted = entries.sorted { lhs, rhs in
            if lhs.isFavorite != rhs.isFavorite {
                return lhs.isFavorite && !rhs.isFavorite
            }
            return lhs.phrase.count > rhs.phrase.count
        }

        var result = text
        for entry in sorted {
            let phrase = entry.phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !phrase.isEmpty else { continue }

            // 1. Spoken email recognition for email entries
            if phrase.contains("@") {
                result = applySpokenEmail(phrase: phrase, in: result)
            }

            // 2. Smart phonetic recognition if enabled (✨)
            if entry.hasSparkle {
                result = applySmartPhonetics(for: entry, in: result)
            }

            // 3. Exact word-boundary replacement
            result = applyWordBoundaryReplacement(entry: entry, in: result)
        }

        return result
    }

    private func applySpokenEmail(phrase: String, in text: String) -> String {
        guard phrase.contains("@") else { return text }
        let parts = phrase.components(separatedBy: "@")
        guard parts.count == 2 else { return text }
        let user = parts[0]
        let domain = parts[1]
        let escapedUser = NSRegularExpression.escapedPattern(for: user)
        let domainParts = domain.components(separatedBy: ".")
        let domainPattern = domainParts
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "\\s*(?:\\.|dot)\\s*")

        let pattern = "(?i)\\b\(escapedUser)\\s*(?:at|@)\\s*\(domainPattern)\\b"
        return replaceRegex(pattern: pattern, with: phrase, in: text)
    }

    private func applySmartPhonetics(for entry: VocabularyEntry, in text: String) -> String {
        var current = text
        let phrase = entry.phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = entry.isShortcut ? entry.replacement.trimmingCharacters(in: .whitespacesAndNewlines) : phrase

        // Generic rule: a short letter/digit term may be heard spelled out or split up
        // ("a b gen", "i.n.r.", "ab gen" → "ABGen" / "INR"). Specific sound-alikes are learned
        // per user from their corrections, never hard-coded here.
        let compact = phrase.filter { !$0.isWhitespace }
        if (2...8).contains(compact.count), compact.allSatisfy({ $0.isLetter || $0.isNumber }) {
            let pattern = compact.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "[\\s.]*")
            current = replaceRegex(pattern: "(?i)(?<!\\w)\(pattern)(?!\\w)", with: replacement, in: current)
        }

        return current
    }

    private func applyWordBoundaryReplacement(entry: VocabularyEntry, in text: String) -> String {
        let phrase = entry.phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return text }

        let target = entry.isShortcut ? entry.replacement.trimmingCharacters(in: .whitespacesAndNewlines) : phrase
        guard !target.isEmpty else { return text }

        // Use non-word boundaries (?<!\w) ... (?!\w) to avoid matching substrings inside words
        let escaped = NSRegularExpression.escapedPattern(for: phrase)
        let pattern = "(?<!\\w)\(escaped)(?!\\w)"

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }

        let nsString = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length))
        guard !matches.isEmpty else { return text }

        var output = ""
        var lastIndex = 0

        for match in matches {
            let matchRange = match.range
            if matchRange.location > lastIndex {
                output += nsString.substring(with: NSRange(location: lastIndex, length: matchRange.location - lastIndex))
            }

            let matchedSubstring = nsString.substring(with: matchRange)
            let replacementString: String

            if entry.isShortcut {
                if let firstChar = matchedSubstring.first, firstChar.isUppercase {
                    replacementString = target.prefix(1).uppercased() + target.dropFirst()
                } else {
                    replacementString = target
                }
            } else {
                replacementString = target
            }

            output += replacementString
            lastIndex = matchRange.location + matchRange.length
        }

        if lastIndex < nsString.length {
            output += nsString.substring(with: NSRange(location: lastIndex, length: nsString.length - lastIndex))
        }

        return output
    }

    private func replaceRegex(pattern: String, with replacement: String, in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: NSRegularExpression.escapedTemplate(for: replacement)
        )
    }

    private func persist() {
        settings.customVocabulary = entries
    }
}
