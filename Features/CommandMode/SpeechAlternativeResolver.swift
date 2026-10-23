import Foundation
import Shared

public struct SpeechInterpretation: Equatable, Sendable {
    public let phraseID: Int64
    public let original: String
    public let selected: String
    public let alternatives: [String]
    public var rescued: Bool { original != selected }
}

/// Alternatives may rescue only an exact unique installed/configured application
/// in the bounded open/launch grammar. No prose, query, domain or payload edits.
public enum SpeechAlternativeResolver {
    public static func selectAll(_ phrases: [SpeechPhrase], commands: CommandMode) -> [SpeechInterpretation] {
        var chosen: [SpeechInterpretation] = []
        for phrase in phrases {
            let prefix = SpeechCommandSegmenter.segments(chosen.map(\.selected).joined(separator: " "), continuous: true).last?.text ?? ""
            chosen.append(select(phrase, commands: commands, prefix: prefix))
        }
        return chosen
    }

    public static func select(_ phrase: SpeechPhrase, commands: CommandMode, prefix: String = "") -> SpeechInterpretation {
        func grammar(_ text: String) -> String? {
            let pattern = "(?i)^\\s*(open|launch)\\s+([\\p{L}\\p{N} _-]+)[.!?]?\\s*$"
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
            return (text as NSString).substring(with: match.range(at: 1)).lowercased()
        }
        func exact(_ text: String) -> String? {
            guard case .execute(let intent) = commands.resolve(text),
                  case .application(let app, _) = intent.agentAction.arguments,
                  commands.isExactApplicationOpen(text, action: intent.agentAction) || commands.isConfiguredApplicationOpen(text, action: intent.agentAction) else { return nil }
            return app.id
        }
        let context = grammar(phrase.text) == nil && !prefix.isEmpty ? prefix + " " : ""
        let primary = context + phrase.text
        var eligible = true
        switch commands.resolve(primary) {
        case .execute(let intent), .needsConfirmation(let intent): eligible = intent.agentAction.toolID == .openApplication
        case .notCommand: break
        }
        if primary.range(of: "(?i)\\b(?:and|then|actually|instead|wait|search|create|write)\\b", options: .regularExpression) != nil { eligible = false }
        var selected = phrase.text
        if eligible, let verb = grammar(primary), exact(primary) == nil {
            let candidates = phrase.alternatives.map { context + $0 }.filter { grammar($0) == verb }.compactMap { text -> (String, String)? in
                exact(text).map { (text, $0) }
            }
            if Set(candidates.map { $0.1 }).count == 1, let candidate = candidates.first {
                selected = String(candidate.0.dropFirst(context.count))
            }
        }
        return SpeechInterpretation(phraseID: phrase.id, original: phrase.text, selected: selected, alternatives: phrase.alternatives)
    }
}
