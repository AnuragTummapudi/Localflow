import AppKit
import Combine
import Foundation
import OSLog
import Shared
import AudioCapture
import HotkeyManager
import ModelManager
import TextInjection
import Engines
import CommandMode
import SpeechCleanup
import SmartFormatting

/// Coordinates hotkey capture, speech recognition, commands, formatting, and text insertion.
@MainActor
public final class DictationCoordinator: ObservableObject {
    private static let polishLog = Logger(subsystem: "dev.localflow.LocalFlow", category: "SmartPolish")
    private static let promptLog = Logger(subsystem: "dev.localflow.LocalFlow", category: "PromptEngineer")
    /// The current activity state.
    @Published public private(set) var state: LocalFlowActivityState = .idle {
        didSet {
            NotificationCenter.default.post(name: .localFlowActivityStateDidChange, object: state)
        }
    }

    /// The pending command that requires user confirmation.
    @Published public var pendingCommand: CommandIntent?

    /// The display name of the engine currently handling transcription.
    @Published public private(set) var activeEngineName: String = "Not loaded"

    /// Last user-visible error message (cleared on next successful start).
    @Published public private(set) var lastErrorMessage: String?

    /// Whether a speech engine is ready to transcribe.
    public var isEngineReady: Bool { activeEngineName != "Not loaded" }

    @Published public private(set) var isPreparingEngine = false
    public var canConfigureEngine: Bool { !isPreparingEngine && state != .listening && state != .processing && !isRewritingSelection }

    /// The audio capture service.
    let audioCapture: any AudioCapturing

    /// Local dictation history (shared with Settings).
    public let historyStore: DictationHistoryStore

    /// Local custom vocabulary (shared with Settings).
    public let vocabularyStore: VocabularyStore

    private let settings = LocalFlowSettings.shared
    private let hotkeyManager = HotkeyManager()
    private let modelManager = ModelManager.shared
    private let textInjection: any TextInjecting
    private let commandMode = CommandMode()
    private let speechCleanup = SpeechCleanup()
    private let formatter = SmartFormatting()
    private var isRewritingSelection = false
    private let overlayController: any DictationOverlayPresenting
    private let resultCardController: any ResultCardPresenting
    private var cancellables = Set<AnyCancellable>()
    private var router: TranscriptionRouter
    private var dictationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var handsFreeSilenceTask: Task<Void, Never>?
    private var pendingKeyReleaseTask: Task<Void, Never>?
    private var sessionStartTime: Date?
    private var correctionWatchTask: Task<Void, Never>?
    /// Audio from a cancelled hands-free session or a failed transcription, kept only while Undo/Retry is shown.
    private var cancelledAudio: (audio: CapturedAudio, hadSpeech: Bool)?

    /// The active session mode (push-to-talk vs. locked hands-free).
    @Published public private(set) var sessionMode: DictationSessionMode = .pushToTalk

    /// App that was frontmost when the user started holding the hotkey (never LocalFlow itself).
    private var targetApplication: NSRunningApplication?
    /// Continuously tracks the last non-LocalFlow frontmost app (survives Settings being key).
    private var lastExternalApplication: NSRunningApplication?
    private var workspaceObserver: (any NSObjectProtocol)?

