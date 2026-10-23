import XCTest
@testable import CommandMode

final class NarrowDecisionTests: XCTestCase {
    private func score(_ value: Bool, accepted: Bool = true) throws -> ScoredDecision<Bool> {
        ScoredDecision(value: value, confidence: try DecisionProbability(0.99), accepted: accepted)
    }
    func testSchemaHasOnlyFourDecisionsAndNoRiskOrExecutableSlots() throws {
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: NarrowDecisionSchema.data()) as? [[String: Any]])
        XCTAssertEqual(Set(rows.compactMap { $0["id"] as? String }), Set(NarrowDecisionQuestion.allCases.map(\.rawValue)))
        XCTAssertEqual(CoarseCommandFamily.allCases.count, 7)
    }
    func testKnownExactBypassesAllModelEvidence() throws {
        let contradictory = NarrowSpeechDecisions(actionableCommand: try score(false), needsMoreSpeech: try score(true), correctionOrReplacement: try score(true))
        XCTAssertEqual(NarrowDecisionPolicy.route(.execute(.mute), knownExact: true, isFinal: false, decisions: contradictory), .parsed(.execute(.mute)))
        XCTAssertEqual(NarrowDecisionPolicy.route(.execute(.mute), knownExact: true, isFinal: false, decisions: nil), .parsed(.execute(.mute)))
    }
    func testUncertainSpeechWaitsOrAbstainsAndCannotGenerateAction() throws {
        let more = NarrowSpeechDecisions(actionableCommand: try score(true), needsMoreSpeech: try score(true), correctionOrReplacement: try score(true))
        XCTAssertEqual(NarrowDecisionPolicy.route(.notCommand, knownExact: false, isFinal: false, decisions: more), .wait)
        XCTAssertEqual(NarrowDecisionPolicy.route(.notCommand, knownExact: false, isFinal: true, decisions: more), .abstain)
        let accepted = NarrowSpeechDecisions(actionableCommand: try score(true), needsMoreSpeech: try score(false), correctionOrReplacement: try score(false))
        XCTAssertEqual(NarrowDecisionPolicy.route(.notCommand, knownExact: false, isFinal: true, decisions: accepted), .parsed(.notCommand))
        XCTAssertEqual(NarrowDecisionPolicy.route(.needsConfirmation(.lockScreen), knownExact: false, isFinal: true, decisions: accepted), .parsed(.needsConfirmation(.lockScreen)))
    }
    func testCorrectionWaitsForAuthorityAndUncalibratedHeadAbstains() throws {
        let correction = NarrowSpeechDecisions(actionableCommand: try score(true), needsMoreSpeech: try score(false), correctionOrReplacement: try score(true))
        XCTAssertEqual(NarrowDecisionPolicy.route(.execute(.mute), knownExact: false, isFinal: false, decisions: correction), .wait)
        XCTAssertEqual(NarrowDecisionPolicy.route(.execute(.mute), knownExact: false, isFinal: true, decisions: correction), .parsed(.execute(.mute)))
        let rejected = NarrowSpeechDecisions(actionableCommand: try score(true), correctionOrReplacement: try score(false, accepted: false))
        XCTAssertEqual(NarrowDecisionPolicy.route(.execute(.mute), knownExact: false, isFinal: true, decisions: rejected), .abstain)
    }
    func testEveryConsequentialNativeToolRetainsAuthoritativeRisk() throws {
        let misleading = SpeechDecisions(intent: nil, risk: try ScoredDecision(value: DecisionRisk.safe, confidence: DecisionProbability(1), accepted: true), requiresMoreSpeech: nil)
        let pending = CommandResolution.needsConfirmation(.lockScreen)
        XCTAssertEqual(DecisionCommandPolicy.resolve(pending, decisions: misleading), pending)
        for id in [NativeToolID.quitApplication, .replaceSelection, .appendNote, .writeNote, .lockMac, .sleepDisplay] { XCTAssertEqual(id.risk, .consequential) }
    }
}
