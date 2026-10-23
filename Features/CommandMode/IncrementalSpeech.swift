import Foundation

/// Evidence is counted across distinct ASR revisions, never repeated notifications or timers.
public struct StablePrefixTracker {
    private struct Word { var text: String; var since: TimeInterval; var observations: Int }
    private var words: [Word] = []
    private var previous = ""
    public init() {}
    public mutating func update(_ text: String, at time: TimeInterval) {
        guard text != previous else { return }
        previous = text
        let tokens = Self.tokens(text)
        guard tokens != words.map(\.text) else { return }
        var common = 0
        while common < min(words.count, tokens.count), words[common].text == tokens[common] { common += 1 }
        words = Array(words.prefix(common)).map { Word(text: $0.text, since: $0.since, observations: $0.observations + 1) }
            + tokens.dropFirst(common).map { Word(text: $0, since: time, observations: 1) }
    }
    public func stableWordCount(at time: TimeInterval, policy: SpeculationPolicy) -> Int {
        words.prefix { $0.observations >= policy.observations && time - $0.since >= policy.settleSeconds }.count
    }
    public static func tokens(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { $0.isWhitespace }).map {
            String($0).trimmingCharacters(in: .punctuationCharacters)
        }.filter { !$0.isEmpty }
    }
}

/// A conservative timing gate fitted to bundled, labeled ASR traces. Exact, unique app
/// identity is an additional mandatory gate; this score is not an invented Laya probability.
public struct SpeculationPolicy: Equatable, Sendable {
    public let observations: Int
    public let settleSeconds: TimeInterval
    public static func calibrated() throws -> Self {
        struct Sample: Decodable { let observations: Int; let age: Double; let safe: Bool }
        struct Fixture: Decodable { let calibration: [Sample] }
        guard let url = Bundle.module.url(forResource: "voice-agent-stability", withExtension: "json") else { throw DecisionError.invalidInstallation }
        let samples = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).calibration
        guard samples.contains(where: { $0.safe }), samples.contains(where: { !$0.safe }) else { throw DecisionError.invalidInstallation }
        let candidates = Set(samples.map(\.observations)).sorted().flatMap { count in
            Set(samples.map(\.age)).sorted().map { Self(observations: count, settleSeconds: $0) }
        }
        let safe = candidates.filter { candidate in
            !samples.contains { !$0.safe && $0.observations >= candidate.observations && $0.age >= candidate.settleSeconds }
        }
        guard let fitted = safe.max(by: { lhs, rhs in
            let l = samples.filter { $0.safe && $0.observations >= lhs.observations && $0.age >= lhs.settleSeconds }.count
            let r = samples.filter { $0.safe && $0.observations >= rhs.observations && $0.age >= rhs.settleSeconds }.count
            return l == r ? lhs.settleSeconds > rhs.settleSeconds : l < r
        }), samples.contains(where: { $0.safe && $0.observations >= fitted.observations && $0.age >= fitted.settleSeconds }) else { throw DecisionError.invalidInstallation }
        return fitted
    }
}

public struct SpeechCommandSegment: Equatable, Sendable {
    public let text: String
    public let endWord: Int
    public let closed: Bool
    public let startWord: Int
    public let independent: Bool
    public init(text: String, endWord: Int, closed: Bool, startWord: Int = 0, independent: Bool = false) {
        self.text = text; self.endWord = endWord; self.closed = closed
        self.startWord = startWord; self.independent = independent
    }
}

