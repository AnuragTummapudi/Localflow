import Foundation

/// Only explicit mappings are authoritative. A single pass over the source prevents
/// chained expansion, preserves unmapped bytes, and cannot turn payload into a header.
public enum PayloadCanonicalizer {
    public static func apply(_ source: String, mappings: [String: String]) -> String {
        guard !mappings.isEmpty else { return source }
        let keys = mappings.keys.sorted { $0.count == $1.count ? $0 < $1 : $0.count > $1.count }
        let pattern = "(?<![\\p{L}\\p{N}_])(?:" + keys.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + ")(?![\\p{L}\\p{N}_])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return source }
        let original = source as NSString
        var result = source
        for match in regex.matches(in: source, range: NSRange(location: 0, length: original.length)).reversed() {
            let literal = original.substring(with: match.range)
            guard let key = keys.first(where: { $0.caseInsensitiveCompare(literal) == .orderedSame }),
                  let replacement = mappings[key], let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }
}