    /// Creates a dictation coordinator and starts observing the hotkey.
    /// The extra parameters are a test seam; the app uses the defaults.
    init(
        historyStore: DictationHistoryStore = DictationHistoryStore(),
        vocabularyStore: VocabularyStore = VocabularyStore(),
        audioCapture: any AudioCapturing = AudioCaptureSession(),
        textInjection: any TextInjecting = TextInjection(),
        overlayController: (any DictationOverlayPresenting)? = nil,
        resultCardController: (any ResultCardPresenting)? = nil,
        engine: (any STTEngine)? = nil,
        startsSystemObservers: Bool = true
    ) {
        self.historyStore = historyStore
        self.vocabularyStore = vocabularyStore
        self.audioCapture = audioCapture
        self.textInjection = textInjection
        // Built here, not as default arguments: those are evaluated off the main actor.
        self.overlayController = overlayController ?? OverlayWindowController()
        self.resultCardController = resultCardController ?? FloatingResultCardController()
        self.router = TranscriptionRouter(engine: engine ?? UnavailableEngine(message: "Model not loaded"))
        if engine != nil { activeEngineName = "Injected engine" }
        if startsSystemObservers { hotkeyManager.start() }
        hotkeyManager.eventPublisher
            .sink { [weak self] event in
                Task { @MainActor in
                    await self?.handle(hotkeyEvent: event)
                }
            }
            .store(in: &cancellables)

        self.overlayController.onCancel = { [weak self] in
            Task { @MainActor in
                self?.cancelHandsFreeSession()
            }
        }
        self.overlayController.onFinishAndPaste = { [weak self] in
            Task { @MainActor in
                await self?.endDictation()
            }
        }
        self.audioCapture.onInterrupted = { [weak self] in
            Task { @MainActor in
                // Mic changed mid-recording: transcribe what we have instead of "listening" to a dead engine.
                guard let self, self.state == .listening else { return }
                await self.endDictation()
            }
        }
        self.overlayController.onUndo = { [weak self] in
            Task { @MainActor in
                self?.undoCancellation()
            }
        }

        guard startsSystemObservers else { return }
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastExternalApplication = front
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier
            else { return }
            Task { @MainActor in
                guard let self else { return }
                // App changes are navigation, never a reason to stop a recording.  In
                // particular, hands-free capture stays locked until the user presses the
                // shortcut again, taps Finish, or uses an explicit cancellation path.
                self.lastExternalApplication = app
            }
        }
    }

    deinit {
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
    }

    /// Requests microphone permission.
    public func requestMicrophonePermission() async -> Bool {
        await audioCapture.requestMicrophonePermission()
    }

    /// Requests Accessibility trust.
    public func requestAccessibilityPermission() -> Bool {
        textInjection.isAccessibilityTrusted(prompt: true)
    }

    /// Prepares speech models for first use.
    public func prepareModels() async {
        do {
            try await prepareModelsWithError()
        } catch {
            state = .error
            lastErrorMessage = error.localizedDescription
        }
    }

    /// Loads an engine on cold start when a local model (or Apple Speech asset) is already present.
    public func prepareModelsIfAvailable() async {
        let appleReady: Bool
        if appleSpeechEngineIsAvailable() {
            appleReady = await appleSpeechModelIsInstalled()
        } else {
            appleReady = false
        }
        guard settings.dictationSource == .cloud || modelManager.modelsAvailable() || appleReady else { return }
        await prepareModels()
    }

    /// Prepares speech models and throws on failure, enabling callers to surface errors.
    public func prepareModelsWithError() async throws {
        guard canConfigureEngine else {
            throw LocalFlowError.modelUnavailable("Finish the current dictation or rewrite before changing engines.")
        }
        isPreparingEngine = true
        defer { isPreparingEngine = false }
        // Keep the current engine running until the new one is ready, so a failed switch never leaves dictation dead.
        let engine = try await modelManager.prepareEngine()
        let name = modelManager.selectedEngine.kind == .cloud
            ? "\(modelManager.selectedEngine.detail) (cloud)" : modelManager.selectedEngine.kind.displayName
        let detail = modelManager.selectedEngine.detail
        await router.updateEngine(engine, name: name)
        activeEngineName = name
        NotificationCenter.default.post(
            name: .localFlowEngineDidChange,
            object: detail.isEmpty ? name : "\(name) — \(detail)"
        )
        state = .idle
        lastErrorMessage = nil
    }

    /// Executes a command after explicit user confirmation.
    public func confirmPendingCommand() {
        guard let pendingCommand else { return }
        commandMode.execute(pendingCommand)
        self.pendingCommand = nil
    }

    /// Cancels the pending command confirmation.
    public func cancelPendingCommand() {
        pendingCommand = nil
    }

    /// Unified session teardown: guarantees audio engine, overlay, tasks, flags,
    /// and state all return to a clean idle state through one single path.
    public func teardownSession(
        errorMessage: String? = nil,
        clearErrorMessage: Bool = false,
        cancelDictationTask: Bool = true
    ) {
        timeoutTask?.cancel()
        timeoutTask = nil

        if cancelDictationTask { dictationTask?.cancel() }
        dictationTask = nil

        handsFreeSilenceTask?.cancel()
        handsFreeSilenceTask = nil

        pendingKeyReleaseTask?.cancel()
        pendingKeyReleaseTask = nil

        sessionStartTime = nil
        sessionMode = .pushToTalk
        cancelledAudio = nil

        audioCapture.reset()
        overlayController.hide()

        targetApplication = nil

        if let errorMessage {
            lastErrorMessage = errorMessage
        } else if clearErrorMessage {
            lastErrorMessage = nil
        }

        state = .idle
    }

    /// Cancels hands-free mode and presents the "Transcript cancelled" state with an Undo window.
    public func cancelHandsFreeSession() {
        guard state == .listening || state == .processing else { return }

        timeoutTask?.cancel()
        timeoutTask = nil
        handsFreeSilenceTask?.cancel()
        handsFreeSilenceTask = nil
        pendingKeyReleaseTask?.cancel()
        pendingKeyReleaseTask = nil
        dictationTask?.cancel()
        dictationTask = nil

        let audio = audioCapture.stop()
        cancelledAudio = (audio, audioCapture.hasMeaningfulAudio)
        state = .idle

        // Present the "Transcript cancelled" undo state with 3.5s countdown
        overlayController.showCancelled(title: "Transcript cancelled", actionTitle: "Undo", durationSeconds: 3.5) { [weak self] in
            self?.teardownSession(errorMessage: nil, clearErrorMessage: true)
        }
    }

    /// "Undo" / "Retry" transcribes the held recording and inserts it as if the user had tapped Finish.
    public func undoCancellation() {
        guard state == .idle, let cancelled = cancelledAudio else { return }
        cancelledAudio = nil
        transcribe(cancelled.audio, capturedSpeech: cancelled.hadSpeech)
    }

    /// Handles incoming hotkey events (push-to-talk holds, double-taps, Escape cancellation).
    public func handle(hotkeyEvent: HotkeyEvent) async {
        switch hotkeyEvent {
        case .doubleTap:
            pendingKeyReleaseTask?.cancel()
            pendingKeyReleaseTask = nil

            if state == .listening && sessionMode == .handsFree {
                // Tapping while active stops hands-free and transcribes
                await endDictation()
            } else if state == .listening && sessionMode == .pushToTalk {
                // Double tap arrived while push-to-talk was initiated: promote to hands-free!
                sessionMode = .handsFree
                setupHandsFreeTimers()
                overlayController.show(mode: .handsFree, levelsPublisher: audioCapture.waveformLevelsPublisher)
            } else if state == .idle {
                await beginDictation(mode: .handsFree)
            }

        case .pushToTalkDown:
            if state == .listening && sessionMode == .handsFree {
                // "A single press/tap of the same hotkey while a hands-free session is active STOPS it
                // and proceeds to transcription/injection, exactly like releasing in push-to-talk mode."
                await endDictation()
            } else if state == .idle {
                await beginDictation(mode: .pushToTalk)
            }

        case .pushToTalkUp:
            if sessionMode == .handsFree {
                // Hands-free recording remains locked; releasing key does not stop recording.
                return
            }
            guard state == .listening else { return }

            let holdDuration = sessionStartTime.map { Date().timeIntervalSince($0) } ?? 1.0
            if holdDuration >= 0.35 {
                // Standard push-to-talk hold: instantaneous end on release
                await endDictation()
            } else {
                // Quick tap: allow small window for potential second tap before committing end
                pendingKeyReleaseTask?.cancel()
                pendingKeyReleaseTask = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: 350_000_000)
                        guard !Task.isCancelled else { return }
                        if self?.sessionMode == .pushToTalk && self?.state == .listening {
                            await self?.endDictation()
                        }
                    } catch {}
                }
            }

        case .escape:
            // "Escape key cancels an active hands-free session outright (discards the recording, no transcription attempt)"
            if sessionMode == .handsFree && (state == .listening || state == .processing) {
                cancelHandsFreeSession()
            } else if state == .listening || state == .processing {
                teardownSession(errorMessage: nil, clearErrorMessage: true)
            }

        case .polishShortcut:
            // Cancel any in-flight dictation triggered accidentally by Option keydown
            if state == .listening {
                teardownSession(errorMessage: nil, clearErrorMessage: true)
            }
            await polishActiveSelectionOrRecentDictation()

        case .promptEngineerShortcut:
            if state == .listening {
                teardownSession(errorMessage: nil, clearErrorMessage: true)
            }
            await buildPromptFromActiveSelection()
        }
    }

    /// Option + 2 Prompt Engineer. Like Smart Polish, this is selection-only and uses
    /// the same capture, revalidation, and safe replacement transaction.
    public func buildPromptFromActiveSelection() async {
        let requestID = UUID()
        Self.promptLog.debug("request \(requestID.uuidString, privacy: .public) shortcut received")
        guard !isRewritingSelection, state != .processing else {
            Self.promptLog.notice("request \(requestID.uuidString, privacy: .public) duplicate suppressed")
            overlayController.showError("Another rewrite is already in progress.")
            return
        }
        isRewritingSelection = true
        defer { isRewritingSelection = false }
        overlayController.showPolishing(message: "Reading selection…")
        let capture = await textInjection.captureCurrentSelection()
        let selection: SelectedTextSnapshot
        switch capture {
        case .captured(let snapshot):
            selection = snapshot
            Self.promptLog.debug("request \(requestID.uuidString, privacy: .public) capture \(snapshot.method.rawValue, privacy: .public), length \(snapshot.text.count, privacy: .public), target \(snapshot.bundleIdentifier ?? "unknown", privacy: .public)")
        case .permissionDenied:
            overlayController.showError("Allow Accessibility to read selected text.")
            return
        case .noSelection:
            overlayController.showError("Select text first")
            return
        case .secureInput, .unsupported, .failed:
            overlayController.showError("Select editable text in an app, then press ⌥2.")
            return
        }

        do {
            overlayController.showPolishing(message: "Building prompt…")
            let started = ContinuousClock.now
            let prompt = try await LocalWritingAssistant.buildPrompt(
                selection.text,
                protectedWords: vocabularyStore.entries.flatMap { [$0.phrase, $0.replacement] }
            )
            Self.promptLog.debug("request \(requestID.uuidString, privacy: .public) generation completed in \(String(describing: ContinuousClock.now - started), privacy: .public), output length \(prompt.count, privacy: .public)")
            guard !Task.isCancelled else { return }
            overlayController.showPolishing(message: "Replacing text…")
            let outcome = await textInjection.replaceCapturedSelection(selection, with: prompt)
            switch outcome {
            case .verified:
                Self.promptLog.debug("request \(requestID.uuidString, privacy: .public) replacement verified")
                historyStore.append(text: prompt, bundleIdentifier: selection.bundleIdentifier)
                overlayController.showPolished(message: "Prompt ready ✓")
            case .sentUnverified:
                Self.promptLog.notice("request \(requestID.uuidString, privacy: .public) replacement sent unverified")
                historyStore.append(text: prompt, bundleIdentifier: selection.bundleIdentifier)
                overlayController.showPolished(message: "Prompt sent to the selected app.")
            case .selectionChanged, .targetChanged:
                Self.promptLog.notice("request \(requestID.uuidString, privacy: .public) selection changed")
                resultCardController.show(text: prompt, status: "Selection changed", persistent: true)
            case .unsupported, .failed:
                Self.promptLog.error("request \(requestID.uuidString, privacy: .public) replacement failed")
                resultCardController.show(text: prompt, status: "Prompt ready, but replacement failed. Copy it here.", persistent: true)
            }
        } catch let error as LocalWritingAssistant.PromptEngineerError {
            Self.promptLog.error("request \(requestID.uuidString, privacy: .public) failed category \(String(describing: error), privacy: .public)")
            overlayController.showError(error.localizedDescription)
        } catch {
            overlayController.showError("Prompt failed")
        }
    }

    /// Option + 1 Smart Polish. This action is deliberately selection-only: it never
    /// reads dictation history and never inserts into a cursor without the same live selection.
    public func polishActiveSelectionOrRecentDictation() async {
        guard !isRewritingSelection, state != .processing else {
            overlayController.showError("Polish already in progress.")
            return
        }
        isRewritingSelection = true
        defer { isRewritingSelection = false }
        let requestID = UUID()
        overlayController.showPolishing(message: "Reading selection…")
        Self.polishLog.debug("request \(requestID.uuidString, privacy: .public) received")
        let capture = await textInjection.captureCurrentSelection()
        let selection: SelectedTextSnapshot
        switch capture {
        case .captured(let snapshot):
            selection = snapshot
            Self.polishLog.debug("request \(requestID.uuidString, privacy: .public) captured via \(snapshot.method.rawValue, privacy: .public), length \(snapshot.text.count, privacy: .public), target \(snapshot.bundleIdentifier ?? "unknown", privacy: .public)")
        case .permissionDenied:
            overlayController.showError("Allow Accessibility to read selected text.")
            return
        case .noSelection:
            overlayController.showError("Select some text, then press ⌥1 to polish it.")
            return
        case .secureInput, .unsupported, .failed:
            overlayController.showError("Select editable text in an app, then press ⌥1 to polish it.")
            return
        }
        do {
            overlayController.showPolishing(message: settings.polishProvider.map { "Polishing with \($0.displayName)…" } ?? "Rewriting privately on this Mac…")
            let started = ContinuousClock.now
            let polished = try await LocalWritingAssistant.polish(
                selection.text,
                tone: PolishTone(rawValue: settings.smartPolishTone) ?? .natural,
                protectedWords: vocabularyStore.entries.flatMap { [$0.phrase, $0.replacement] }
            )
            Self.polishLog.debug("request \(requestID.uuidString, privacy: .public) generation finished in \(String(describing: ContinuousClock.now - started), privacy: .public)")
            guard !Task.isCancelled else { return }
            if polished == selection.text {
                overlayController.showPolished(message: "This text is already polished.")
                return
            }
            overlayController.showPolishing(message: "Replacing text…")
            await applyPolish(polished, selection: selection, requestID: requestID)
        } catch {
            Self.polishLog.error("request \(requestID.uuidString, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            let message: String
            if let polishError = error as? LocalWritingAssistant.PolishError {
                switch polishError {
                case .alreadyRunning: message = "Polish already in progress."
                case .unavailable(let reason): message = reason
                case .invalidInput: message = "Select some text, then press ⌥1 to polish it."
                case .generationFailed: message = "Apple Intelligence could not finish polishing."
                case .unsafeOutput: message = "The rewrite was not safe to apply; your selection was kept."
                }
            } else {
                message = error.localizedDescription
            }
            overlayController.showError(message)
        }
    }

    /// Records and replaces Option + 1 output, using an honest completion message when
    /// the safe local pass finds no changes to make.
    private func applyPolish(
        _ polished: String,
        selection: SelectedTextSnapshot,
        requestID: UUID
    ) async {
        let outcome = await textInjection.replaceCapturedSelection(selection, with: polished)
        switch outcome {
        case .verified:
            Self.polishLog.debug("request \(requestID.uuidString, privacy: .public) replacement verified")
            historyStore.append(text: polished, bundleIdentifier: selection.bundleIdentifier)
            overlayController.showPolished(message: "Text polished.")
        case .sentUnverified:
            Self.polishLog.debug("request \(requestID.uuidString, privacy: .public) replacement sent without AX verification")
            historyStore.append(text: polished, bundleIdentifier: selection.bundleIdentifier)
            overlayController.showPolished(message: "Polished text sent to the selected app.")
        case .selectionChanged, .targetChanged:
            Self.polishLog.notice("request \(requestID.uuidString, privacy: .public) replacement suppressed because selection changed")
            resultCardController.show(text: polished, status: "The original selection changed, so LocalFlow did not replace it.", persistent: true)
        case .unsupported, .failed:
            Self.polishLog.error("request \(requestID.uuidString, privacy: .public) replacement failed")
            overlayController.showError("Could not replace the selected text.")
        }
    }

    private func setupHandsFreeTimers() {
        // 1. Hard auto-stop at the capture limit: stop cleanly and transcribe whatever was captured
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(AudioCaptureSession.maxRecordingSeconds))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self?.state == .listening, self?.sessionMode == .handsFree else { return }
                    Task { @MainActor in
                        await self?.endDictation()
                    }
                }
            } catch {}
        }

        // 2. Extended continuous silence detection (45 seconds threshold):
        // If the user spoke, auto-transcribe rather than discarding! Only cancel if untouched silence.
        handsFreeSilenceTask?.cancel()
        handsFreeSilenceTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard let self, self.state == .listening, self.sessionMode == .handsFree else { return }
                        if self.audioCapture.continuousSilenceDurationSeconds >= 45.0 {
                            if self.audioCapture.hasMeaningfulAudio {
                                // User spoke thoughts and stopped: auto-transcribe & insert!
                                Task { @MainActor in
                                    await self.endDictation()
                                }
                            } else {
                                // Accidental activation with pure silence: cleanly cancel
                                self.teardownSession(errorMessage: "Hands-free session cancelled due to inactivity.")
                            }
                        }
                    }
                } catch {
                    break
                }
            }
        }
    }

    public func beginDictation(mode: DictationSessionMode = .pushToTalk) async {
        // A new paste would show up as an "edit" of the previous one.
        correctionWatchTask?.cancel()
        cancelledAudio = nil  // a new recording replaces any pending Undo/Retry

        // Guarantee any previous session (or stuck state) is cleanly torn down first.
        if state != .idle {
            teardownSession()
        }

        // Never capture audio without a real engine — that was producing empty history.
        if !isEngineReady {
            do {
                try await prepareModelsWithError()
            } catch {
                lastErrorMessage = "Speech model not ready. Open Settings → General → Apply & prepare. (\(error.localizedDescription))"
                state = .error
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    if self.state == .error { self.teardownSession() }
                }
                return
            }
        }

        guard isEngineReady else {
            lastErrorMessage = "Speech model not loaded. Finish onboarding or download a model in Settings → General."
            return
        }

        // Remember where text should land — Settings/LocalFlow must never become the paste target.
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier {
            targetApplication = front
            lastExternalApplication = front
        } else if let last = lastExternalApplication, !last.isTerminated {
            targetApplication = last
        }


        do {
            try audioCapture.start()
            sessionMode = mode
            sessionStartTime = Date()
            overlayController.show(mode: mode, levelsPublisher: audioCapture.waveformLevelsPublisher)
            state = .listening
            lastErrorMessage = nil

            if mode == .handsFree {
                setupHandsFreeTimers()
            } else {
                // Hard timeout failsafe: auto-stop and transcribe at the capture limit
                timeoutTask?.cancel()
                timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: .seconds(AudioCaptureSession.maxRecordingSeconds))
                        guard !Task.isCancelled else { return }
                        await MainActor.run {
                            guard self?.state == .listening else { return }
                            Task { @MainActor in
                                // Auto-stop and transcribe whatever was captured — NEVER discard audio!
                                await self?.endDictation()
                            }
                        }
                    } catch {}
                }
            }
        } catch {
            teardownSession(errorMessage: error.localizedDescription)
        }
    }

    public func endDictation() async {
        guard state == .listening else { return }

        // Cancel recording timeouts
        timeoutTask?.cancel()
        timeoutTask = nil
        handsFreeSilenceTask?.cancel()
        handsFreeSilenceTask = nil
        pendingKeyReleaseTask?.cancel()
        pendingKeyReleaseTask = nil

        let audio = audioCapture.stop()
        overlayController.hide()
        transcribe(audio, capturedSpeech: audioCapture.hasMeaningfulAudio)
    }

    /// Transcribes captured audio, then runs commands or formats and inserts the text.
    private func transcribe(_ audio: CapturedAudio, capturedSpeech: Bool) {
        // Silence detection: if no meaningful audio energy was captured for the hold duration,
        // explicitly cancel and tear down the session — do not attempt to transcribe or inject.
        guard !audio.isEmpty, audio.hasMeaningfulAudio, capturedSpeech else {
            teardownSession(errorMessage: "No speech detected.")
            return
        }

        state = .processing
        // Keep the user oriented while the local speech engine and formatter work,
        // then hide this small HUD only after we inject or show the fallback card.
        overlayController.showProcessing()

        // Hard timeout failsafe on processing: prevent indefinite hangs in transcription engines (120s limit)
        timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 120_000_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self?.state == .processing else { return }
                    self?.teardownSession(errorMessage: "Transcription timed out.")
                }
            } catch {}
        }

        dictationTask?.cancel()
        dictationTask = Task { @MainActor in
            do {
                let result = try await router.transcribe(audio: audio)
                // Whoever cancelled already tore down; tearing down again would kill a newer session.
                guard !Task.isCancelled else { return }

                let corrected = vocabularyStore.apply(to: result.text)
                let trimmed = corrected.trimmingCharacters(in: .whitespacesAndNewlines)

                // If transcription engine returns empty/near-empty result, explicitly cancel
                guard !trimmed.isEmpty else {
                    teardownSession(errorMessage: "No speech recognized. Try speaking again.")
                    return
                }

                switch commandMode.resolve(trimmed, transcriptionConfidence: result.confidence) {
                case .notCommand:
                    let target = resolvedTargetApplication()
                    let bundleID = target?.bundleIdentifier
                        ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                    let profile = formatter.profile(for: bundleID, applicationName: target?.localizedName)
                    let cleaned = speechCleanup.clean(
                        trimmed,
                        options: SpeechCleanupOptions(settings: settings),
                        vocabularyStore: vocabularyStore
                    )
                    let formatted = formatter.format(cleaned, profile: profile, vocabularyStore: vocabularyStore)
                    // Always keep history even when paste/AX insert fails.
                    historyStore.append(text: formatted, bundleIdentifier: bundleID)
                    do {
                        let outcome = try await textInjection.insert(formatted, into: target)
                        guard !Task.isCancelled else { return }
                        switch outcome {
                        case .inserted:
                            teardownSession(clearErrorMessage: true)
                            watchForCorrections(of: formatted, in: target)
                        case .noFocusedTarget:
                            // Fallback UI: show floating result card near cursor
                            resultCardController.show(text: formatted)
                            teardownSession(clearErrorMessage: true)
                        }
                    } catch LocalFlowError.accessibilityPermissionMissing {
                        if Task.isCancelled { return }
                        teardownSession(errorMessage: "Transcribed and saved to History, but paste needs Accessibility. Enable LocalFlow in System Settings → Privacy & Security → Accessibility (text is also on your clipboard — press ⌘V).")
                    } catch {
                        if Task.isCancelled { return }
                        // Paste failed for another reason: keep the text one click away instead of blaming permissions.
                        resultCardController.show(text: formatted, status: "Couldn't paste. Copy it here — it's also in History.", persistent: true)
                        teardownSession(clearErrorMessage: true)
                    }
                case .execute(let intent):
                    commandMode.execute(intent)
                    teardownSession(clearErrorMessage: true)
                    if case .searchWeb(_, let provider, _) = intent {
                        overlayController.showPolished(message: "Opening \(provider)...", durationSeconds: 1.5)
                    } else if case .spotifySearchAndPlay = intent {
                        overlayController.showPolished(message: "Opening Spotify...", durationSeconds: 1.5)
                    }
                case .needsConfirmation(let intent):
                    pendingCommand = intent
                    teardownSession(clearErrorMessage: true)
                }
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                teardownSession(errorMessage: "Transcription failed: \(error.localizedDescription)")
                // Never lose what the user said to an engine hiccup: hold the audio and offer Retry.
                cancelledAudio = (audio, capturedSpeech)
                overlayController.showCancelled(title: "Transcription failed", actionTitle: "Retry", durationSeconds: 10) { [weak self] in
                    self?.cancelledAudio = nil
                }
            }
        }
    }

    /// After a paste, watch the same field until the user leaves it (max ~30 s) and learn
    /// one-word fixes they make inside the dictation. Reads stay on this Mac; only learned words are stored.
    private func watchForCorrections(of inserted: String, in target: NSRunningApplication?) {
        guard settings.learnFromCorrections else { return }
        correctionWatchTask?.cancel()
        let pid = target?.processIdentifier
        correctionWatchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))  // let the paste land
            guard let self, !Task.isCancelled,
                  let start = self.textInjection.focusedFieldText(preferredPID: pid) else { return }
            var latest = start.text
            for _ in 0..<60 {
                try? await Task.sleep(for: .milliseconds(500))
                if Task.isCancelled { return }
                guard let now = self.textInjection.focusedFieldText(preferredPID: pid),
                      CFEqual(now.element, start.element) else { break }
                latest = now.text
            }
            let checker = NSSpellChecker.shared
            let corrections = CorrectionDetector.corrections(inserted: inserted, before: start.text, after: latest) { word in
                checker.checkSpelling(of: word, startingAt: 0).location == NSNotFound
            }
            let learned = corrections.filter { self.vocabularyStore.learn($0) }
            guard let first = learned.first, self.state == .idle else { return }
            self.overlayController.showPolished(
                message: learned.count == 1 ? "New word learned: \(first.corrected)" : "\(learned.count) new words learned",
                durationSeconds: 2.2
            )
        }
    }

        /// Prefer the app captured at hotkey-down; never paste into LocalFlow itself.
    private func resolvedTargetApplication() -> NSRunningApplication? {
        if let target = targetApplication, !target.isTerminated,
           target.bundleIdentifier != Bundle.main.bundleIdentifier {
            return target
        }
        if let last = lastExternalApplication, !last.isTerminated {
            return last
        }
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier {
            return front
        }
        return nil
    }
}