/// Split only an explicit connector followed by a known command verb. Text-bearing tools
/// consume the remaining stream, so "and open Safari" inside note text is never executed.
public enum SpeechCommandSegmenter {
    public static func segments(_ raw: String, continuous: Bool = false) -> [SpeechCommandSegment] {
        let verb = "(?:call it|name it|title it|write|run|start|open|launch|switch to|quit|search|create|mute|unmute|volume|set volume|sleep display|lock it|take|reveal|type at cursor|replace selected|copy to clipboard|append to current|write current|pause|resume|next track|previous track)\\b"
        let explicit = "(?i)(?:[,;]\\s*(?:(?:and then|and|then)\\s+)?|\\s+(?:and then|then|and)\\s+)(?=\(verb))"
        let pattern = continuous ? explicit.replacingOccurrences(of: "[,;]", with: "[,;.]" ) + "|(?i)\\s+(?=\(verb))" : explicit
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let source = raw as NSString
        let matches = regex.matches(in: raw, range: NSRange(location: 0, length: source.length))
        var start = 0
        var result: [SpeechCommandSegment] = []
        var independent = false
        for match in matches {
            let piece = source.substring(with: NSRange(location: start, length: match.range.location - start)).trimmingCharacters(in: .whitespacesAndNewlines)
            if carriesText(piece) || continuous && (piece.lowercased().hasPrefix("search ") || CommandMode.parseSearch(from: piece) != nil) { break }
            let separator = source.substring(with: match.range)
            let implicit = separator.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            // Bare headers are only for explicit agent speech with an anchored,
            // bounded application/navigation header to the left, never prose or queries.
            if implicit && !headerOnly(piece) { continue }
            result.append(SpeechCommandSegment(text: correctedApplication(piece), endWord: StablePrefixTracker.tokens(source.substring(to: match.range.location)).count, closed: true, startWord: StablePrefixTracker.tokens(source.substring(to: start)).count, independent: independent))
            start = NSMaxRange(match.range)
            independent = implicit || separator.contains(".")
        }
        let tail = source.substring(from: start).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { result.append(SpeechCommandSegment(text: correctedApplication(tail), endWord: StablePrefixTracker.tokens(raw).count, closed: false, startWord: StablePrefixTracker.tokens(source.substring(to: start)).count, independent: independent)) }
        return result
    }
    private static func headerOnly(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard ["open ", "launch ", "switch to ", "quit ", "go to ", "browse to "].contains(where: { lower.hasPrefix($0) }) else { return false }
        return StablePrefixTracker.tokens(text).count <= 4 && CommandMode.parseSearch(from: text) == nil
            && text.range(of: "(?i)\\b(?:actually|instead)\\b", options: .regularExpression) == nil
    }
    private static func carriesText(_ text: String) -> Bool {
        ["call it ", "name it ", "title it ", "create ", "type ", "replace ", "copy ", "append ", "write "].contains { text.lowercased().hasPrefix($0) }
    }
    private static func correctedApplication(_ text: String) -> String {
        let verbs = ["open ", "launch ", "switch to ", "quit "]
        guard let verb = verbs.first(where: { text.lowercased().hasPrefix($0) }),
              let range = text.range(of: "(?i)\\b(?:actually|instead)\\s+", options: .regularExpression) else { return text }
        let replacement = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return verbs.contains(where: { replacement.lowercased().hasPrefix($0) }) ? replacement : verb + replacement
    }

    /// Compound note customization is fused into ONE final create with exact title/body.
    public static func noteAction(_ text: String) -> AgentAction? {
        for (header, tool) in [("call it ", NativeToolID.renameNote), ("name it ", .renameNote), ("title it ", .renameNote), ("write ", .appendNote)] {
            if text.lowercased().hasPrefix(header) {
                let payload = String(text.dropFirst(header.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !payload.isEmpty else { return nil }
                return AgentAction(toolID: tool, arguments: .currentNote(payload))
            }
        }
        guard let root = text.range(of: "(?i)^create (?:a )?(?:new )?note\\b", options: .regularExpression) else { return nil }
        var rest = String(text[root.upperBound...]).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",")))
        // First distinguish customization grammar from a plain title/body. A word
        // such as "write" inside "create note My write plan" is payload, not a verb.
        let titleHeader = rest.range(of: "(?i)^(?:and\\s+)?(?:call it|called|name it|title it)\\s+", options: .regularExpression)
        var body = ""
        if let titleHeader {
            rest = String(rest[titleHeader.upperBound...])
            guard !rest.isEmpty else { return nil }
            // Only an explicit connector opens the body. Bare "write" inside the
            // named title cannot silently move source words to another argument.
            if let write = rest.range(of: "(?i)(?:,\\s*(?:and\\s+)?|\\s+and\\s+)write\\b\\s*", options: .regularExpression) {
                body = String(rest[write.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                rest = String(rest[..<write.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !rest.isEmpty, !body.isEmpty, body != "...", body != "…" else { return nil }
            }
        } else if let write = rest.range(of: "(?i)^(?:and\\s+)?write\\b\\s*", options: .regularExpression), text.lowercased().contains("new note") {
            body = String(rest[write.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            rest = ""
            guard !body.isEmpty, body != "...", body != "…" else { return nil }
        } else if !rest.isEmpty {
            return NativeCommandParser.parse("create note " + rest)
        }
        return AgentAction(toolID: .createNote, arguments: .note(title: rest.isEmpty ? "Untitled" : rest, body: body))
    }
}
