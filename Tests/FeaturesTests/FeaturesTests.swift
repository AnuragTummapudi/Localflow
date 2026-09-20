import XCTest
import AppKit
@testable import Shared
@testable import CommandMode
@testable import SmartFormatting
@testable import TextInjection

private struct MockCatalog: ApplicationCatalog {
    func installedApplications() -> [ApplicationMatch] {
        [
            ApplicationMatch(name: "Safari", bundleIdentifier: "com.apple.Safari", url: URL(fileURLWithPath: "/Applications/Safari.app"), confidence: 1),
            ApplicationMatch(name: "Xcode", bundleIdentifier: "com.apple.dt.Xcode", url: URL(fileURLWithPath: "/Applications/Xcode.app"), confidence: 1)
        ]
    }
}

final class FeaturesTests: XCTestCase {
    func testHighConfidenceCommandExecutes() {
        let commandMode = CommandMode(catalog: MockCatalog())

        guard case .execute(.openApplication(let match)) = commandMode.resolve("open Safari") else {
            return XCTFail("Expected high-confidence open command")
        }
        XCTAssertEqual(match.name, "Safari")
    }

    func testLowConfidenceCommandRequiresConfirmation() {
        let commandMode = CommandMode(catalog: MockCatalog(), highConfidenceThreshold: 0.99)

        guard case .needsConfirmation(.openApplication(let match)) = commandMode.resolve("open safar") else {
            return XCTFail("Expected low-confidence confirmation")
        }
        XCTAssertEqual(match.name, "Safari")
    }

    func testLowTranscriptionConfidenceRequiresConfirmation() {
        let commandMode = CommandMode(catalog: MockCatalog())

        guard case .needsConfirmation(.openApplication(let match)) = commandMode.resolve("open Safari", transcriptionConfidence: 0.4) else {
            return XCTFail("Expected low ASR confidence to require confirmation")
        }
        XCTAssertEqual(match.name, "Safari")
    }

    func testOpenURLWithoutScheme() {
        let commandMode = CommandMode(catalog: MockCatalog())

        guard case .execute(.openURL(let url)) = commandMode.resolve("open youtube.com") else {
            return XCTFail("Expected open youtube.com to resolve to openURL")
        }
        XCTAssertEqual(url.absoluteString, "https://youtube.com")
    }

    func testOpenURLWithSpokenDotAndSpaces() {
        let commandMode = CommandMode(catalog: MockCatalog())

        guard case .execute(.openURL(let url1)) = commandMode.resolve("open youtube dot com") else {
            return XCTFail("Expected 'open youtube dot com' to resolve to openURL")
        }
        XCTAssertEqual(url1.absoluteString, "https://youtube.com")

        guard case .execute(.openURL(let url2)) = commandMode.resolve("open youtube . com.") else {
            return XCTFail("Expected 'open youtube . com.' to resolve to openURL")
        }
        XCTAssertEqual(url2.absoluteString, "https://youtube.com")
    }

    func testOpenURLWithSchemeAndPath() {
        let commandMode = CommandMode(catalog: MockCatalog())

        guard case .execute(.openURL(let url)) = commandMode.resolve("open https://github.com/facebook/react") else {
            return XCTFail("Expected https URL with path to resolve to openURL")
        }
        XCTAssertEqual(url.absoluteString, "https://github.com/facebook/react")
    }

    func testOpenURLLocalhost() {
        let commandMode = CommandMode(catalog: MockCatalog())

        guard case .execute(.openURL(let url)) = commandMode.resolve("open localhost:3000") else {
            return XCTFail("Expected localhost to resolve to openURL")
        }
        XCTAssertEqual(url.absoluteString, "http://localhost:3000")
    }

    func testGoToURLCommand() {
        let commandMode = CommandMode(catalog: MockCatalog())

        guard case .execute(.openURL(let url)) = commandMode.resolve("go to google.com") else {
            return XCTFail("Expected 'go to google.com' to resolve to openURL")
        }
        XCTAssertEqual(url.absoluteString, "https://google.com")
    }

