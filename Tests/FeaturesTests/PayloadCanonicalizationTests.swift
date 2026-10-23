import XCTest
import Shared
@testable import CommandMode

@MainActor final class PayloadCanonicalizationTests: LocalSettingsTestCase {
    func testUnconfiguredPayloadsRemainByteExact() {
        let commands = CommandMode()
        for source in ["Create reminder Review local flow benchmark.", "Create note Swift Actors: Call José; write EXACT.", "Copy to clipboard examblow.com"] {
            guard case .execute(let command) = commands.resolve(source), let raw = NativeCommandParser.parse(source) else { return XCTFail("Expected supported grammar") }
            XCTAssertEqual(command.agentAction.arguments, raw.arguments)
        }
        XCTAssertEqual(PayloadCanonicalizer.apply("examblow.com Swift Actors", mappings: [:]), "examblow.com Swift Actors")
    }
    func testOnlyExplicitTermsChangeParsedPayloadAndCannotBecomeActions() {
        var memory = AgentMemory(); memory.payloadVocabulary = ["local flow": "LocalFlow", "open sesame": "open Safari and quit Notes"]
        let commands = CommandMode(memory: memory)
        guard case .execute(let command) = commands.resolve("create reminder Review local flow; open sesame") else { return XCTFail("Expected reminder") }
        XCTAssertEqual(command.agentAction.toolID, .createReminder)
        XCTAssertEqual(command.agentAction.arguments, .reminder(title: "Review LocalFlow; open Safari and quit Notes"))
        XCTAssertEqual(PayloadCanonicalizer.apply("Local flowing; LOCAL FLOW; local flow", mappings: memory.payloadVocabulary!), "Local flowing; LocalFlow; LocalFlow")
        XCTAssertEqual(PayloadCanonicalizer.apply("one", mappings: ["one": "two", "two": "three"]), "two")
    }
    func testURLMappingRequiresWholeExplicitLiteralAndPreservesOtherDomains() {
        var memory = AgentMemory(); memory.payloadVocabulary = ["examblow.com": "example.com"]
        let commands = CommandMode(memory: memory)
        XCTAssertEqual(commands.resolve("open examblow.com"), .execute(.openURL(URL(string: "https://example.com")!)))
        XCTAssertEqual(commands.resolve("open other-examblow.com"), .execute(.openURL(URL(string: "https://other-examblow.com")!)))
        XCTAssertEqual(CommandMode().resolve("open examblow.com"), .execute(.openURL(URL(string: "https://examblow.com")!)))
    }
    func testSearchMappingPreservesProviderAndQuerySpecialCharacters() {
        var memory = AgentMemory(); memory.payloadVocabulary = ["local flow": "LocalFlow & C++"]
        guard case .execute(.searchWeb(let query, let provider, let url)) = CommandMode(memory: memory).resolve("search for local flow actors") else { return XCTFail("Expected search") }
        XCTAssertEqual(query, "LocalFlow & C++ actors"); XCTAssertEqual(provider, "Google")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, query)
    }
    func testLegacyMemoryDecodesAndInvalidMappingsFailClosed() throws {
        let legacy = AgentMemory(); let bytes = try JSONEncoder().encode(legacy)
        XCTAssertNil(try JSONDecoder().decode(AgentMemory.self, from: bytes).payloadVocabulary)
        var invalid = legacy; invalid.payloadVocabulary = ["x": "one", "X": "two"]
        XCTAssertThrowsError(try invalid.validate())
    }
    func testAppSimilarityAndDuplicateNamesNeverBecomeGuessedAutomaticActions() {
        struct Catalog: ApplicationCatalog {
            let apps: [ApplicationMatch]
            func installedApplications() -> [ApplicationMatch] { apps }
        }
        let notes = ApplicationMatch(name: "Notes", bundleIdentifier: "notes", url: nil, confidence: 1)
        let commands = CommandMode(catalog: Catalog(apps: [notes]))
        for text in ["open Note", "open Notess"] {
            guard case .needsConfirmation = commands.resolve(text) else { return XCTFail("Uncertain identity must require confirmation: \(text)") }
        }
        XCTAssertEqual(commands.resolve("open Notes"), .execute(.openApplication(notes)))
        let duplicate = CommandMode(catalog: Catalog(apps: [notes, ApplicationMatch(name: "Notes", bundleIdentifier: "other.notes", url: nil, confidence: 1)]))
        guard case .needsConfirmation = duplicate.resolve("open Notes") else { return XCTFail("Duplicate installed identity cannot execute automatically") }
    }
    func testConfiguredQueriesRetainExactUnknownSiteAndSpotifyProvider() {
        var memory = AgentMemory(); memory.payloadVocabulary = ["local flow": "LocalFlow & C++"]
        let commands = CommandMode(memory: memory)
        guard case .execute(.searchWeb(let query, let provider, let url)) = commands.resolve("search local flow on example.com") else { return XCTFail("Expected existing site search") }
        XCTAssertEqual(query, "LocalFlow & C++"); XCTAssertEqual(provider, "example.com")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "site:example.com LocalFlow & C++")
        guard case .execute(.searchWeb(let song, let destination, _)) = commands.resolve("play local flow on Spotify") else { return XCTFail("Expected existing Spotify search") }
        XCTAssertEqual(song, "LocalFlow & C++"); XCTAssertEqual(destination, "Spotify")
    }
}
