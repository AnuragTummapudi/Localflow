import XCTest
import Carbon.HIToolbox
@testable import Shared
@testable import AudioCapture
@testable import HotkeyManager
@testable import ModelManager
@testable import Engines

final class SharedTests: XCTestCase {
    func testAudioCaptureSessionResetAndSilenceState() {
        let session = AudioCaptureSession()
        XCTAssertFalse(session.isRecording)
        XCTAssertFalse(session.hasMeaningfulAudio)
        XCTAssertEqual(session.peakCapturedLevel, 0)

        // Calling reset on an idle session guarantees clean idle state
        session.reset()
        XCTAssertFalse(session.isRecording)
        XCTAssertFalse(session.hasMeaningfulAudio)
        XCTAssertEqual(session.waveformLevels.count, 32)
        XCTAssertEqual(session.waveformLevels.first, 0.12)
    }
    func testVocabularyReplacementIsCaseInsensitive() {
        let defaults = UserDefaults(suiteName: "LocalFlowTests.\(UUID().uuidString)")!
        let settings = LocalFlowSettings(defaults: defaults)
        let store = VocabularyStore(settings: settings)
        store.add(phrase: "local flow", replacement: "LocalFlow")

        XCTAssertEqual(store.apply(to: "open local flow now"), "open LocalFlow now")
    }

    func testCustomWordCasingPreservedWithoutDeletion() {
        let defaults = UserDefaults(suiteName: "LocalFlowTests.\(UUID().uuidString)")!
        let settings = LocalFlowSettings(defaults: defaults)
        let store = VocabularyStore(settings: settings)
        // Add single word without replacement
        store.add(phrase: "Anurag Tummapudi")

        let result = store.apply(to: "my name is anurag tummapudi and I code")
        XCTAssertEqual(result, "my name is Anurag Tummapudi and I code")
    }

    func testWordBoundaryPreventsSubstringCorruption() {
        let defaults = UserDefaults(suiteName: "LocalFlowTests.\(UUID().uuidString)")!
        let settings = LocalFlowSettings(defaults: defaults)
        let store = VocabularyStore(settings: settings)

        // "dinner" contains "inr", "obtuse" contains "bt"
        let input = "having dinner with 500 inr while feeling obtuse btw"
        let result = store.apply(to: input)
        // "dinner" must NOT become "dINR" or "d500", "obtuse" must NOT become "oby theuse"
        XCTAssertTrue(result.contains("having dinner with 500 INR"))
        XCTAssertTrue(result.contains("feeling obtuse by the way"))
    }

    func testShortcutCapitalizationPreservation() {
        let defaults = UserDefaults(suiteName: "LocalFlowTests.\(UUID().uuidString)")!
        let settings = LocalFlowSettings(defaults: defaults)
        let store = VocabularyStore(settings: settings)

        let result = store.apply(to: "Btw, we are launching today.")
        XCTAssertEqual(result, "By the way, we are launching today.")
    }

    func testSmartPhoneticsVariations() {
        let defaults = UserDefaults(suiteName: "LocalFlowTests.\(UUID().uuidString)")!
        let settings = LocalFlowSettings(defaults: defaults)
        let store = VocabularyStore(settings: settings)

        let input = "meeting with mccarthy and reading posh quotes about a b gen"
        let result = store.apply(to: input)
        XCTAssertEqual(result, "meeting with Mckarthy and reading Pausch quotes about ABGen")
    }

    func testEmailSpokenAddressParsing() {
        let defaults = UserDefaults(suiteName: "LocalFlowTests.\(UUID().uuidString)")!
        let settings = LocalFlowSettings(defaults: defaults)
        let store = VocabularyStore(settings: settings)

        let input = "email me at tummapudianurag at gmail dot com today"
        let result = store.apply(to: input)
        XCTAssertEqual(result, "email me at tummapudianurag@gmail.com today")
    }

    func testLengthPrioritizedMatching() {
        let defaults = UserDefaults(suiteName: "LocalFlowTests.\(UUID().uuidString)")!
        let settings = LocalFlowSettings(defaults: defaults)
        let store = VocabularyStore(settings: settings)

        // Both "Anurag" and "Anurag Tummapudi" exist
        let input = "hello anurag tummapudi and anurag"
        let result = store.apply(to: input)
        XCTAssertEqual(result, "hello Anurag Tummapudi and Anurag")
    }

    func testHistorySearchUsesSubstringMatching() {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = DictationHistoryStore(fileURL: fileURL)
        store.append(text: "This is a local transcript", bundleIdentifier: "com.example")
        store.append(text: "Another item", bundleIdentifier: nil)

        XCTAssertEqual(store.search("local").map(\.text), ["This is a local transcript"])
    }