    func testOpenAppNotConfusedWithURL() {
        let commandMode = CommandMode(catalog: MockCatalog())

        guard case .execute(.openApplication(let match)) = commandMode.resolve("open Safari") else {
            return XCTFail("Expected 'open Safari' to resolve to openApplication, not openURL")
        }
        XCTAssertEqual(match.name, "Safari")
    }

    func testOpenInYouTubeCommand() {
        let commandMode = CommandMode(catalog: MockCatalog())

        guard case .execute(.searchWeb(let query, let provider, let url)) = commandMode.resolve("open firebasechannel in youtube.com") else {
            return XCTFail("Expected 'open firebasechannel in youtube.com' to resolve to searchWeb")
        }
        XCTAssertEqual(query, "firebasechannel")
        XCTAssertEqual(provider, "YouTube")
        XCTAssertEqual(url.absoluteString, "https://www.youtube.com/results?search_query=firebasechannel")
    }

    func testOpenOnYouTubeAliasAndPunctuation() {
        let commandMode = CommandMode(catalog: MockCatalog())

        guard case .execute(.searchWeb(let query, let provider, let url)) = commandMode.resolve("open swift concurrency on youtube.") else {
            return XCTFail("Expected 'open swift concurrency on youtube.' to resolve to searchWeb")
        }
        XCTAssertEqual(query, "swift concurrency")
        XCTAssertEqual(provider, "YouTube")
        XCTAssertEqual(url.absoluteString, "https://www.youtube.com/results?search_query=swift%20concurrency")
    }

    func testOpenWithSpokenDotCom() {
        let commandMode = CommandMode(catalog: MockCatalog())

        guard case .execute(.searchWeb(let query, let provider, let url)) = commandMode.resolve("open lofi beats in youtube dot com") else {
            return XCTFail("Expected 'open lofi beats in youtube dot com' to resolve to searchWeb")
        }
        XCTAssertEqual(query, "lofi beats")
        XCTAssertEqual(provider, "YouTube")
        XCTAssertEqual(url.absoluteString, "https://www.youtube.com/results?search_query=lofi%20beats")
    }

    func testSearchCommandWithNestedPrepositions() {
        let commandMode = CommandMode(catalog: MockCatalog())

        guard case .execute(.searchWeb(let query, let provider, let url)) = commandMode.resolve("open how to center a div in css on google") else {
            return XCTFail("Expected nested prepositions to resolve correctly")
        }
        XCTAssertEqual(query, "how to center a div in css")
        XCTAssertEqual(provider, "Google")
        XCTAssertEqual(url.absoluteString, "https://www.google.com/search?q=how%20to%20center%20a%20div%20in%20css")
    }

    func testSearchOnGitHub() {
        let commandMode = CommandMode(catalog: MockCatalog())

        guard case .execute(.searchWeb(let query, let provider, let url)) = commandMode.resolve("search localflow on github.com") else {
            return XCTFail("Expected 'search localflow on github.com' to resolve to searchWeb")
        }
        XCTAssertEqual(query, "localflow")
        XCTAssertEqual(provider, "GitHub")
        XCTAssertEqual(url.absoluteString, "https://github.com/search?q=localflow")
    }

    func testGenericSearchFallbackToGoogle() {
        let commandMode = CommandMode(catalog: MockCatalog())

        guard case .execute(.searchWeb(let query, let provider, let url)) = commandMode.resolve("search for rust async") else {
            return XCTFail("Expected 'search for rust async' to fallback to default Google search")
        }
        XCTAssertEqual(query, "rust async")
        XCTAssertEqual(provider, "Google")
        XCTAssertEqual(url.absoluteString, "https://www.google.com/search?q=rust%20async")
    }

