import AppKit
import Combine
import XCTest
import Shared
import Engines
import TextInjection
import HotkeyManager
@testable import LocalFlowApp

// MARK: - Fakes (no microphone, Accessibility, windows, or event taps)

@MainActor
private final class FakeAudio: AudioCapturing {
    var onInterrupted: (() -> Void)?
    var hasMeaningfulAudio = true
    var continuousSilenceDurationSeconds: Double = 0
    var waveformLevelsPublisher: AnyPublisher<[Float], Never> { Just([]).eraseToAnyPublisher() }
    private(set) var isRecording = false
    private(set) var startCount = 0
    private(set) var resetCount = 0

    func requestMicrophonePermission() async -> Bool { true }
    func start() throws { isRecording = true; startCount += 1 }
    func stop() -> CapturedAudio {
        isRecording = false
        return CapturedAudio(buffer: nil, samples: Array(repeating: 0.2, count: 1_600), sampleRate: 16_000)
    }
    func reset() { isRecording = false; resetCount += 1 }
}

private final class FakeInjection: TextInjecting, @unchecked Sendable {
    private let lock = NSLock()
    private var _inserted: [String] = []
    private let outcome: TextInjectionOutcome
    init(outcome: TextInjectionOutcome = .inserted) { self.outcome = outcome }
    var inserted: [String] { lock.withLock { _inserted } }

    func isAccessibilityTrusted(prompt: Bool) -> Bool { true }
    func insert(_ text: String, into targetApp: NSRunningApplication?) async throws -> TextInjectionOutcome {
        lock.withLock { _inserted.append(text) }
        return outcome
    }
    func captureCurrentSelection() async -> SelectedTextCaptureResult { .noSelection }
    func replaceCapturedSelection(_ snapshot: SelectedTextSnapshot, with polished: String) async -> SelectionReplacementResult { .failed }
    func focusedFieldText(preferredPID: pid_t?) -> (element: AXUIElement, text: String)? { nil }
}

@MainActor
private final class FakeOverlay: DictationOverlayPresenting {
    var onCancel: (() -> Void)?
    var onFinishAndPaste: (() -> Void)?
    var onUndo: (() -> Void)?
    private(set) var cancelledShown = 0
    func show(mode: DictationSessionMode, levelsPublisher: AnyPublisher<[Float], Never>) {}
    private(set) var lastCancelledAction: String?
    func showCancelled(title: String, actionTitle: String, durationSeconds: Double, onDismiss: @escaping () -> Void) {
        cancelledShown += 1
        lastCancelledAction = actionTitle
    }
    func showPolished(message: String, durationSeconds: Double) {}
    func showError(_ message: String) {}
    func showPolishing(message: String) {}
    func showProcessing() {}
    func hide() {}
}

@MainActor
private final class FakeResultCard: ResultCardPresenting {
    private(set) var shown: [String] = []
    func show(text: String, status: String, persistent: Bool) { shown.append(text) }
}