    func testNetworkPolicyBlocksAfterModelsAreAvailable() {
        let defaults = UserDefaults(suiteName: "LocalFlowTests.\(UUID().uuidString)")!
        let settings = LocalFlowSettings(defaults: defaults)
        settings.hardBlockNetworkAfterModelsDownloaded = true
        let policy = NetworkPolicy(settings: settings, modelsAvailable: { true })

        XCTAssertFalse(policy.allowsNetworkAccess())
    }

    func testNetworkActivityCounterIncrementsOnMainThread() {
        let counter = NetworkActivityCounter()
        XCTAssertEqual(counter.requestCount, 0)
        counter.recordRequest()
        XCTAssertEqual(counter.requestCount, 1)
        counter.recordRequest()
        XCTAssertEqual(counter.requestCount, 2)
        counter.reset()
        XCTAssertEqual(counter.requestCount, 0)
    }

    func testEngineSelectionPriority() async throws {
        // Apple Speech APIs exist only on macOS 26+; older OSes should fall through cleanly.
        if appleSpeechEngineIsAvailable() {
            let isInstalled = await appleSpeechModelIsInstalled()
            // Headless CI typically has no OS speech asset pre-downloaded.
            _ = isInstalled
        } else {
            XCTAssertFalse(appleSpeechEngineIsAvailable())
        }

        do {
            _ = try await ModelManager.shared.prepareEngine()
        } catch {
            // Expected when local Parakeet/Whisper weights are not pre-downloaded.
            XCTAssertNotNil(error)
        }
    }

    func testCapturedAudioSilenceDetection() {
        // Empty audio
        let emptyAudio = CapturedAudio(buffer: nil, samples: [], sampleRate: 16000)
        XCTAssertTrue(emptyAudio.isEmpty)
        XCTAssertFalse(emptyAudio.hasMeaningfulAudio)

        // 30 seconds of quiet background room noise (mean amp ~0.0005, peak ~0.002)
        let silentSamples = (0..<480_000).map { _ in Float.random(in: -0.002...0.002) }
        let silentAudio = CapturedAudio(buffer: nil, samples: silentSamples, sampleRate: 16000)
        XCTAssertFalse(silentAudio.isEmpty)
        XCTAssertFalse(silentAudio.hasMeaningfulAudio, "30 seconds of room silence should not be classified as meaningful speech")

        // Audio with clear speech energy
        let speechSamples = (0..<480_000).map { i in
            sin(Float(i) * 0.05) * 0.25
        }
        let speechAudio = CapturedAudio(buffer: nil, samples: speechSamples, sampleRate: 16000)
        XCTAssertTrue(speechAudio.hasMeaningfulAudio, "Audible speech audio must be detected as meaningful")
    }

    func testHandsFreeContinuousSilenceMeasurement() {
        let session = AudioCaptureSession()
        XCTAssertFalse(session.isRecording)
        // When not recording, continuous silence duration must be 0
        XCTAssertEqual(session.continuousSilenceDurationSeconds, 0.0)

        // Reset clears all counters cleanly
        session.reset()
        XCTAssertEqual(session.continuousSilenceDurationSeconds, 0.0)
    }

    func testDictationSessionModeEnum() {
        XCTAssertEqual(DictationSessionMode.pushToTalk.rawValue, "pushToTalk")
        XCTAssertEqual(DictationSessionMode.handsFree.rawValue, "handsFree")

        let modes: [DictationSessionMode] = [.pushToTalk, .handsFree]
        let encoded = try? JSONEncoder().encode(modes)
        XCTAssertNotNil(encoded)
        let decoded = try? JSONDecoder().decode([DictationSessionMode].self, from: encoded!)
        XCTAssertEqual(decoded, modes)
    }

    func testHotkeyEventsAndDoubleTapBehavior() {
        let manager = HotkeyManager()
        var receivedEvents: [HotkeyEvent] = []
        let cancellable = manager.eventPublisher.sink { event in
            receivedEvents.append(event)
        }

        // Test event emission
        manager.eventPublisher.send(.pushToTalkDown)
        manager.eventPublisher.send(.pushToTalkUp)
        manager.eventPublisher.send(.doubleTap)
        manager.eventPublisher.send(.escape)

        XCTAssertEqual(receivedEvents, [.pushToTalkDown, .pushToTalkUp, .doubleTap, .escape])
        cancellable.cancel()
    }

    func testFunctionHotkeySuppressesOnlyThePhysicalFunctionKey() {
        XCTAssertTrue(
            HotkeyManager.shouldSuppressSystemFunctionAction(
                keyCode: UInt16(kVK_Function),
                functionHotkeyEnabled: true
            )
        )
        XCTAssertFalse(
            HotkeyManager.shouldSuppressSystemFunctionAction(
                keyCode: UInt16(kVK_Function),
                functionHotkeyEnabled: false
            )
        )
        XCTAssertFalse(
            HotkeyManager.shouldSuppressSystemFunctionAction(
                keyCode: UInt16(kVK_Option),
                functionHotkeyEnabled: true
            )
        )
    }
}
