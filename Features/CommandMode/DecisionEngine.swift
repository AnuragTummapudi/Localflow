import Foundation

public enum VoiceIntent: String, Codable, CaseIterable, Sendable {
    case dictation, openApplication = "open_application", switchApplication = "switch_application"
    case closeApplication = "close_application", webNavigation = "web_navigation", search
    case noteAction = "note_action", reminderAction = "reminder_action", mediaAction = "media_action"
    case systemAction = "system_action", unknown
}

public enum DecisionRisk: String, Codable, CaseIterable, Sendable { case safe, reversible, consequential }
public enum DecisionQuestion: String, Codable, CaseIterable, Sendable { case intent, risk, requiresMoreSpeech = "requires_more_speech" }

/// A validated probability, never an unbounded model score or NaN.
public struct DecisionProbability: Codable, Equatable, Sendable {
    public let value: Double
    public init(_ value: Double) throws {
        guard value.isFinite, (0...1).contains(value) else { throw DecisionError.invalidResponse }
        self.value = value
    }
    public init(from decoder: Decoder) throws { try self.init(decoder.singleValueContainer().decode(Double.self)) }
    public func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(value) }
}

public struct ScoredDecision<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public let value: Value
    public let confidence: DecisionProbability
    /// False means the local calibration policy abstained; exact parsing remains authoritative.
    public let accepted: Bool
    public init(value: Value, confidence: DecisionProbability, accepted: Bool) {
        self.value = value; self.confidence = confidence; self.accepted = accepted
    }
}

public struct DecisionState: Codable, Sendable {
    public let text: String
    public let isFinal: Bool
    public let languageCode: String
    public init(text: String, isFinal: Bool = true, languageCode: String = "en") {
        self.text = text; self.isFinal = isFinal; self.languageCode = languageCode
    }
}

public struct SpeechDecisions: Codable, Equatable, Sendable {
    public let intent: ScoredDecision<VoiceIntent>?
    public let risk: ScoredDecision<DecisionRisk>?
    public let requiresMoreSpeech: ScoredDecision<Bool>?
    public let inferenceMilliseconds: Double
    public let narrow: NarrowSpeechDecisions?
    public init(intent: ScoredDecision<VoiceIntent>?, risk: ScoredDecision<DecisionRisk>?, requiresMoreSpeech: ScoredDecision<Bool>?, inferenceMilliseconds: Double = 0, narrow: NarrowSpeechDecisions? = nil) {
        self.intent = intent; self.risk = risk; self.requiresMoreSpeech = requiresMoreSpeech
        self.inferenceMilliseconds = inferenceMilliseconds; self.narrow = narrow
    }
}

public enum DecisionError: Error, Equatable { case unavailable, invalidResponse, timedOut, unsupportedLanguage, invalidInstallation }

/// Implementations return decisions only. They never extract slots, generate text or execute tools.
public protocol DecisionEngine: Sendable {
    func evaluate(_ state: DecisionState, questions: Set<DecisionQuestion>) async throws -> SpeechDecisions
}

/// Preserves the existing CommandMode parser as the always-available production fallback.
@MainActor
public final class DeterministicDecisionEngine: DecisionEngine {
    private let commands: CommandMode
    public init(commands: CommandMode = CommandMode()) { self.commands = commands }
    public func evaluate(_ state: DecisionState, questions: Set<DecisionQuestion> = Set(DecisionQuestion.allCases)) async throws -> SpeechDecisions {
        try Task.checkCancellation()
        return try Self.decisions(for: commands.resolve(state.text), isFinal: state.isFinal, questions: questions)
    }
    public static func decisions(for resolution: CommandResolution, isFinal: Bool, questions: Set<DecisionQuestion> = Set(DecisionQuestion.allCases)) throws -> SpeechDecisions {
        let intent: VoiceIntent
        let risk: DecisionRisk
        let confidence: Double
        switch resolution {
        case .notCommand: intent = .dictation; risk = .safe; confidence = 1
        case .execute(let command), .needsConfirmation(let command):
            intent = command.decisionIntent; risk = command.decisionRisk
            switch command {
            case .openApplication(let match), .quitApplication(let match), .switchToApplication(let match): confidence = match.confidence
            default: confidence = 1
            }
        }
        return SpeechDecisions(
            intent: questions.contains(.intent) ? ScoredDecision(value: intent, confidence: try DecisionProbability(confidence), accepted: true) : nil,
            risk: questions.contains(.risk) ? ScoredDecision(value: risk, confidence: try DecisionProbability(1), accepted: true) : nil,
            requiresMoreSpeech: questions.contains(.requiresMoreSpeech) ? ScoredDecision(value: !isFinal, confidence: try DecisionProbability(1), accepted: true) : nil)
    }
}

public extension CommandIntent {
    var decisionIntent: VoiceIntent {
        switch self {
        case .nativeAction(let action):
            switch action.toolID {
            case .openApplication: return .openApplication
            case .focusApplication: return .switchApplication
            case .quitApplication: return .closeApplication
            case .openURL, .openWebsite: return .webNavigation
            case .searchWeb, .searchProvider: return .search
            case .createReminder: return .reminderAction
            case .createNote, .appendNote, .writeNote, .renameNote: return .noteAction
            case .spotifyTransport, .spotifySearch: return .mediaAction
            default: return .systemAction
            }
        case .openApplication: return .openApplication
        case .switchToApplication: return .switchApplication
        case .quitApplication: return .closeApplication
        case .openURL: return .webNavigation
        case .searchWeb: return .search
        case .spotifyControl, .spotifySearchAndPlay: return .mediaAction
        case .mute, .unmute, .sleepDisplay, .lockScreen: return .systemAction
        }
    }
    var decisionRisk: DecisionRisk {
        switch agentAction.toolID.risk {
        case .safe: return .safe
        case .reversible: return .reversible
        case .consequential: return .consequential
        }
    }
}

/// Laya may request confirmation for a parsed action. It cannot invent an executable action,
/// relax an existing confirmation, or turn unsupported note/reminder intents into tools.
public enum DecisionCommandPolicy {
    public static func resolve(_ parsed: CommandResolution, decisions: SpeechDecisions) -> CommandResolution {
        guard case .execute(let command) = parsed else { return parsed }
        if let intent = decisions.intent, intent.accepted, intent.value != command.decisionIntent { return .needsConfirmation(command) }
        if let more = decisions.requiresMoreSpeech, more.accepted, more.value { return .needsConfirmation(command) }
        return parsed
    }
}

public enum DecisionQuestionSchema {
    public static func data() throws -> Data {
        guard let url = Bundle.module.url(forResource: "laya-questions", withExtension: "json") else { throw DecisionError.invalidInstallation }
        return try Data(contentsOf: url)
    }
}