/// Returns `text` for every call; while `isHeld`, each call waits until `release()`.
private actor FakeEngine: STTEngine {
    private let text: String
    private var isHeld: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var calls = 0
    private var failuresLeft: Int

    init(text: String = "hello world", held: Bool = false, failures: Int = 0) {
        self.text = text
        self.isHeld = held
        self.failuresLeft = failures
    }

    func release() {
        isHeld = false
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func transcribe(audio: CapturedAudio) async throws -> STTResult {
        calls += 1
        if isHeld { await withCheckedContinuation { waiters.append($0) } }
        if failuresLeft > 0 {
            failuresLeft -= 1
            throw LocalFlowError.modelUnavailable("speech service unreachable")
        }
        return STTResult(text: text, confidence: 0.99)
    }
}

// MARK: - Tests

@MainActor
final class DictationCoordinatorTests: XCTestCase {
    private var audio: FakeAudio!
    private var injection: FakeInjection!
    private var overlay: FakeOverlay!
    private var resultCard: FakeResultCard!
    private var history: DictationHistoryStore!
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        audio = FakeAudio()
        overlay = FakeOverlay()
        resultCard = FakeResultCard()
        history = DictationHistoryStore(fileURL: tempDir.appendingPathComponent("history.json"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeCoordinator(
        engine: FakeEngine = FakeEngine(),
        outcome: TextInjectionOutcome = .inserted
    ) -> DictationCoordinator {
        injection = FakeInjection(outcome: outcome)
        let suite = "LocalFlowAppTests.\(UUID().uuidString)"
        let vocabulary = VocabularyStore(settings: LocalFlowSettings(defaults: UserDefaults(suiteName: suite)!))
        return DictationCoordinator(
            historyStore: history,
            vocabularyStore: vocabulary,
            audioCapture: audio,
            textInjection: injection,
            overlayController: overlay,
            resultCardController: resultCard,
            engine: engine,
            startsSystemObservers: false
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
    }

    func testPushToTalkHoldAndReleaseTranscribesAndInserts() async {
        let coordinator = makeCoordinator()
        await coordinator.handle(hotkeyEvent: .pushToTalkDown)
        XCTAssertEqual(coordinator.state, .listening)
        XCTAssertEqual(coordinator.sessionMode, .pushToTalk)
        XCTAssertTrue(audio.isRecording)

        try? await Task.sleep(nanoseconds: 400_000_000)  // longer than the 0.35 s tap threshold
        await coordinator.handle(hotkeyEvent: .pushToTalkUp)
        XCTAssertFalse(audio.isRecording)

        await waitUntil { coordinator.state == .idle && !self.injection.inserted.isEmpty }
        XCTAssertEqual(injection.inserted.count, 1)
        XCTAssertTrue(injection.inserted[0].lowercased().contains("hello world"))
        XCTAssertEqual(history.items.first?.text, injection.inserted[0])
    }

    func testQuickTapThenDoubleTapPromotesToHandsFree() async {
        let coordinator = makeCoordinator()
        await coordinator.handle(hotkeyEvent: .pushToTalkDown)
        await coordinator.handle(hotkeyEvent: .pushToTalkUp)  // quick tap: end is deferred
        await coordinator.handle(hotkeyEvent: .doubleTap)
        XCTAssertEqual(coordinator.sessionMode, .handsFree)

        // The deferred quick-tap end must not fire, and releasing the key keeps recording.
        try? await Task.sleep(nanoseconds: 500_000_000)
        await coordinator.handle(hotkeyEvent: .pushToTalkUp)
        XCTAssertEqual(coordinator.state, .listening)
        XCTAssertTrue(audio.isRecording)
        XCTAssertTrue(injection.inserted.isEmpty)

        // A single press stops hands-free and transcribes.
        await coordinator.handle(hotkeyEvent: .pushToTalkDown)
        await waitUntil { coordinator.state == .idle && self.injection.inserted.count == 1 }
        XCTAssertEqual(coordinator.sessionMode, .pushToTalk)
    }

    /// C1 regression: a cancelled transcription that finishes late must not tear down the next session.
    func testEscapeWhileProcessingThenNewSessionSurvivesStaleTranscription() async {
        let engine = FakeEngine(held: true)
        let coordinator = makeCoordinator(engine: engine)

        await coordinator.handle(hotkeyEvent: .pushToTalkDown)
        try? await Task.sleep(nanoseconds: 400_000_000)
        await coordinator.handle(hotkeyEvent: .pushToTalkUp)
        XCTAssertEqual(coordinator.state, .processing)
        await waitUntil { await engine.calls == 1 }

        await coordinator.handle(hotkeyEvent: .escape)
        XCTAssertEqual(coordinator.state, .idle)

        await coordinator.handle(hotkeyEvent: .pushToTalkDown)
        XCTAssertEqual(coordinator.state, .listening)
        let resetsBeforeStale = audio.resetCount

        await engine.release()  // stale transcription now returns
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(coordinator.state, .listening, "stale task tore down the new session")
        XCTAssertTrue(audio.isRecording)
        XCTAssertEqual(audio.resetCount, resetsBeforeStale)
        XCTAssertTrue(injection.inserted.isEmpty)
        XCTAssertTrue(history.items.isEmpty)
    }

    func testNoFocusedTargetShowsResultCardAndKeepsHistory() async {
        let coordinator = makeCoordinator(outcome: .noFocusedTarget)
        await coordinator.handle(hotkeyEvent: .pushToTalkDown)
        try? await Task.sleep(nanoseconds: 400_000_000)
        await coordinator.handle(hotkeyEvent: .pushToTalkUp)

        await waitUntil { coordinator.state == .idle && !self.resultCard.shown.isEmpty }
        XCTAssertEqual(resultCard.shown.count, 1)
        XCTAssertTrue(resultCard.shown[0].lowercased().contains("hello world"))
        XCTAssertEqual(history.items.first?.text, resultCard.shown[0])
        XCTAssertNil(coordinator.lastErrorMessage)
    }

    func testHandsFreeCancelThenUndoTranscribesCancelledAudio() async {
        let engine = FakeEngine()
        let coordinator = makeCoordinator(engine: engine)
        await coordinator.handle(hotkeyEvent: .doubleTap)  // from idle: start hands-free
        XCTAssertEqual(coordinator.sessionMode, .handsFree)
        XCTAssertEqual(coordinator.state, .listening)

        await coordinator.handle(hotkeyEvent: .escape)
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(overlay.cancelledShown, 1)
        let calls = await engine.calls
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(injection.inserted.isEmpty)

        overlay.onUndo?()  // the Undo button on the cancelled pill
        await waitUntil { self.injection.inserted.count == 1 && coordinator.state == .idle }
        XCTAssertEqual(history.items.count, 1)
    }

    func testFailedTranscriptionOffersRetryThatInsertsText() async {
        let engine = FakeEngine(failures: 1)
        let coordinator = makeCoordinator(engine: engine)
        await coordinator.handle(hotkeyEvent: .pushToTalkDown)
        try? await Task.sleep(nanoseconds: 400_000_000)
        await coordinator.handle(hotkeyEvent: .pushToTalkUp)

        await waitUntil { coordinator.state == .idle && self.overlay.lastCancelledAction == "Retry" }
        XCTAssertNotNil(coordinator.lastErrorMessage)
        XCTAssertTrue(injection.inserted.isEmpty)

        overlay.onUndo?()  // the Retry button on the pill
        await waitUntil { self.injection.inserted.count == 1 && coordinator.state == .idle }
        let calls = await engine.calls
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(history.items.count, 1)
        XCTAssertNil(coordinator.lastErrorMessage)
    }

    func testAudioInterruptionWhileListeningEndsAndTranscribes() async {
        let coordinator = makeCoordinator()
        await coordinator.handle(hotkeyEvent: .pushToTalkDown)
        XCTAssertEqual(coordinator.state, .listening)

        audio.onInterrupted?()  // mic device changed mid-recording
        await waitUntil { coordinator.state == .idle && self.injection.inserted.count == 1 }
        XCTAssertFalse(audio.isRecording)
        XCTAssertEqual(history.items.count, 1)
    }
}
