import Foundation

/// A word the user corrected right after LocalFlow inserted a dictation.
public struct LearnedCorrection: Equatable, Sendable {
    /// What the engine produced (e.g. "posh").
    public let heard: String
    /// What the user changed it to (e.g. "Pausch").
    public let corrected: String
}

/// Finds one-word fixes the user made inside freshly inserted dictation, so the word can be learned.
/// Pure function: AX reading and persistence live elsewhere.
public enum CorrectionDetector {
    /// - Parameters:
    ///   - inserted: The text LocalFlow pasted.
    ///   - before: The field's full text right after the paste.
    ///   - after: The field's full text once the user moved on.
    ///   - isCommonWord: True for an ordinary, correctly spelled dictionary word (lowercase input).
    public static func corrections(
        inserted: String,
        before: String,
        after: String,
        isCommonWord: (String) -> Bool
    ) -> [LearnedCorrection] {
        let inserted = inserted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !inserted.isEmpty, before != after,
              let insertedRange = before.range(of: inserted, options: .backwards) else { return [] }

        let old = tokens(in: before)
        let new = tokens(in: after)
        // Only words that were part of this dictation may be learned, never the user's own earlier text.
        let insertedWords = Set(old.indices.filter { old[$0].range.overlaps(insertedRange) })

        let diff = new.map(\.word).difference(from: old.map(\.word))
        var removed = Set<Int>(), added = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): added.insert(offset)
            }
        }

        // Walk both sides in step; a lone removed word facing a lone added word is a 1:1 substitution.
        var results: [LearnedCorrection] = []
        var i = 0, j = 0
        while i < old.count || j < new.count {
            let oldRun = run(from: i, in: removed, limit: old.count)
            let newRun = run(from: j, in: added, limit: new.count)
            if oldRun == 0 && newRun == 0 { i += 1; j += 1; continue }
            if oldRun == 1, newRun == 1, insertedWords.contains(i),
               let learned = accept(heard: old[i].word, corrected: new[j].word, isCommonWord: isCommonWord) {
                results.append(learned)
            }
            i += oldRun; j += newRun
        }
        return results
    }

    static func accept(heard: String, corrected: String, isCommonWord: (String) -> Bool) -> LearnedCorrection? {
        guard heard != corrected, corrected.count >= 2, heard.count >= 2,
              corrected.count <= 40, corrected.contains(where: \.isLetter) else { return nil }
        let a = heard.lowercased(), b = corrected.lowercased()
        // Case-only fix ("localflow" → "LocalFlow") always teaches the spelling.
        if a == b { return LearnedCorrection(heard: heard, corrected: corrected) }
        // Swapping one ordinary word for another ("their" → "there") is grammar, not vocabulary.
        let isSpecial = corrected != b || corrected.contains(where: \.isNumber) || !isCommonWord(b)
        guard isSpecial else { return nil }
        // Must still sound/look like the same word, otherwise the user rewrote the sentence.
        let distance = editDistance(Array(a), Array(b))
        let similar = distance <= 2 || (a.first == b.first && Double(distance) <= Double(max(a.count, b.count)) * 0.6)
        return similar ? LearnedCorrection(heard: heard, corrected: corrected) : nil
    }

    private static func run(from start: Int, in set: Set<Int>, limit: Int) -> Int {
        var end = start
        while end < limit, set.contains(end) { end += 1 }
        return end - start
    }

    private static func tokens(in text: String) -> [(word: String, range: Range<String.Index>)] {
        var result: [(String, Range<String.Index>)] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { word, range, _, _ in
            if let word { result.append((word, range)) }
        }
        return result
    }

    static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for (i, ca) in a.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: b.count)
            for (j, cb) in b.enumerated() {
                current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (ca == cb ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}