    func testCustomDomainSiteSearchFallback() {
        let commandMode = CommandMode(catalog: MockCatalog())

        guard case .execute(.searchWeb(let query, let provider, let url)) = commandMode.resolve("open pricing in stripe.com") else {
            return XCTFail("Expected 'open pricing in stripe.com' to resolve to site search")
        }
        XCTAssertEqual(query, "pricing")
        XCTAssertEqual(provider, "stripe.com")
        XCTAssertTrue(url.absoluteString.contains("site:stripe.com"))
        XCTAssertTrue(url.absoluteString.contains("pricing"))
    }

    func testSearchExecutesDirectlyWithoutConfirmationModal() {
        let commandMode = CommandMode(catalog: MockCatalog(), highConfidenceThreshold: 0.85)

        // Even with low transcription confidence, search commands execute directly without irritating confirmation modals
        guard case .execute(.searchWeb(let query, let provider, _)) = commandMode.resolve("Open Vake Vake song on youtube.com", transcriptionConfidence: 0.5) else {
            return XCTFail("Expected search to execute directly without confirmation dialog")
        }
        XCTAssertEqual(query, "Vake Vake song")
        XCTAssertEqual(provider, "YouTube")
    }

    func testOpenInSpotifyDeepLinkOrWeb() {
        let commandMode = CommandMode(catalog: MockCatalog())

        guard case .execute(.searchWeb(let query, let provider, let url)) = commandMode.resolve("open Bohemian Rhapsody in spotify") else {
            return XCTFail("Expected 'open Bohemian Rhapsody in spotify' to resolve to searchWeb")
        }
        XCTAssertEqual(query, "Bohemian Rhapsody")
        XCTAssertEqual(provider, "Spotify")
        // Resolves to native spotify:search: URI if Spotify desktop app is present, or web fallback
        let isSpotifyAppOrWeb = url.absoluteString.hasPrefix("spotify:search:") || url.absoluteString.hasPrefix("https://open.spotify.com/search/")
        XCTAssertTrue(isSpotifyAppOrWeb, "Expected spotify deep link or web search URL, got \(url.absoluteString)")
    }

    func testPlaySongOnSpotifySearchesThenAttemptsTopResultPlayback() {
        let commandMode = CommandMode(catalog: MockCatalog())

        guard case .execute(.spotifySearchAndPlay(let query, let url)) = commandMode.resolve("play Midnight City by M83 on Spotify") else {
            return XCTFail("Expected a Spotify search-and-play request")
        }

        XCTAssertEqual(query, "Midnight City by M83")
        XCTAssertTrue(
            url.absoluteString.hasPrefix("spotify:search:") || url.absoluteString.hasPrefix("https://open.spotify.com/search/"),
            "Expected Spotify deep link or web search URL, got \(url.absoluteString)"
        )
    }

    func testSpotifyPlaybackCommandsResolveLocally() {
        let commandMode = CommandMode(catalog: MockCatalog())

        XCTAssertEqual(commandMode.resolve("resume Spotify"), .execute(.spotifyControl(.resume)))
        XCTAssertEqual(commandMode.resolve("resume Spotify."), .execute(.spotifyControl(.resume)))
        XCTAssertEqual(commandMode.resolve("pause Spotify"), .execute(.spotifyControl(.pause)))
        XCTAssertEqual(commandMode.resolve("pause Spotify!"), .execute(.spotifyControl(.pause)))
        XCTAssertEqual(commandMode.resolve("next Spotify track"), .execute(.spotifyControl(.next)))
        XCTAssertEqual(commandMode.resolve("next Spotify track."), .execute(.spotifyControl(.next)))
        XCTAssertEqual(commandMode.resolve("previous Spotify track"), .execute(.spotifyControl(.previous)))
    }

    func testMailFormattingAddsStructure() {
        let formatter = SmartFormatting()
        let output = formatter.format("thanks for the update", profile: .mail)

        XCTAssertTrue(output.hasPrefix("Hi,\n\n"))
        XCTAssertTrue(output.contains("Thanks for the update."))
        XCTAssertTrue(output.hasSuffix("\n\nBest,"))
    }

    // MARK: - TextInjection caret / selection splice

