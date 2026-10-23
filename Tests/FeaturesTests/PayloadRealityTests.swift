import XCTest
import Shared
@testable import CommandMode

@MainActor final class PayloadRealityTests: LocalSettingsTestCase {
    func testFiveRealASRFailuresRemainFaithfulToTheSourceRatherThanGuessed() throws {
        // These are fixed synthetic-audio observations, not user transcripts.
        XCTAssertEqual(SpeechCommandSegmenter.noteAction("Create a new note, call it local flow benchmark.")?.arguments,
                       .note(title: "local flow benchmark.", body: ""))
        XCTAssertEqual(NativeCommandParser.parse("Append to current note, this is my dictated benchmark text.")?.arguments,
                       .currentNote("this is my dictated benchmark text."))
        XCTAssertEqual(NativeCommandParser.parse("Create reminder review local flow benchmark.")?.arguments,
                       .reminder(title: "review local flow benchmark."))
        XCTAssertEqual(CommandMode.parseURL(from: "examblow.com"), URL(string: "https://examblow.com"))
        let parts = SpeechCommandSegmenter.segments("Open notes then open browser then search for Swift Actors.")
        XCTAssertEqual(parts.last?.text, "search for Swift Actors.")
        XCTAssertEqual(CommandMode.parseSearch(from: try XCTUnwrap(parts.last?.text))?.query, "Swift Actors")
    }

    func testPlainNoteTitleAndBodyCannotBeRepartitionedByEmbeddedWriteVerb() {
        XCTAssertEqual(SpeechCommandSegmenter.noteAction("create note My write plan")?.arguments,
                       .note(title: "My write plan", body: ""))
        XCTAssertEqual(SpeechCommandSegmenter.noteAction("create note Meeting: write current note and open Safari")?.arguments,
                       .note(title: "Meeting", body: "write current note and open Safari"))
        XCTAssertEqual(SpeechCommandSegmenter.noteAction("create a note called My write plan")?.arguments,
                       .note(title: "My write plan", body: ""))
        XCTAssertEqual(SpeechCommandSegmenter.noteAction("create a new note, call it Draft, and write Keep CASE, accents: café. And open Notes.")?.arguments,
                       .note(title: "Draft", body: "Keep CASE, accents: café. And open Notes."))
        XCTAssertEqual(SpeechCommandSegmenter.segments("create note My write plan and open Safari").count, 1)
    }

    func testOperationalPayloadBypassesDictationVocabularyWhileDictationKeepsIt() throws {
        let vocabulary = VocabularyStore(settings: settings)
        vocabulary.add(phrase: "benchmark", replacement: "replacement text")
        let source = "create reminder Review benchmark"
        let agentText = vocabulary.apply(to: source, preserveOperationalPayload: true)
        let ordinaryText = vocabulary.apply(to: source)
        XCTAssertEqual(NativeCommandParser.parse(agentText)?.arguments, .reminder(title: "Review benchmark"))
        XCTAssertEqual(NativeCommandParser.parse(ordinaryText)?.arguments, .reminder(title: "Review replacement text"))
        let body = "type at cursor benchmark and open Notes"
        XCTAssertEqual(NativeCommandParser.parse(vocabulary.apply(to: body, preserveOperationalPayload: true))?.arguments,
                       .text("benchmark and open Notes"))
    }

    func testTypedSemanticDisagreementChangesOnlyConfirmationAndNeverPayload() throws {
        let original = AgentAction(toolID: .createNote, arguments: .note(title: "Exact title", body: "Exact BODY!"))
        let decisions = SpeechDecisions(intent: ScoredDecision(value: .webNavigation, confidence: try DecisionProbability(0.99), accepted: true),
                                       risk: nil, requiresMoreSpeech: nil)
        let resolution = DecisionCommandPolicy.resolve(.execute(.nativeAction(original)), decisions: decisions)
        guard case .needsConfirmation(let command) = resolution else { return XCTFail("Disagreement must request confirmation") }
        XCTAssertEqual(command.agentAction, original)
    }
}
