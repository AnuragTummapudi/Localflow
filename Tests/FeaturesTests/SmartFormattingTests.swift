import XCTest
@testable import Shared
@testable import SmartFormatting

final class SmartFormattingTests: XCTestCase {

    func testDeveloperProfilesPreserveLiteralText() {
        let formatter = SmartFormatting()
        let text = "let userID = fetch_user(\"missy\")\n    // keep --dry-run and src/app.ts\nhttps://example.com/api"
        for profile in [SmartFormattingProfile.code, .prompt] {
            XCTAssertEqual(formatter.format(text, profile: profile), text)
            XCTAssertEqual(formatter.polish(text, profile: profile), text)
        }
    }

    func testPolishInDeveloperProfilesStillNormalizesSafeWhitespace() {
        let formatter = SmartFormatting()
        let input = "  keep userID in src/auth.ts  "
        XCTAssertEqual(formatter.polish(input, profile: .code), "keep userID in src/auth.ts")
        XCTAssertEqual(formatter.polish(input, profile: .prompt), "keep userID in src/auth.ts")
    }

    func testDeveloperDestinationDetection() {
        let suite = "LocalFlow.ProfileTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = LocalFlowSettings(defaults: defaults)
        let formatter = SmartFormatting(settings: settings)
        XCTAssertEqual(formatter.profile(for: "com.openai.codex"), .prompt)
        XCTAssertEqual(formatter.profile(for: "com.anthropic.claudefordesktop"), .prompt)
        XCTAssertEqual(formatter.profile(for: "com.microsoft.VSCode"), .code)
        XCTAssertEqual(formatter.profile(for: "com.apple.Terminal"), .code)
        XCTAssertEqual(formatter.profile(for: "com.googlecode.iterm2"), .code)
        settings.formattingProfileOverrides = ["com.openai.codex": .notes]
        XCTAssertEqual(formatter.profile(for: "com.openai.codex"), .notes)
        XCTAssertFalse(settings.promptModeEnabled)
        XCTAssertFalse(settings.localRewriteEnabled)
    }

    @MainActor
    func testRewriteValidationProtectsTechnicalDetails() {
        let input = "Fix userID in src/app.ts using --dry-run for Missy on port 3000"
        XCTAssertTrue(LocalWritingAssistant.isAcceptable("Request: \(input)", for: input, protectedWords: ["Missy"]))
        XCTAssertFalse(LocalWritingAssistant.isAcceptable("Fix userid in src/app.ts using --dry-run for Missy on port 3000", for: input))
        XCTAssertFalse(LocalWritingAssistant.isAcceptable("Fix userID in src/app.ts using --dry-run for messy on port 3000", for: input, protectedWords: ["Missy"]))
        XCTAssertFalse(LocalWritingAssistant.isAcceptable("", for: input))
    }

    @MainActor
    func testAmbiguousShortPromptIsKept() async {
        let result = await LocalWritingAssistant.rewrite("missy", purpose: .prompt)
        XCTAssertEqual(result.text, "missy")
        XCTAssertFalse(result.didRewrite)
        XCTAssertNotNil(result.notice)
    }

    func testSpellingAutocorrection() {
        let formatter = SmartFormatting()
        let result = formatter.format("i recieved the package yesterday", profile: .generic)
        XCTAssertTrue(result.contains("received"), "Expected 'recieved' to be autocorrected to 'received', got: \(result)")
        XCTAssertTrue(result.contains("I received"), "Expected 'i' to be capitalized, got: \(result)")
    }

    func testCommonTypoFallbackWorksWithoutSystemDictionarySuggestion() {
        let formatter = SmartFormatting()
        let result = formatter.polish("teh report was recieved yesterday", profile: .generic)
        XCTAssertEqual(result, "The report was received yesterday.")
    }

    func testContractionFixes() {
        let formatter = SmartFormatting()
        let result = formatter.format("we didnt know and they couldnt come", profile: .generic)
        XCTAssertTrue(result.contains("didn't"), "Expected 'didn't', got: \(result)")
        XCTAssertTrue(result.contains("couldn't"), "Expected 'couldn't', got: \(result)")
    }

