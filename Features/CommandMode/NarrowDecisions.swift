import Foundation

/// System-1 observations only. No tool IDs, risk scores, identities or text slots.
public enum CoarseCommandFamily: String, Codable, CaseIterable, Sendable {
    case application, web, productivity, system, textFile = "text_file", media, other
}
public enum NarrowDecisionQuestion: String, Codable, CaseIterable, Sendable {
    case actionableCommand = "actionable_command", needsMoreSpeech = "needs_more_speech", correctionOrReplacement = "correction_or_replacement", coarseFamily = "coarse_family"
}
public struct NarrowSpeechDecisions: Codable, Equatable, Sendable {
    public let actionableCommand: ScoredDecision<Bool>?
    public let needsMoreSpeech: ScoredDecision<Bool>?
    public let correctionOrReplacement: ScoredDecision<Bool>?
    public let coarseFamily: ScoredDecision<CoarseCommandFamily>?
    public let inferenceMilliseconds: Double
    public init(actionableCommand: ScoredDecision<Bool>? = nil, needsMoreSpeech: ScoredDecision<Bool>? = nil,
                correctionOrReplacement: ScoredDecision<Bool>? = nil, coarseFamily: ScoredDecision<CoarseCommandFamily>? = nil, inferenceMilliseconds: Double = 0) {
        self.actionableCommand = actionableCommand; self.needsMoreSpeech = needsMoreSpeech
        self.correctionOrReplacement = correctionOrReplacement; self.coarseFamily = coarseFamily; self.inferenceMilliseconds = inferenceMilliseconds
    }
}
public enum NarrowRoutingResult: Equatable, Sendable { case parsed(CommandResolution), wait, abstain }
public enum NarrowDecisionPolicy {
    /// Exact commands bypass inference. Scores can only withhold uncertain work;
    /// returning .parsed sends the original deterministic slots to native policy.
    public static func route(_ parsed: CommandResolution, knownExact: Bool, isFinal: Bool, decisions: NarrowSpeechDecisions?) -> NarrowRoutingResult {
        if knownExact { return .parsed(parsed) }
        guard let decisions else { return .abstain }
        if let more = decisions.needsMoreSpeech, more.accepted, more.value { return isFinal ? .abstain : .wait }
        guard let action = decisions.actionableCommand, action.accepted, action.value else { return .abstain }
        if let correction = decisions.correctionOrReplacement, !correction.accepted { return .abstain }
        if !isFinal {
            if decisions.correctionOrReplacement?.value == true { return .wait }
            guard let more = decisions.needsMoreSpeech, more.accepted, !more.value else { return .wait }
        }
        return .parsed(parsed)
    }
}
public enum NarrowDecisionSchema {
    public static func data() throws -> Data {
        guard let url = Bundle.module.url(forResource: "laya-v2-questions", withExtension: "json") else { throw DecisionError.invalidInstallation }
        return try Data(contentsOf: url)
    }
}
