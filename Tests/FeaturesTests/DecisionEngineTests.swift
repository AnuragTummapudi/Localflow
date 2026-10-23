import XCTest
@testable import CommandMode

@MainActor
final class DecisionEngineTests: XCTestCase {
    private struct Catalog: ApplicationCatalog {
        func installedApplications() -> [ApplicationMatch] {
            [ApplicationMatch(name: "Notes", bundleIdentifier: "test.notes", url: nil, confidence: 1)]
        }
    }
    func testProbabilityRejectsInvalidValuesAndInvalidDecodedValues() throws {
        for value in [-0.1, 1.1, Double.nan, .infinity] { XCTAssertThrowsError(try DecisionProbability(value)) }
        XCTAssertThrowsError(try JSONDecoder().decode(DecisionProbability.self, from: Data("1.5".utf8)))
        XCTAssertEqual(try DecisionProbability(0).value, 0)
        XCTAssertEqual(try DecisionProbability(1).value, 1)
    }
    func testDeterministicFallbackUsesExistingParserAndQuestions() async throws {
        let engine = DeterministicDecisionEngine(commands: CommandMode(catalog: Catalog()))
        let result = try await engine.evaluate(DecisionState(text: "Open Notes"), questions: [.intent, .risk])
        XCTAssertEqual(result.intent?.value, .openApplication)
        XCTAssertEqual(result.risk?.value, .reversible)
        XCTAssertNil(result.requiresMoreSpeech)
        let dictation = try await engine.evaluate(DecisionState(text: "The meeting begins at noon."))
        XCTAssertEqual(dictation.intent?.value, .dictation)
        XCTAssertEqual(dictation.requiresMoreSpeech?.value, false)
    }
    func testRiskMappingPreservesConsequentialActions() throws {
        let parsed = CommandMode(catalog: Catalog()).resolve("quit Notes")
        let result = try DeterministicDecisionEngine.decisions(for: parsed, isFinal: true)
        XCTAssertEqual(result.intent?.value, .closeApplication)
        XCTAssertEqual(result.risk?.value, .consequential)
    }
    func testPartialStateCannotBeTreatedAsComplete() async throws {
        let result = try await DeterministicDecisionEngine(commands: CommandMode(catalog: Catalog()))
            .evaluate(DecisionState(text: "open", isFinal: false))
        XCTAssertEqual(result.requiresMoreSpeech?.value, true)
    }
    func testModelCannotCreateUnsupportedActionsOrRelaxConfirmation() throws {
        let decisions = SpeechDecisions(intent: ScoredDecision(value: .reminderAction, confidence: try DecisionProbability(1), accepted: true), risk: nil, requiresMoreSpeech: nil)
        XCTAssertEqual(DecisionCommandPolicy.resolve(.notCommand, decisions: decisions), .notCommand)
        let pending = CommandResolution.needsConfirmation(.mute)
        XCTAssertEqual(DecisionCommandPolicy.resolve(pending, decisions: decisions), pending)
        XCTAssertEqual(DecisionCommandPolicy.resolve(.execute(.mute), decisions: decisions), .needsConfirmation(.mute))
    }
    func testAbstainedScoresDoNotChangeExistingResolution() throws {
        let decisions = SpeechDecisions(intent: ScoredDecision(value: .dictation, confidence: try DecisionProbability(0.9), accepted: false), risk: ScoredDecision(value: .consequential, confidence: try DecisionProbability(0.9), accepted: false), requiresMoreSpeech: nil)
        XCTAssertEqual(DecisionCommandPolicy.resolve(.execute(.mute), decisions: decisions), .execute(.mute))
    }
    func testModelRiskHasNoAuthorityAndMoreSpeechRequiresConfirmation() throws {
        let risk = SpeechDecisions(intent: nil, risk: ScoredDecision(value: .consequential, confidence: try DecisionProbability(0.99), accepted: true), requiresMoreSpeech: nil)
        XCTAssertEqual(DecisionCommandPolicy.resolve(.execute(.mute), decisions: risk), .execute(.mute))
        let more = SpeechDecisions(intent: nil, risk: nil, requiresMoreSpeech: ScoredDecision(value: true, confidence: try DecisionProbability(0.99), accepted: true))
        XCTAssertEqual(DecisionCommandPolicy.resolve(.execute(.mute), decisions: more), .needsConfirmation(.mute))
    }
}
