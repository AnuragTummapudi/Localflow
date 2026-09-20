import XCTest
@testable import Shared
@testable import SpeechCleanup

final class SpeechCleanupTests: XCTestCase {
    private var cleanup: SpeechCleanup!

    override func setUp() {
        super.setUp()
        cleanup = SpeechCleanup()
    }

    // MARK: - Rule 1: Standalone and Contextual Filler Word Removal

    func testStandaloneFillerAtStart() {
        let input = "Um, let's meet tomorrow at the office."
        let output = cleanup.clean(input)
        XCTAssertEqual(output, "Let's meet tomorrow at the office.")
    }

    func testStandaloneFillerInMiddle() {
        let input = "I think um we should proceed with the launch."
        let output = cleanup.clean(input)
        XCTAssertEqual(output, "I think we should proceed with the launch.")
    }

    func testMultipleFillersInSentence() {
        let input = "Uh, we can, uhh, discuss this later, erm, today."
        let output = cleanup.clean(input)
        XCTAssertEqual(output, "We can, discuss this later, today.")
    }

    func testFillerSubstringsAreNotRemoved() {
        let input = "The umbrella was humming ahead of time."
        let output = cleanup.clean(input)
        XCTAssertEqual(output, "The umbrella was humming ahead of time.")
    }

    func testContextualFillerLikeSurroundedByCommas() {
        let input = "It was, like, completely unexpected."
        let output = cleanup.clean(input)
        XCTAssertEqual(output, "It was, completely unexpected.")
    }

    func testContextualFillerLikeLeadingSentence() {
        let input = "Like, we need to finalize the quarterly roadmap."
        let output = cleanup.clean(input)
        XCTAssertEqual(output, "We need to finalize the quarterly roadmap.")
    }

    func testContextualFillerLikeAsVerbPreserved() {
        let input = "I like apples and oranges."
        let output = cleanup.clean(input)
        XCTAssertEqual(output, "I like apples and oranges.")
    }

    func testContextualFillerYouKnowSurroundedByCommas() {
        let input = "We should, you know, review the PR first."
        let output = cleanup.clean(input)
        XCTAssertEqual(output, "We should, review the PR first.")
    }

    func testContextualFillerYouKnowAsVerbPreserved() {
        let input = "Do you know what time the presentation starts?"
        let output = cleanup.clean(input)
        XCTAssertEqual(output, "Do you know what time the presentation starts?")
    }

    // MARK: - Rule 2: Repeated Word Collapse

    func testRepeatedWordCollapsePreservesCasing() {
        let input = "The the report is ready."
        let output = cleanup.clean(input)
        XCTAssertEqual(output, "The report is ready.")
    }

    func testRepeatedWordCollapseLowercase() {
        let input = "We went to the the office."
        let output = cleanup.clean(input)
        XCTAssertEqual(output, "We went to the office.")
    }

    func testRepeatedWordCollapsePronounsAndVerbs() {
        let input = "I I think this is is good."
        let output = cleanup.clean(input)
        XCTAssertEqual(output, "I think this is good.")
    }

    func testRepeatedWordCollapseTriplicate() {
        let input = "Wait wait wait here."
        let output = cleanup.clean(input)
        XCTAssertEqual(output, "Wait here.")
    }

    // MARK: - Rule 3: Capitalization at Sentence Boundaries

    func testCapitalizeTranscriptStart() {
        let input = "good morning everyone."
        let output = cleanup.clean(input)
        XCTAssertEqual(output, "Good morning everyone.")
    }

    func testCapitalizeAfterSentenceTerminators() {
        let input = "first point. second point! third point? fourth point."
        let output = cleanup.clean(input)
        XCTAssertEqual(output, "First point. Second point! Third point? Fourth point.")
    }

    func testCapitalizeRespectsCustomVocabularyCasing() {
        let testDefaults = UserDefaults(suiteName: "SpeechCleanupTestsSuite")!
        testDefaults.removePersistentDomain(forName: "SpeechCleanupTestsSuite")
        let settings = LocalFlowSettings(defaults: testDefaults)
        let store = VocabularyStore(settings: settings)
        store.add(phrase: "iOS")
        store.add(phrase: "macOS")
        store.add(phrase: "ABGen")
        let input = "iOS is great. macOS is also supported. abgen was tested."
        let output = cleanup.clean(input, vocabularyStore: store)
        XCTAssertEqual(output, "iOS is great. macOS is also supported. ABGen was tested.")
    }

    // MARK: - Rule 4: Self-Correction Triggers

    func testExactRequiredSelfCorrectionCase() {
        // Exact test required by spec: "5pm, no actually 6pm" -> "6pm"
        let input = "5pm, no actually 6pm"
        let output = cleanup.clean(input)
        XCTAssertEqual(output, "6pm")
    }

    func testSelfCorrectionWithNoWait() {
        let input = "Let's meet Tuesday, no wait, Wednesday morning."
        let output = cleanup.clean(input)
        XCTAssertEqual(output, "Wednesday morning.")
    }

    func testSelfCorrectionWithScratchThatAcrossSentences() {
        let input = "Send an email to John. Scratch that, send it to Sarah."
        let output = cleanup.clean(input)
        XCTAssertEqual(output, "Send it to Sarah.")
    }

    func testSelfCorrectionWithActually() {
        let input = "We will order pizza, actually sushi tonight."
        let output = cleanup.clean(input)
        XCTAssertEqual(output, "Sushi tonight.")
    }

    func testSelfCorrectionAtStartOfInput() {
        let input = "Actually, let's postpone the meeting."
        let output = cleanup.clean(input)
        XCTAssertEqual(output, "Let's postpone the meeting.")
    }

    // MARK: - Combined Pipeline & Options Toggling

    func testCombinedMessySpeechCleanup() {
        let input = "Um, the the meeting is at 5pm, no actually 6pm. Like, don't be late."
        let output = cleanup.clean(input)
        XCTAssertEqual(output, "6pm. Don't be late.")
    }

    func testOptionsCanDisableSpecificRules() {
        let input = "Um, the the meeting is at 5pm, no actually 6pm."

        // Disable filler removal
        var options = SpeechCleanupOptions(removeFillerWords: false)
        var output = cleanup.clean(input, options: options)
        XCTAssertTrue(output.contains("6pm"))

        // Disable repeat collapse
        options = SpeechCleanupOptions(collapseRepeatedWords: false)
        let repeatInput = "The the plan is solid."
        output = cleanup.clean(repeatInput, options: options)
        XCTAssertEqual(output, "The the plan is solid.")

        // Master disabled
        options = SpeechCleanupOptions(isEnabled: false)
        output = cleanup.clean(input, options: options)
        XCTAssertEqual(output, input)
    }

    func testRulesLoadFromJSON() {
        let rules = SpeechCleanupRules.load()
        XCTAssertFalse(rules.standaloneFillers.isEmpty)
        XCTAssertFalse(rules.contextualFillers.isEmpty)
        XCTAssertFalse(rules.selfCorrectionTriggers.isEmpty)
        XCTAssertTrue(rules.standaloneFillers.contains("um"))
        XCTAssertTrue(rules.selfCorrectionTriggers.contains("no actually"))
    }
}