    /// Before: "Hello world" with caret between "Hello " and "world"
    /// Insert: "beautiful "
    /// After:  "Hello beautiful world"
    func testCaretInsertPreservesSurroundingText() {
        let before = "Hello world"
        // UTF-16 index of the space after "Hello" is 6 → caret before "world"
        let caret = 6
        let insertion = "beautiful "

        guard let result = TextInjection.splicing(
            current: before,
            utf16Location: caret,
            utf16Length: 0,
            insertion: insertion
        ) else {
            return XCTFail("Expected valid splice")
        }

        XCTAssertEqual(before, "Hello world")
        XCTAssertEqual(result.value, "Hello beautiful world")
        XCTAssertEqual(result.caretUTF16Location, caret + (insertion as NSString).length)
    }

    /// Before: "The quick brown fox" with "quick" selected
    /// Insert: "slow"
    /// After:  "The slow brown fox"
    func testSelectionReplacePreservesSurroundingText() {
        let before = "The quick brown fox"
        let selectionStart = ("The " as NSString).length // 4
        let selectionLength = ("quick" as NSString).length // 5
        let insertion = "slow"

        guard let result = TextInjection.splicing(
            current: before,
            utf16Location: selectionStart,
            utf16Length: selectionLength,
            insertion: insertion
        ) else {
            return XCTFail("Expected valid splice")
        }

        XCTAssertEqual(before, "The quick brown fox")
        XCTAssertEqual(result.value, "The slow brown fox")
        XCTAssertNotEqual(result.value, insertion, "Must not replace the entire field with just the insertion")
    }

    /// Old buggy behavior would have produced only the insertion string.
    func testDoesNotOverwriteEntireField() {
        let before = "existing content here"
        let insertion = "dictated"

        guard let result = TextInjection.splicing(
            current: before,
            utf16Location: ("existing " as NSString).length,
            utf16Length: 0,
            insertion: insertion
        ) else {
            return XCTFail("Expected valid splice")
        }

        XCTAssertEqual(result.value, "existing dictatedcontent here")
        XCTAssertTrue(result.value.hasPrefix("existing "))
        XCTAssertTrue(result.value.hasSuffix("content here"))
        XCTAssertNotEqual(result.value, insertion)
    }

    func testInvalidRangeReturnsNil() {
        XCTAssertNil(
            TextInjection.splicing(
                current: "abc",
                utf16Location: 10,
                utf16Length: 0,
                insertion: "x"
            )
        )
    }

    /// In-process NSTextView: apply the same splice LocalFlow uses and confirm caret insert.
    @MainActor
    func testNSTextViewCaretInsertBeforeAfter() {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 80))
        textView.string = "Hello world"
        let caret = 6
        textView.setSelectedRange(NSRange(location: caret, length: 0))

        let before = textView.string
        let insertion = "beautiful "
        guard let spliced = TextInjection.splicing(
            current: before,
            utf16Location: textView.selectedRange().location,
            utf16Length: textView.selectedRange().length,
            insertion: insertion
        ) else {
            return XCTFail("Expected splice")
        }

        // This is what insertBySplicingValue writes back through AX.
        textView.string = spliced.value
        textView.setSelectedRange(NSRange(location: spliced.caretUTF16Location, length: 0))

        let after = textView.string
        let oldBugOverwrite = insertion

        XCTAssertEqual(before, "Hello world")
        XCTAssertEqual(after, "Hello beautiful world")
        XCTAssertNotEqual(after, oldBugOverwrite, "Old kAXValue overwrite would leave only \"\(oldBugOverwrite)\"")
        XCTAssertEqual(textView.selectedRange().location, ("Hello beautiful " as NSString).length)
    }

    func testTextInjectionOutcomeDistinct() {
        let success = TextInjectionOutcome.inserted
        let fallback = TextInjectionOutcome.noFocusedTarget
        XCTAssertNotEqual(success, fallback)
        XCTAssertEqual(success, .inserted)
        XCTAssertEqual(fallback, .noFocusedTarget)
    }
}
