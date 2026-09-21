import XCTest
@testable import Shared
@testable import SmartFormatting
@testable import SpeechCleanup

final class SmartFormattingTests: XCTestCase {
    func testDestinationResolutionUsesOnlyExplicitAllowlist() {
        let formatter = SmartFormatting()
        XCTAssertEqual(formatter.profile(for: "com.tinyspeck.slackmacgap"), .slack)
        XCTAssertEqual(formatter.profile(for: "com.google.Chrome", activeDomain: "app.slack.com"), .slack)
        XCTAssertEqual(formatter.profile(for: "com.google.Gmail"), .gmail)
        XCTAssertEqual(formatter.profile(for: "com.google.Chrome", activeDomain: "mail.google.com"), .gmail)
        for identifier in ["com.openai.codex", "com.anthropic.claudefordesktop", "com.microsoft.VSCode", "com.apple.Terminal", "com.google.Chrome"] {
            XCTAssertEqual(formatter.profile(for: identifier), .neutral)
        }
    }

    func testNeutralFormattingPreservesTechnicalLiterals() {
        let formatter = SmartFormatting()
        let output = formatter.format("fix userID in src/auth.ts with --dry-run at https://example.com", profile: .neutral)
        XCTAssertTrue(output.contains("userID"))
        XCTAssertTrue(output.contains("src/auth.ts"))
        XCTAssertTrue(output.contains("--dry-run"))
        XCTAssertTrue(output.contains("https://example.com"))
    }

    func testSlackFormattingIsLightAndGmailDoesNotInventStructure() {
        let formatter = SmartFormatting()
        XCTAssertEqual(formatter.format("sounds good thanks", profile: .slack), "Sounds good thanks")
        XCTAssertEqual(formatter.format("thanks for the update", profile: .gmail), "Thanks for the update.")
    }

    func testDestinationPipelineRemovesFillersWithoutInventingContent() {
        let cleanup = SpeechCleanup()
        let formatter = SmartFormatting()
        let gmailSource = "hi team uh can you send the notes before our call and flag anything that needs a decision"
        let gmail = formatter.format(cleanup.clean(gmailSource), profile: .gmail)
        XCTAssertFalse(gmail.lowercased().contains(" uh "))
        XCTAssertTrue(gmail.contains("Hi team"))
        XCTAssertTrue(gmail.contains("notes before our call"))
        XCTAssertFalse(gmail.contains("Best,"))
        XCTAssertFalse(gmail.contains("Subject:"))

        let slackSource = "hey deployment is done staging looks good auth tests are still failing will check after lunch"
        let slack = formatter.format(cleanup.clean(slackSource), profile: .slack)
        XCTAssertTrue(slack.contains("deployment"))
        XCTAssertTrue(slack.contains("auth tests"))
        XCTAssertFalse(slack.contains("Hi,"))
        XCTAssertFalse(slack.contains("Best,"))
    }

    func testNeutralDeveloperDictationNeverCreatesPromptLabels() {
        let formatter = SmartFormatting()
        let output = formatter.format("fix login redirect in src/auth.ts keep public API unchanged and tell me which tests prove the fix", profile: .neutral)
        XCTAssertTrue(output.contains("src/auth.ts"))
        for forbidden in ["REQUEST", "CONSTRAINT", "OUTPUT", "You are a senior"] {
            XCTAssertFalse(output.contains(forbidden))
        }
    }

    func testSpellingPunctuationAndVocabulary() {
        let formatter = SmartFormatting()
        let store = VocabularyStore()
        store.add(phrase: "LocalFlow")
        let output = formatter.format("i recieved the LocalFlow update .how do we ship it", profile: .neutral, vocabularyStore: store)
        XCTAssertEqual(output, "I received the LocalFlow update. How do we ship it?")
    }

    @MainActor
    func testRewriteValidationProtectsTechnicalDetails() {
        let input = "Fix userID in src/app.ts using --dry-run for Missy on port 3000"
        XCTAssertTrue(LocalWritingAssistant.isAcceptable("Role:\nEngineer\n\nObjective:\n\(input)", for: input, protectedWords: ["Missy"]))
        XCTAssertFalse(LocalWritingAssistant.isAcceptable("Fix userid in src/app.ts using --dry-run for Missy on port 3000", for: input))
        XCTAssertFalse(LocalWritingAssistant.isAcceptable("Fix userID in src/app.ts using --dry-run for messy on port 3000", for: input, protectedWords: ["Missy"]))
    }

    @MainActor
    func testPromptBlueprintRendererOmitsEmptySections() {
        let blueprint = PromptBlueprintValue(
            role: "Senior Swift engineer",
            objective: "Fix the login redirect.",
            context: ["The failure occurs after refresh."],
            requirements: ["Inspect src/auth.ts", "Run existing tests"],
            constraints: ["Keep the public API unchanged."],
            expectedResult: "A verified minimal fix."
        )
        let output = LocalWritingAssistant.renderPromptBlueprint(blueprint)
        XCTAssertTrue(output.contains("Role:\nSenior Swift engineer"))
        XCTAssertTrue(output.contains("Requirements:\n- Inspect src/auth.ts\n- Run existing tests"))
        XCTAssertTrue(output.contains("Expected result:\nA verified minimal fix."))
        XCTAssertFalse(output.contains("Output:"))

        let minimal = LocalWritingAssistant.renderPromptBlueprint(.init(role: "Editor", objective: "Clarify the note.", context: [], requirements: [], constraints: [], expectedResult: ""))
        XCTAssertFalse(minimal.contains("Context:"))
        XCTAssertFalse(minimal.contains("Constraints:"))
        XCTAssertTrue(LocalWritingAssistant.isValidPromptBlueprint(blueprint, sourceLength: 120))
        XCTAssertFalse(LocalWritingAssistant.isValidPromptBlueprint(.init(role: "", objective: "Do work", context: [], requirements: [], constraints: [], expectedResult: ""), sourceLength: 20))
    }

    func testEverySmartPolishToneHasAStableInstruction() {
        XCTAssertEqual(PolishTone.natural.displayName, "Natural")
        for tone in PolishTone.allCases {
            XCTAssertTrue(tone.instruction.contains("Rewrite"))
        }
    }
}