    func testCustomVocabularyProtected() {
        let formatter = SmartFormatting()
        let store = VocabularyStore()
        store.add(phrase: "LocalFlow")
        store.add(phrase: "Anurag")
        store.add(phrase: "parakeet")

        let result = formatter.format("hello from Anurag using LocalFlow", profile: .generic, vocabularyStore: store)
        XCTAssertTrue(result.contains("LocalFlow"), "Custom word LocalFlow must be preserved, got: \(result)")
        XCTAssertTrue(result.contains("Anurag"), "Custom name Anurag must be preserved, got: \(result)")
    }

    func testSmartQuotesAndEmDashes() {
        let formatter = SmartFormatting()
        let result = formatter.format("he said \"hello world\" -- immediately", profile: .generic)
        XCTAssertTrue(result.contains("“hello world”"), "Expected curly double quotes, got: \(result)")
        XCTAssertTrue(result.contains("—"), "Expected em-dash, got: \(result)")
    }

    func testPunctuationSpacingHygiene() {
        let formatter = SmartFormatting()
        let result = formatter.format("hello , world .how are you", profile: .generic)
        XCTAssertFalse(result.contains(" ,"), "Should not have space before comma, got: \(result)")
        XCTAssertEqual(result, "Hello, world. How are you?")
    }

    func testQuestionMarkDetection() {
        let formatter = SmartFormatting()
        let result1 = formatter.polish("how do we deploy to production")
        XCTAssertTrue(result1.hasSuffix("?"), "Expected question mark at end of 'how do we...', got: \(result1)")

        let result2 = formatter.polish("can you review this pull request")
        XCTAssertTrue(result2.hasSuffix("?"), "Expected question mark at end of 'can you...', got: \(result2)")

        let statement = formatter.polish("we are ready to deploy to production")
        XCTAssertTrue(statement.hasSuffix("."), "Expected period for statement, got: \(statement)")
    }

    func testSentenceCapitalizationAndPronounI() {
        let formatter = SmartFormatting()
        let result = formatter.format("yesterday i saw the report. it was great! then i went home", profile: .generic)
        XCTAssertTrue(result.contains("Yesterday I saw"), "Expected capitalized start and 'I', got: \(result)")
        XCTAssertTrue(result.contains("It was great!"), "Expected capitalized sentence, got: \(result)")
        XCTAssertTrue(result.contains("Then I went"), "Expected capitalized 'Then I', got: \(result)")
    }

    func testChatProfileOmitsSingleSentenceTrailingPeriod() {
        let formatter = SmartFormatting()
        let result = formatter.format("sounds good thanks", profile: .chat)
        XCTAssertFalse(result.hasSuffix("."), "Chat profile should omit trailing period for single line: \(result)")
        XCTAssertEqual(result, "Sounds good thanks")
    }

    func testMailProfileAddsStructure() {
        let formatter = SmartFormatting()
        let result = formatter.format("thanks for the update", profile: .mail)
        XCTAssertTrue(result.hasPrefix("Hi,\n\n"))
        XCTAssertTrue(result.contains("Thanks for the update."))
        XCTAssertTrue(result.hasSuffix("\n\nBest,"))
    }

    func testNotesProfileBulletFormatting() {
        let formatter = SmartFormatting()
        let result = formatter.format("first write the code second run tests third deploy", profile: .notes)
        XCTAssertTrue(result.contains("- write the code") || result.contains("- Write the code") || result.contains("\n- "), "Expected bulleted notes format, got: \(result)")
    }

    func testWisprFlowStylePolish() {
        let formatter = SmartFormatting()
        let messy = "i recieved the email -- we didnt check it"
        let polished = formatter.polish(messy, profile: .generic)
        XCTAssertTrue(polished.contains("received"), "Expected 'received', got: \(polished)")
        XCTAssertTrue(polished.contains("didn't"), "Expected 'didn't', got: \(polished)")
        XCTAssertTrue(polished.contains("—"), "Expected em-dash, got: \(polished)")
        XCTAssertTrue(polished.hasPrefix("I received"), "Expected 'I received', got: \(polished)")
        XCTAssertTrue(polished.hasSuffix("."), "Expected sentence termination, got: \(polished)")
    }
}
