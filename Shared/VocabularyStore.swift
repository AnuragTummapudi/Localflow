import Foundation
import Combine

/// A shared store for custom vocabulary entries and shortcuts.
public final class VocabularyStore: ObservableObject, @unchecked Sendable {
    /// Pre-seeds default dictionary items matching the user's reference entries.
    public static let defaultSeedEntries: [VocabularyEntry] = [
        VocabularyEntry(phrase: "INR", replacement: "", isFavorite: false, hasSparkle: true),
        VocabularyEntry(phrase: "ABGen", replacement: "", isFavorite: false, hasSparkle: true),
        VocabularyEntry(phrase: "Anurag Tummapudi", replacement: "", isFavorite: false, hasSparkle: false),
        VocabularyEntry(phrase: "Mckarthy", replacement: "", isFavorite: false, hasSparkle: true),
        VocabularyEntry(phrase: "Pausch", replacement: "", isFavorite: false, hasSparkle: true),
        VocabularyEntry(phrase: "tummapudianurag@gmail.com", replacement: "", isFavorite: false, hasSparkle: false),
        VocabularyEntry(phrase: "Wispr Flow", replacement: "", isFavorite: false, hasSparkle: false),
        VocabularyEntry(phrase: "Anurag", replacement: "", isFavorite: false, hasSparkle: false),
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

        switch phrase.lowercased() {
        case "inr":
            current = replaceRegex(pattern: "(?i)\\b(i\\s*n\\s*r|i\\.n\\.r\\.?|inr)\\b", with: replacement, in: current)
        case "abgen":
            current = replaceRegex(pattern: "(?i)\\b(a\\s*b\\s*gen|ab\\s*gen|abgen)\\b", with: replacement, in: current)
        case "mckarthy":
            current = replaceRegex(pattern: "(?i)\\b(mccarthy|mc\\s*carthy|macarthy|mckarthy)\\b", with: replacement, in: current)
        case "pausch":
            current = replaceRegex(pattern: "(?i)\\b(pausch|posh|poush)\\b", with: replacement, in: current)
        case "wispr flow":
            current = replaceRegex(pattern: "(?i)\\b(whisper\\s*flow|wisper\\s*flow|wispr\\s*flow)\\b", with: replacement, in: current)
        default:
            if phrase.count <= 5 && phrase.allSatisfy({ $0.isLetter }) {
                let spaced = phrase.map { String($0) }.joined(separator: "\\s+")
                current = replaceRegex(pattern: "(?i)\\b\(spaced)\\b", with: replacement, in: current)
            }
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
