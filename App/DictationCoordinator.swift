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

    /// The audio capture service.
    public let audioCapture = AudioCaptureSession()

    /// Local dictation history (shared with Settings).
    public let historyStore: DictationHistoryStore

    /// Local custom vocabulary (shared with Settings).
    public let vocabularyStore: VocabularyStore

    private let settings = LocalFlowSettings.shared
    private let hotkeyManager = HotkeyManager()
    private let modelManager = ModelManager.shared
    private let textInjection = TextInjection()
    private let commandMode = CommandMode()
    private let speechCleanup = SpeechCleanup()
    private let formatter = SmartFormatting()
    private var isRewritingSelection = false
    private let overlayController = OverlayWindowController()
    private let resultCardController = FloatingResultCardController()
    private var cancellables = Set<AnyCancellable>()
    private var router = TranscriptionRouter(engine: UnavailableEngine(message: "Model not loaded"))
    private var dictationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var handsFreeSilenceTask: Task<Void, Never>?
    private var pendingKeyReleaseTask: Task<Void, Never>?
    private var sessionStartTime: Date?

    /// The active session mode (push-to-talk vs. locked hands-free).
    @Published public private(set) var sessionMode: DictationSessionMode = .pushToTalk

    /// App that was frontmost when the user started holding the hotkey (never LocalFlow itself).
    private var targetApplication: NSRunningApplication?
    /// Continuously tracks the last non-LocalFlow frontmost app (survives Settings being key).
    private var lastExternalApplication: NSRunningApplication?
    private var workspaceObserver: (any NSObjectProtocol)?

    /// Creates a dictation coordinator and starts observing the hotkey.
    public init(
        historyStore: DictationHistoryStore = DictationHistoryStore(),
        vocabularyStore: VocabularyStore = VocabularyStore()
    ) {
        self.historyStore = historyStore
        self.vocabularyStore = vocabularyStore
        hotkeyManager.start()
        hotkeyManager.eventPublisher
            .sink { [weak self] event in
                Task { @MainActor in
                    await self?.handle(hotkeyEvent: event)
                }
            }
            .store(in: &cancellables)

        overlayController.onCancel = { [weak self] in
            Task { @MainActor in
                self?.cancelHandsFreeSession()
            }
        }
        overlayController.onFinishAndPaste = { [weak self] in
            Task { @MainActor in
                await self?.endDictation()
            }
        }
        overlayController.onUndo = { [weak self] in
            Task { @MainActor in
                self?.undoCancellation()
            }
        }

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
        guard modelManager.modelsAvailable() || appleReady else { return }
        await prepareModels()
    }

    /// Prepares speech models and throws on failure, enabling callers to surface errors.
    public func prepareModelsWithError() async throws {
        let engine = try await modelManager.prepareEngine()
        let name = modelManager.selectedEngine.kind.displayName
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
    public func teardownSession(errorMessage: String? = nil, clearErrorMessage: Bool = false) {
        timeoutTask?.cancel()
        timeoutTask = nil

        dictationTask?.cancel()
        dictationTask = nil

        handsFreeSilenceTask?.cancel()
        handsFreeSilenceTask = nil

        pendingKeyReleaseTask?.cancel()
        pendingKeyReleaseTask = nil

        sessionStartTime = nil
        sessionMode = .pushToTalk

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

        _ = audioCapture.stop()
        state = .idle

        // Present the "Transcript cancelled" undo state with 3.5s countdown
        overlayController.showCancelled(durationSeconds: 3.5) { [weak self] in
            self?.teardownSession(errorMessage: nil, clearErrorMessage: true)
        }
    }

    /// Restores the hands-free session if the user taps "Undo".
    public func undoCancellation() {
        Task { @MainActor in
            await beginDictation(mode: .handsFree)
        }
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
                overlayController.show(mode: .handsFree, levelsPublisher: audioCapture.$waveformLevels.eraseToAnyPublisher())
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
            overlayController.showPolishing(message: "Rewriting privately on this Mac…")
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
            AgentDebugLog.write(hypothesisId: "polish", location: "DictationCoordinator.polish", message: "On-device polish failed", data: ["error": error.localizedDescription])
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
                message = "Apple Intelligence could not finish polishing."
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
        // 1. Hard auto-stop timeout at 30 minutes (1,800 seconds): auto-stop cleanly and transcribe whatever was captured
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 1_800_000_000_000)
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
        // Guarantee any previous session (or stuck state) is cleanly torn down first.
        if state != .idle {
            teardownSession()
        }

        // Never capture audio without a real engine — that was producing empty history.
        if !isEngineReady {
            do {
                try await prepareModelsWithError()
            } catch {
                lastErrorMessage = "Speech model not ready. Open Settings → General → Download / Prepare Model. (\(error.localizedDescription))"
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

        // #region agent log
        AgentDebugLog.write(
            hypothesisId: "C",
            location: "DictationCoordinator.swift:beginDictation",
            message: "dictation started",
            data: [
                "mode": mode.rawValue,
                "frontBundle": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil",
                "targetBundle": targetApplication?.bundleIdentifier ?? "nil",
                "lastExternal": lastExternalApplication?.bundleIdentifier ?? "nil",
                "engine": activeEngineName
            ]
        )
        // #endregion

        do {
            try audioCapture.start()
            sessionMode = mode
            sessionStartTime = Date()
            overlayController.show(mode: mode, levelsPublisher: audioCapture.$waveformLevels.eraseToAnyPublisher())
            state = .listening
            lastErrorMessage = nil

            if mode == .handsFree {
                setupHandsFreeTimers()
            } else {
                // Hard timeout failsafe: auto-stop and transcribe if held longer than 30 minutes
                timeoutTask?.cancel()
                timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: 1_800_000_000_000)
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

        // Silence detection: if no meaningful audio energy was captured for the hold duration,
        // explicitly cancel and tear down the session — do not attempt to transcribe or inject.
        guard !audio.isEmpty, audio.hasMeaningfulAudio, audioCapture.hasMeaningfulAudio else {
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
                guard !Task.isCancelled else {
                    teardownSession()
                    return
                }

                let corrected = vocabularyStore.apply(to: result.text)
                let trimmed = corrected.trimmingCharacters(in: .whitespacesAndNewlines)

                // If transcription engine returns empty/near-empty result, explicitly cancel
                guard !trimmed.isEmpty else {
                    teardownSession(errorMessage: "No speech recognized. Try speaking again.")
                    return
                }

                // Prompt mode never dispatches a spoken command or pastes into a shell.
                if settings.promptModeEnabled {
                    let target = resolvedTargetApplication()
                    let rewrite = await LocalWritingAssistant.rewrite(
                        trimmed, purpose: .prompt,
                        protectedWords: vocabularyStore.entries.flatMap { [$0.phrase, $0.replacement] }
                    )
                    guard !Task.isCancelled else { return }
                    historyStore.append(text: rewrite.text, bundleIdentifier: target?.bundleIdentifier)
                    resultCardController.show(text: rewrite.text, status: rewrite.notice ?? "Review your prompt · Copy into your AI app", persistent: true)
                    teardownSession(clearErrorMessage: true)
                    return
                }

                switch commandMode.resolve(trimmed, transcriptionConfidence: result.confidence) {
                case .notCommand:
                    let target = resolvedTargetApplication()
                    let bundleID = target?.bundleIdentifier
                        ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                    let profile = formatter.profile(for: bundleID)
                    let preserveLiterals = profile == .code || profile == .prompt
                    let cleaned = preserveLiterals ? trimmed : speechCleanup.clean(
                        trimmed,
                        options: SpeechCleanupOptions(settings: settings),
                        vocabularyStore: vocabularyStore
                    )
                    let formatted = formatter.format(cleaned, profile: profile, vocabularyStore: vocabularyStore)
                    // #region agent log
                    AgentDebugLog.write(
                        hypothesisId: "C",
                        location: "DictationCoordinator.swift:endDictation",
                        message: "transcription ok, about to insert",
                        data: [
                            "textLen": formatted.count,
                            "raw": trimmed,
                            "cleaned": cleaned,
                            "targetBundle": target?.bundleIdentifier ?? "nil",
                            "frontBundle": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil",
                            "axTrusted": textInjection.isAccessibilityTrusted(prompt: false)
                        ],
                        runId: "post-fix"
                    )
                    // #endregion
                    // Always keep history even when paste/AX insert fails.
                    historyStore.append(text: formatted, bundleIdentifier: bundleID)
                    do {
                        let outcome = try await textInjection.insert(formatted, into: target)
                        switch outcome {
                        case .inserted:
                            // #region agent log
                            AgentDebugLog.write(
                                hypothesisId: "D",
                                location: "DictationCoordinator.swift:endDictation",
                                message: "insert returned success",
                                data: [
                                    "targetBundle": target?.bundleIdentifier ?? "nil",
                                    "frontAfter": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
                                ],
                                runId: "post-fix"
                            )
                            // #endregion
                            teardownSession(clearErrorMessage: true)
                        case .noFocusedTarget:
                            // #region agent log
                            AgentDebugLog.write(
                                hypothesisId: "D",
                                location: "DictationCoordinator.swift:endDictation",
                                message: "no focused target, showing floating card",
                                data: [
                                    "targetBundle": target?.bundleIdentifier ?? "nil"
                                ],
                                runId: "post-fix"
                            )
                            // #endregion
                            // Fallback UI: show floating result card near cursor
                            resultCardController.show(text: formatted)
                            teardownSession(clearErrorMessage: true)
                        }
                    } catch {
                        // #region agent log
                        AgentDebugLog.write(
                            hypothesisId: "D",
                            location: "DictationCoordinator.swift:endDictation",
                            message: "insert threw",
                            data: ["error": error.localizedDescription]
                        )
                        // #endregion
                        teardownSession(errorMessage: "Transcribed and saved to History, but paste needs Accessibility. Enable LocalFlow in System Settings → Privacy & Security → Accessibility (text is also on your clipboard — press ⌘V).")
                    }
                case .execute(let intent):
                    commandMode.execute(intent)
                    teardownSession(clearErrorMessage: true)
                    if case .searchWeb(_, let provider, _) = intent {
                        overlayController.showPolished(message: "Opening \(provider)...", durationSeconds: 1.5)
                    } else if case .spotifySearchAndPlay = intent {
                        overlayController.showPolished(message: "Finding Spotify result…", durationSeconds: 1.8)
                    }
                case .needsConfirmation(let intent):
                    pendingCommand = intent
                    teardownSession(clearErrorMessage: true)
                }
            } catch {
                // #region agent log
                AgentDebugLog.write(
                    hypothesisId: "B",
                    location: "DictationCoordinator.swift:endDictation",
                    message: "transcription failed",
                    data: ["error": error.localizedDescription]
                )
                // #endregion
                teardownSession(errorMessage: "Transcription failed: \(error.localizedDescription)")
            }
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

extension Notification.Name {
    /// Posted whenever LocalFlow's activity state changes.
    public static let localFlowActivityStateDidChange = Notification.Name("LocalFlowActivityStateDidChange")
    /// Posted when the active STT engine changes (object is a display string).
    public static let localFlowEngineDidChange = Notification.Name("LocalFlowEngineDidChange")
}