// MARK: - Test seam (the production types below are the only real conformers)

@MainActor
protocol AudioCapturing: AnyObject {
    var onInterrupted: (() -> Void)? { get set }
    var hasMeaningfulAudio: Bool { get }
    var continuousSilenceDurationSeconds: Double { get }
    var waveformLevelsPublisher: AnyPublisher<[Float], Never> { get }
    func requestMicrophonePermission() async -> Bool
    func start() throws
    func stop() -> CapturedAudio
    func reset()
}

extension AudioCaptureSession: AudioCapturing {
    var waveformLevelsPublisher: AnyPublisher<[Float], Never> { $waveformLevels.eraseToAnyPublisher() }
}

protocol TextInjecting: AnyObject, Sendable {
    func isAccessibilityTrusted(prompt: Bool) -> Bool
    func insert(_ text: String, into targetApp: NSRunningApplication?) async throws -> TextInjectionOutcome
    func captureCurrentSelection() async -> SelectedTextCaptureResult
    func replaceCapturedSelection(_ snapshot: SelectedTextSnapshot, with polished: String) async -> SelectionReplacementResult
    func focusedFieldText(preferredPID: pid_t?) -> (element: AXUIElement, text: String)?
}

extension TextInjection: TextInjecting {}

@MainActor
protocol DictationOverlayPresenting: AnyObject {
    var onCancel: (() -> Void)? { get set }
    var onFinishAndPaste: (() -> Void)? { get set }
    var onUndo: (() -> Void)? { get set }
    func show(mode: DictationSessionMode, levelsPublisher: AnyPublisher<[Float], Never>)
    func showCancelled(title: String, actionTitle: String, durationSeconds: Double, onDismiss: @escaping () -> Void)
    func showPolished(message: String, durationSeconds: Double)
    func showError(_ message: String)
    func showPolishing(message: String)
    func showProcessing()
    func hide()
}

extension DictationOverlayPresenting {
    func showPolished(message: String) { showPolished(message: message, durationSeconds: 1.6) }
}

extension OverlayWindowController: DictationOverlayPresenting {}

@MainActor
protocol ResultCardPresenting: AnyObject {
    func show(text: String, status: String, persistent: Bool)
}

extension ResultCardPresenting {
    func show(text: String) { show(text: text, status: "No text field selected", persistent: false) }
}

extension FloatingResultCardController: ResultCardPresenting {}

extension Notification.Name {
    /// Posted whenever LocalFlow's activity state changes.
    public static let localFlowActivityStateDidChange = Notification.Name("LocalFlowActivityStateDidChange")
    /// Posted when the active STT engine changes (object is a display string).
    public static let localFlowEngineDidChange = Notification.Name("LocalFlowEngineDidChange")
}
