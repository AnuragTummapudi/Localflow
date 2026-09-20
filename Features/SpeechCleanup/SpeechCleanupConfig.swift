import Foundation

/// Rules and triggers for deterministic local speech hygiene.
public struct SpeechCleanupRules: Codable, Sendable, Equatable {
    public var standaloneFillers: [String]
    public var contextualFillers: [ContextualFillerRule]
    public var selfCorrectionTriggers: [String]

    public init(
        standaloneFillers: [String] = ["um", "uh", "uhh", "erm", "ah", "ahh"],
        contextualFillers: [ContextualFillerRule] = [
            ContextualFillerRule(phrase: "like", requirePunctuationBoundary: true),
            ContextualFillerRule(phrase: "you know", requirePunctuationBoundary: true),
            ContextualFillerRule(phrase: "i mean", requirePunctuationBoundary: true)
        ],
        selfCorrectionTriggers: [String] = [
            "no actually",
            "no wait",
            "scratch that",
            "actually",
            "i mean"
        ]
    ) {
        self.standaloneFillers = standaloneFillers
        self.contextualFillers = contextualFillers
        self.selfCorrectionTriggers = selfCorrectionTriggers
    }

    public static let `default` = SpeechCleanupRules()

    /// Loads rules from the bundled SpeechCleanupRules.json or returns default fallback rules.
    public static func load() -> SpeechCleanupRules {
        #if SWIFT_PACKAGE
        if let url = Bundle.module.url(forResource: "SpeechCleanupRules", withExtension: "json", subdirectory: "Resources")
            ?? Bundle.module.url(forResource: "SpeechCleanupRules", withExtension: "json") {
            if let data = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode(SpeechCleanupRules.self, from: data) {
                return decoded
            }
        }
        #endif

        if let mainUrl = Bundle.main.url(forResource: "SpeechCleanupRules", withExtension: "json") {
            if let data = try? Data(contentsOf: mainUrl),
               let decoded = try? JSONDecoder().decode(SpeechCleanupRules.self, from: data) {
                return decoded
            }
        }

        return .default
    }
}

/// A contextual filler word rule with boundary requirements.
public struct ContextualFillerRule: Codable, Sendable, Equatable {
    public var phrase: String
    public var requirePunctuationBoundary: Bool

    public init(phrase: String, requirePunctuationBoundary: Bool = true) {
        self.phrase = phrase
        self.requirePunctuationBoundary = requirePunctuationBoundary
    }
}
