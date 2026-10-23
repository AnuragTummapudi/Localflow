import AppKit
import Combine
import Foundation
import OSLog
import NaturalLanguage
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
    @Published public private(set) var pendingCommand: CommandIntent?

    /// The display name of the engine currently handling transcription.
    @Published public private(set) var activeEngineName: String = "Not loaded"

    /// Last user-visible error message (cleared on next successful start).
    @Published public private(set) var lastErrorMessage: String?

    /// Revisable UI speech. Ordinary dictation enters commands/history only after final ASR.
    @Published public private(set) var transcriptState = TranscriptState()

    /// Streaming is optional; batch transcription remains ready if setup fails.
    @Published public private(set) var streamingStatus = "Not prepared"

    /// Whether a speech engine is ready to transcribe.
    public var isEngineReady: Bool { activeEngineName != "Not loaded" }

    /// The audio capture service.
    public let audioCapture = AudioCaptureSession()

    /// Local dictation history (shared with Settings).
    public let historyStore: DictationHistoryStore

    /// Local custom vocabulary (shared with Settings).
    public let vocabularyStore: VocabularyStore

    public let agentMemory: AgentMemoryStore

    private let settings = LocalFlowSettings.shared
    private let hotkeyManager = HotkeyManager()
    private let modelManager = ModelManager.shared
    private let textInjection = TextInjection()
    private let commandMode = CommandMode()
    public let plannerModels = PlannerModelManager.shared
    @Published public private(set) var isTypedPlannerSession = false
    private var typedPlannerTask: Task<Void, Never>?
    private lazy var actionExecutor: ActionExecutor = ActionExecutor(registry: ToolRegistry(system: MacNativeToolSystem(injection: textInjection, preferredBrowser: { [weak self] in
        guard let self else { return nil }
        return (self.isVoiceAgentSession ? self.voiceAgent.operationalMemory : self.agentMemory.memory).preferredApps["browser"]
    }, memory: { [weak self] in
        guard let self else { return AgentMemory() }
        return (self.isVoiceAgentSession || self.isTypedPlannerSession) ? self.voiceAgent.operationalMemory : self.agentMemory.memory
    })))
    private var nativeActionTask: Task<Void, Never>?
    private var nativePresentationID = UUID()
    private var pendingToolConfirmation: ToolConfirmation?
    private var lastToolUndo: ToolUndoToken?
    private let decisionModels = DecisionModelManager.shared
    @Published public private(set) var isVoiceAgentSession = false
    public private(set) lazy var voiceAgent: VoiceAgentCoordinator = VoiceAgentCoordinator(commands: commandMode, executor: actionExecutor, memoryStore: agentMemory) { [weak self] state, fallback in
        guard let self else { return AgentDecisionEvaluation(decisions: fallback, source: .deterministic) }
        return await self.decisionModels.evaluateForAgent(state, fallback: fallback)
    }
    @Published public private(set) var benchmarkResults: [AgentBenchmarkResult] = []
    private var pendingBenchmark: (Int, [AgentAction])?
#if DEBUG
    @Published public private(set) var realityConfirmation: ToolConfirmation?
    @Published public private(set) var realityConfirmationStatus = "UNVERIFIED"
    @Published public private(set) var realityPreviewPreparing = false
    private var realityPreviewGeneration = UUID()
    public func prepareRealityConfirmation() async {
        guard state == .idle, !isStartingDictation, !isRewritingSelection, !realityPreviewPreparing,
              voiceAgent.snapshot.confirmation == nil else { return }
        cancelRealityPreview()
        let id = UUID(); realityPreviewGeneration = id; realityPreviewPreparing = true
        defer { if realityPreviewGeneration == id { realityPreviewPreparing = false } }
        let result = await actionExecutor.execute(AgentAction(toolID: .lockMac, arguments: .none))
        guard realityPreviewGeneration == id, !Task.isCancelled else {
            if case .requiresConfirmation(let grant) = result { actionExecutor.cancelConfirmation(matching: grant) }
            return
        }
        if case .requiresConfirmation(let grant) = result {
            realityConfirmation = grant
            realityConfirmationStatus = "UNVERIFIED — real confirmation grant prepared; no effect sent"
        } else {
            realityConfirmation = nil
            realityConfirmationStatus = "FAILED — could not prepare the test confirmation"
        }
    }
    public func confirmRealityPreview() {
        guard let grant = realityConfirmation else { return }
        realityConfirmation = nil
        realityConfirmationStatus = actionExecutor.validateConfirmationWithoutPerforming(grant)
            ? "VERIFIED — single-use confirmation consumed; lock effect deliberately not performed"
            : "FAILED — confirmation expired or was superseded"
    }
    public func cancelRealityPreview() {
        realityPreviewGeneration = UUID(); realityPreviewPreparing = false
        guard let grant = realityConfirmation else { return }
        realityConfirmation = nil; actionExecutor.cancelConfirmation(matching: grant)
        realityConfirmationStatus = "UNVERIFIED — preview cancelled; no effect sent"
    }
#endif
    public func beginBenchmark(_ scenario: AgentBenchmarkScenario) async throws {
        guard state == .idle, !isStartingDictation, !isRewritingSelection else { throw ToolError.busy }
        agentMemory.reload()
        let expected = try scenario.expectedActions(commands: commandMode.forAgentSession(memory: agentMemory.memory))
        await beginVoiceAgent()
        guard isVoiceAgentSession, state == .listening else { throw ToolError.unavailable(lastErrorMessage ?? "Voice capture could not start.") }
        pendingBenchmark = (scenario.id, expected)
    }
    public func exportBenchmarks() throws -> URL {
        let url = agentMemory.fileURL.deletingLastPathComponent().appendingPathComponent("benchmark.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(benchmarkResults).write(to: url, options: .atomic)
        return url
    }
    @Published public private(set) var lastDecisions: SpeechDecisions?
    private let speechCleanup = SpeechCleanup()
    private let formatter = SmartFormatting()
    private var isRewritingSelection = false
    private let overlayController = OverlayWindowController()
    private let resultCardController = FloatingResultCardController()
    private var cancellables = Set<AnyCancellable>()
    private var router = TranscriptionRouter(engine: UnavailableEngine(message: "Model not loaded"))
    private let streamingRouter = StreamingTranscriptionRouter()
    private var streamingStartTask: Task<StreamingTranscriptionSession, Never>?
    private var streamingEventsTask: Task<Void, Never>?
    private var recordingID: UUID?
    private var isStartingDictation = false
    private var isResettingAgentMemory = false
    public func resetOperationalMemory() async throws {
        guard state == .idle, !isStartingDictation, !isRewritingSelection, !isResettingAgentMemory else { throw ToolError.busy }
        isResettingAgentMemory = true
        defer { isResettingAgentMemory = false }
        let retiredNativeAction = nativeActionTask
        cancelPendingCommand()
        await voiceAgent.cancelAndWait()
        await retiredNativeAction?.value
        try agentMemory.reset()
    }
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
        vocabularyStore: VocabularyStore = VocabularyStore(),
        agentMemory: AgentMemoryStore? = nil
    ) {
        self.agentMemory = agentMemory ?? AgentMemoryStore()
        self.historyStore = historyStore
        self.vocabularyStore = vocabularyStore
        decisionModels.prepareInstalled()
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
                guard let self else { return }
                if self.isTypedPlannerSession {
                    self.cancelTypedPlanner()
                } else if self.isVoiceAgentSession {
                    self.teardownSession(clearErrorMessage: true)
                    self.overlayController.showCancelled(durationSeconds: 1.6, allowsUndo: false, message: "Voice Agent cancelled")
                } else if self.overlayController.isConfirming {
                    self.cancelPendingCommand()
                } else {
                    self.cancelHandsFreeSession()
                }
            }
        }
        overlayController.onConfirm = { [weak self] in self?.confirmPendingCommand() }
        overlayController.onFinishAndPaste = { [weak self] in
            Task { @MainActor in
                await self?.endDictation()
            }
        }
        overlayController.onUndo = { [weak self] in
            guard let self else { return }
            if let token = self.lastToolUndo {
                self.undoNativeAction(token)
            } else if self.overlayController.supportsCancellationUndo {
                self.undoCancellation()
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
        await modelManager.refreshReadiness()
        guard modelManager.modelsAvailable else { return }
        do { try await prepareModelsWithError(allowInstallation: false) }
        catch { state = .error; lastErrorMessage = error.localizedDescription }
    }

    public func prepareModelsWithError(allowInstallation: Bool = true) async throws {
        let engine = try await modelManager.prepareEngine(allowInstallation: allowInstallation)
        await router.updateEngine(engine, name: "Apple Speech")
        await streamingRouter.updateEngine(engine)
        activeEngineName = "Apple Speech"
        streamingStatus = modelManager.speechReadiness.detail
        NotificationCenter.default.post(name: .localFlowEngineDidChange, object: "Apple Speech")
        if state != .listening && state != .processing { state = .idle }
        lastErrorMessage = nil
    }

    /// Executes only the exact single-use action captured by the executor.
    public func confirmPendingCommand() {
        if isVoiceAgentSession || isTypedPlannerSession {
            Task { @MainActor [weak self] in await self?.voiceAgent.confirm() }
            return
        }
        guard let intent = pendingCommand, let challenge = pendingToolConfirmation else { return }
        pendingCommand = nil
        pendingToolConfirmation = nil
        let id = UUID()
        nativePresentationID = id
        overlayController.showActing(actionPresentation(for: intent))
        let presentation = overlayController.currentPresentationID
        nativeActionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.actionExecutor.confirm(challenge)
            guard self.nativePresentationID == id else { return }
            self.nativeActionTask = nil
            guard self.overlayController.currentPresentationID == presentation else { return }
            self.presentToolResult(result, intent: intent)
        }
    }

    public func cancelPendingCommand() {
        pendingCommand = nil
        pendingToolConfirmation = nil
        actionExecutor.cancelConfirmation()
        invalidateNativePresentation()
        if overlayController.isConfirming {
            overlayController.showCancelled(durationSeconds: 1.6, allowsUndo: false, message: "Command cancelled")
        }
    }

    private func invalidateNativePresentation() {
        nativePresentationID = UUID()
        nativeActionTask?.cancel()
        nativeActionTask = nil
        lastToolUndo = nil
    }

    private func executeCommand(_ intent: CommandIntent, requireConfirmation: Bool = false) {
        invalidateNativePresentation()
        let id = nativePresentationID
        overlayController.showActing(actionPresentation(for: intent))
        let presentation = overlayController.currentPresentationID
        nativeActionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.commandMode.execute(intent, using: self.actionExecutor, requireConfirmation: requireConfirmation)
            guard self.nativePresentationID == id else { return }
            self.nativeActionTask = nil
            guard self.overlayController.currentPresentationID == presentation else { return }
            self.presentToolResult(result, intent: intent)
        }
    }

    private func undoNativeAction(_ token: ToolUndoToken) {
        invalidateNativePresentation()
        let id = nativePresentationID
        overlayController.showActing(OverlayMessage(title: "Undoing…", symbol: "arrow.uturn.backward"))
        let presentation = overlayController.currentPresentationID
        nativeActionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.actionExecutor.undo(token)
            guard self.nativePresentationID == id else { return }
            self.nativeActionTask = nil
            guard self.overlayController.currentPresentationID == presentation else { return }
            self.presentToolResult(result, intent: nil)
        }
    }

    private func presentToolResult(_ result: ToolResult, intent: CommandIntent?) {
        switch result {
        case .requiresConfirmation(let challenge):
            guard let intent else { return }
            pendingCommand = intent
            pendingToolConfirmation = challenge
            overlayController.showConfirmation(OverlayMessage(title: challenge.action.summary, detail: "Confirm this action?", symbol: "hand.raised"))
        case .completed(let message, _, let verification, let undo):
            lastToolUndo = undo
            overlayController.showToolResult(message: message, verified: verification == .verified, allowsUndo: undo != nil)
        case .failed(let message):
            lastErrorMessage = message
            overlayController.showError(message)
        case .cancelled:
            overlayController.showCancelled(durationSeconds: 1.6, allowsUndo: false, message: "Command cancelled")
        }
    }

    /// Unified session teardown: guarantees audio engine, overlay, tasks, flags,
    /// and state all return to a clean idle state through one single path.
    public func teardownSession(
        errorMessage: String? = nil,
        clearErrorMessage: Bool = false,
        cancelDictationTask: Bool = true,
        preserveOverlay: Bool = false,
        preserveVoiceAgent: Bool = false
    ) {
        if !preserveVoiceAgent, isVoiceAgentSession {
            isVoiceAgentSession = false
            voiceAgent.cancel()
        }
        cancelStreamingSession()
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

        audioCapture.reset()
        if !preserveOverlay { overlayController.hide() }

        targetApplication = nil

        if let errorMessage {
            lastErrorMessage = errorMessage
        } else if clearErrorMessage {
            lastErrorMessage = nil
        }

        state = .idle
        if let errorMessage { overlayController.showError(errorMessage) }
    }

    /// Cancels hands-free mode and presents the "Transcript cancelled" state with an Undo window.
    public func cancelHandsFreeSession() {
        if isVoiceAgentSession {
            teardownSession(clearErrorMessage: true)
            overlayController.showCancelled(durationSeconds: 1.6, allowsUndo: false, message: "Voice Agent cancelled")
            return
        }
        guard state == .listening || state == .processing else { return }

        cancelStreamingSession()

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
                overlayController.update(transcript: transcriptState.partial)
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

        case .voiceAgentShortcut:
            if isVoiceAgentSession && state == .listening { await endDictation() }
            else if state == .idle { await beginVoiceAgent() }

        case .escape:
            if isTypedPlannerSession { cancelTypedPlanner(); return }
            if isVoiceAgentSession {
                teardownSession(clearErrorMessage: true)
                overlayController.showCancelled(durationSeconds: 1.6, allowsUndo: false, message: "Voice Agent cancelled")
                return
            }
            if pendingCommand != nil {
                cancelPendingCommand()
                return
            }
            if isStartingDictation {
                teardownSession(errorMessage: nil, clearErrorMessage: true)
                return
            }
            // "Escape key cancels an active hands-free session outright (discards the recording, no transcription attempt)"
            if sessionMode == .handsFree && (state == .listening || state == .processing) {
                cancelHandsFreeSession()
            } else if state == .listening || state == .processing {
                teardownSession(errorMessage: nil, clearErrorMessage: true)
                overlayController.showCancelled(durationSeconds: 1.6, allowsUndo: false)
            } else {
                invalidateNativePresentation()
                overlayController.dismissTransient()
            }

        case .polishShortcut:
            // Cancel any in-flight dictation triggered accidentally by Option keydown
            if state == .listening || isVoiceAgentSession {
                teardownSession(errorMessage: nil, clearErrorMessage: true)
            }
            await polishActiveSelectionOrRecentDictation()

        case .promptEngineerShortcut:
            if state == .listening || isVoiceAgentSession {
                teardownSession(errorMessage: nil, clearErrorMessage: true)
            }
            await buildPromptFromActiveSelection()
        }
    }

    /// Option + 2 Prompt Engineer. Like Smart Polish, this is selection-only and uses
    /// the same capture, revalidation, and safe replacement transaction.
    public func buildPromptFromActiveSelection() async {
        if isVoiceAgentSession { teardownSession(clearErrorMessage: true) }
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
        if isVoiceAgentSession { teardownSession(clearErrorMessage: true) }
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
                    guard self?.state == .listening, self?.sessionMode == .handsFree, self?.isVoiceAgentSession == false else { return }
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
                    try await Task.sleep(for: .seconds(self?.isVoiceAgentSession == true ? 0.2 : 1))
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard let self, self.state == .listening, self.sessionMode == .handsFree else { return }
                        if self.isVoiceAgentSession {
                            self.voiceAgent.observePause(silenceDurationSeconds: self.audioCapture.continuousSilenceDurationSeconds)
                        } else if self.audioCapture.continuousSilenceDurationSeconds >= 45.0 {
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

    /// Agent traffic is explicit; the ordinary Option/Fn dictation path retains final-only behavior.
    public func beginVoiceAgent() async {
        if isTypedPlannerSession { cancelTypedPlanner(); await voiceAgent.cancelAndWait() }
        agentMemory.reload()
        if let error = agentMemory.error {
            lastErrorMessage = "Repair or reload agent memory in Settings: " + error
            overlayController.showError(lastErrorMessage ?? error)
            return
        }
        guard agentMemory.memory.realTimeEnabled else {
            lastErrorMessage = "Enable real-time agent in Settings → Agent / Mac Control."; return
        }
        guard state == .idle, !isStartingDictation, !isRewritingSelection else { return }
        await beginCapture(mode: .handsFree, agent: true)
    }

    public func beginDictation(mode: DictationSessionMode = .pushToTalk) async {
        if isTypedPlannerSession { cancelTypedPlanner(); await voiceAgent.cancelAndWait() }
        await beginCapture(mode: mode, agent: false)
    }

    private func beginCapture(mode: DictationSessionMode, agent: Bool) async {
        guard !isStartingDictation, !isResettingAgentMemory else { return }
        isStartingDictation = true
        defer { isStartingDictation = false }
        let startID = UUID()
        recordingID = startID
        // A new recording supersedes unconfirmed actions and waits for cancelled native
        // helper ownership before warming it again. It never races a new IPC session.
        if pendingCommand != nil { cancelPendingCommand() }
        let previousNativeTask = nativeActionTask
        invalidateNativePresentation()
        await previousNativeTask?.value
        isVoiceAgentSession = false
#if DEBUG
        cancelRealityPreview()
#endif
        await voiceAgent.cancelAndWait()
        guard recordingID == startID else { return }
        decisionModels.prepareInstalled()
        lastDecisions = nil
        // Guarantee any previous session (or stuck state) is cleanly torn down first.
        if state != .idle {
            teardownSession()
        }
        isVoiceAgentSession = agent
        if agent {
            voiceAgent.onChange = { [weak self] snapshot in self?.presentAgent(snapshot) }
        }
        let recordingID = UUID()
        self.recordingID = recordingID
        transcriptState = TranscriptState()

        // Never capture audio without a real engine — that was producing empty history.
        if !isEngineReady {
            do {
                try await prepareModelsWithError(allowInstallation: false)
            } catch {
                guard self.recordingID == recordingID else { return }
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
        guard self.recordingID == recordingID else { return }

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
            let chunks = try audioCapture.startStreaming(retainRecording: !agent)
            sessionMode = mode
            sessionStartTime = Date()
            overlayController.show(mode: mode, levelsPublisher: audioCapture.$waveformLevels.eraseToAnyPublisher())
            state = .listening
            if agent { voiceAgent.begin() }
            lastErrorMessage = nil
            let startTask = Task { await streamingRouter.start(chunks: chunks) }
            streamingStartTask = startTask
            streamingEventsTask = Task { @MainActor [weak self] in
                let session = await startTask.value
                for await event in session.events {
                    guard !Task.isCancelled, let self, self.recordingID == recordingID else { return }
                    self.transcriptState.apply(event)
                    if case .failed(let message) = event {
                        self.teardownSession(errorMessage: message)
                        return
                    }
                    if self.isVoiceAgentSession, self.state == .listening, case .partial(let partial) = event {
                        if let onset = self.audioCapture.speechOnsetUptime { self.voiceAgent.markSpeechOnset(at: onset) }
                        self.voiceAgent.receive(partial)
                    }
                    if self.state == .listening && !self.isVoiceAgentSession {
                        self.overlayController.update(transcript: self.transcriptState.partial)
                    }
                }
            }

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
        guard state == .listening, let recordingID, let startTask = streamingStartTask else { return }

        // Cancel recording timeouts
        timeoutTask?.cancel()
        timeoutTask = nil
        handsFreeSilenceTask?.cancel()
        handsFreeSilenceTask = nil
        pendingKeyReleaseTask?.cancel()
        pendingKeyReleaseTask = nil

        _ = audioCapture.stop()

        // Silence detection: if no meaningful audio energy was captured for the hold duration,
        // explicitly cancel and tear down the session — do not attempt to transcribe or inject.
        guard audioCapture.hasMeaningfulAudio else {
            teardownSession(errorMessage: "No speech detected.")
            return
        }

        state = .processing
        // Keep the user oriented while the local speech engine and formatter work,
        // then hide this small HUD only after we inject or show the fallback card.
        if isVoiceAgentSession {
            overlayController.updateAgent(transcript: transcriptState.partial, message: OverlayMessage(title: "Finishing speech…", symbol: "ellipsis"), recording: false, phase: .thinking)
        } else { overlayController.showProcessing() }

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
                let session = await startTask.value
                try Task.checkCancellation()
                let result = try await streamingRouter.finish(sessionID: session.id)
                guard !Task.isCancelled, self.recordingID == recordingID else { return }
                transcriptState.apply(.final(result))
                if !isVoiceAgentSession { overlayController.showThinking(message: "Deciding…") }

                // Resolve every operational command against source text. Vocabulary
                // shortcuts belong to dictation, including in legacy single-command capture.
                let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

                // If transcription engine returns empty/near-empty result, explicitly cancel
                guard !trimmed.isEmpty else {
                    teardownSession(errorMessage: "No speech recognized. Try speaking again.")
                    return
                }

                if isVoiceAgentSession {
                    // The final transcript reconciles the incremental ledger instead of re-running
                    // the ordinary single-command/dictation branch or injecting leftover commands.
                    await voiceAgent.finish(FinalTranscript(text: trimmed, confidence: result.confidence, source: result.source, phrases: result.phrases))
                    guard !Task.isCancelled, self.recordingID == recordingID else { return }
                    teardownSession(clearErrorMessage: true, cancelDictationTask: false, preserveOverlay: true, preserveVoiceAgent: true)
                    presentAgent(voiceAgent.snapshot)
                    return
                }

                let sessionCommands = commandMode.withMemory(agentMemory.memory)
                let parsed = sessionCommands.resolve(trimmed, transcriptionConfidence: result.confidence)
                let fallback = try DeterministicDecisionEngine.decisions(for: parsed, isFinal: true)
                let needsSemanticHelp: Bool
                switch parsed {
                case .needsConfirmation: needsSemanticHelp = true
                case .execute(let intent):
                    let action = intent.agentAction
                    needsSemanticHelp = action.toolID == .openApplication
                        && !sessionCommands.isExactApplicationOpen(trimmed, action: action)
                        && !sessionCommands.isConfiguredApplicationOpen(trimmed, action: action)
                case .notCommand: needsSemanticHelp = false
                }
                let decisions = needsSemanticHelp
                    ? await decisionModels.evaluate(DecisionState(text: trimmed, languageCode: NLLanguageRecognizer.dominantLanguage(for: trimmed)?.rawValue ?? "und"), fallback: fallback)
                    : fallback
                guard !Task.isCancelled, self.recordingID == recordingID else { return }
                lastDecisions = decisions
                if let narrow = decisions.narrow, needsSemanticHelp {
                    switch NarrowDecisionPolicy.route(parsed, knownExact: false, isFinal: true, decisions: narrow) {
                    case .parsed: break
                    case .wait, .abstain:
                        teardownSession(errorMessage: "Uncertain or incomplete command. Nothing was sent.")
                        return
                    }
                }
                switch DecisionCommandPolicy.resolve(parsed, decisions: decisions) {
                case .notCommand:
                    overlayController.showThinking(message: "Formatting…")
                    let dictationText = vocabularyStore.apply(to: trimmed)
                    let target = resolvedTargetApplication()
                    let bundleID = target?.bundleIdentifier
                        ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                    let profile = formatter.profile(for: bundleID, applicationName: target?.localizedName)
                    let cleaned = speechCleanup.clean(
                        dictationText,
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
                            "rawLength": trimmed.count,
                            "cleanedLength": cleaned.count,
                            "targetBundle": target?.bundleIdentifier ?? "nil",
                            "frontBundle": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil",
                            "axTrusted": textInjection.isAccessibilityTrusted(prompt: false)
                        ],
                        runId: "post-fix"
                    )
                    // #endregion
                    // Always keep history even when paste/AX insert fails.
                    historyStore.append(text: formatted, bundleIdentifier: bundleID)
                    overlayController.showActing(OverlayMessage(title: target?.localizedName ?? "Dictation", detail: "Sending text…", symbol: "text.cursor"))
                    do {
                        let outcome = try await textInjection.insert(formatted, into: target)
                        guard !Task.isCancelled, self.recordingID == recordingID else { return }
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
                            teardownSession(clearErrorMessage: true, preserveOverlay: true)
                            overlayController.showPolished(message: "Text sent")
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
                        guard !Task.isCancelled, self.recordingID == recordingID else { return }
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
                    teardownSession(clearErrorMessage: true, preserveOverlay: true)
                    executeCommand(intent)
                case .needsConfirmation(let intent):
                    teardownSession(clearErrorMessage: true, preserveOverlay: true)
                    executeCommand(intent, requireConfirmation: true)
                }
            } catch {
                guard !Task.isCancelled, self.recordingID == recordingID else { return }
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

    /// Explicit typed developer requests. Automatic speech fallback is quality-gated separately.
    public var plannerToolSchemas: [PlannerToolSchema] { actionExecutor.registry.plannerSchemas }
    public func canRunTypedRequest(_ goal: String) -> Bool {
        guard !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, state == .idle,
              !isStartingDictation, !isRewritingSelection, typedPlannerTask == nil, !plannerModels.busy else { return false }
        let route = PlannerRouter.route(goal, authoritative: true, enabled: plannerModels.experimentalEnabled, commands: commandMode)
        return route == .direct || route == .planner && plannerModels.resident
    }
    public func runTypedPlanner(goal: String, thinking: Bool = false) {
        guard canRunTypedRequest(goal) else { return }
        isTypedPlannerSession = true
        voiceAgent.onChange = { [weak self] snapshot in self?.presentAgent(snapshot) }
        typedPlannerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.voiceAgent.runPlanner(PlannerRequest(goal: goal, mode: thinking ? .thinking : .nonThinking), provider: self.plannerModels)
            self.typedPlannerTask = nil
        }
    }
    /// Only an explicit UI click renews the bounded planner budget; tool confirmation still applies.
    public func continueTypedPlannerAfterUserApproval() {
        guard isTypedPlannerSession, typedPlannerTask == nil, voiceAgent.snapshot.plannerNeedsContinuation else { return }
        let goal = voiceAgent.snapshot.transcript
        typedPlannerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.voiceAgent.runPlanner(PlannerRequest(goal: goal), provider: self.plannerModels, resumeAfterUserApproval: true)
            self.typedPlannerTask = nil
        }
    }
    public func cancelTypedPlanner() {
        typedPlannerTask?.cancel(); voiceAgent.cancel(); isTypedPlannerSession = false
        Task { await plannerModels.cancelGeneration() }
        lastToolUndo = voiceAgent.snapshot.actions.last(where: { $0.phase == .completed && $0.undo != nil })?.undo
        overlayController.showCancelled(durationSeconds: 1.6, allowsUndo: lastToolUndo != nil, message: "Planner cancelled")
    }
    public func terminateOwnedPlannerProcesses() {
        typedPlannerTask?.cancel(); voiceAgent.cancel(); actionExecutor.registry.terminateOwnedProcesses()
        plannerModels.runtime.terminateImmediately()
    }

    private func presentAgent(_ snapshot: VoiceAgentSnapshot) {
        if let (scenario, expected) = pendingBenchmark,
           snapshot.isCancelled || snapshot.timings.contains(where: { $0.kind == .totalCompletion }) {
            benchmarkResults.append(AgentBenchmarkResult(scenario: scenario, mode: "live-microphone-native-tools", snapshot: snapshot, expected: expected))
            benchmarkResults = Array(benchmarkResults.suffix(100))
            pendingBenchmark = nil
        }
        guard isVoiceAgentSession || isTypedPlannerSession, !snapshot.isCancelled else { return }
        let recording = state == .listening
        let action = snapshot.actions.first(where: { $0.phase == .executing })
            ?? snapshot.actions.first(where: { $0.phase == .stable })
            ?? ((snapshot.isFinal || snapshot.feedbackVisible)
                ? snapshot.actions.last(where: { $0.phase == .completed || $0.phase == .failed }) : nil)
        let phase: OverlayPhase
        let message: OverlayMessage
        if let confirmation = snapshot.confirmation {
            phase = .confirmation
            message = OverlayMessage(title: confirmation.action.summary, detail: snapshot.notice.isEmpty ? "Confirm this action?" : snapshot.notice, symbol: "hand.raised")
        } else if snapshot.plannerActive {
            phase = action?.phase == .executing ? .acting : .thinking
            message = OverlayMessage(title: action?.phase == .executing ? action!.action.summary : snapshot.notice,
                detail: snapshot.plannerProgress, symbol: "gearshape")
        } else if isTypedPlannerSession, snapshot.notice == "Planner finished" {
            phase = .success
            message = OverlayMessage(title: "Planner finished", detail: snapshot.actions.contains(where: { $0.verification != .verified }) ? "Some requests remain unverified" : "Actions complete", symbol: "checkmark.circle.fill")
        } else if !snapshot.notice.isEmpty, snapshot.isFinal {
            phase = .error
            message = OverlayMessage(title: "Check instruction", detail: snapshot.notice, symbol: "exclamationmark.triangle.fill")
        } else if let action {
            switch action.phase {
            case .executing: phase = .acting
            case .failed: phase = .error
            case .completed: phase = .success
            default: phase = .thinking
            }
            let verified = action.verification == .verified
            let detail = action.phase == .executing ? "Running…" : (action.phase == .completed && !verified ? "Request sent · unverified" : action.detail)
            message = OverlayMessage(title: action.action.summary, detail: detail, symbol: action.phase == .completed && verified ? "checkmark.circle.fill" : "gearshape")
        } else {
            phase = snapshot.notice.isEmpty ? (recording ? .handsFree : .thinking) : .error
            message = OverlayMessage(title: snapshot.notice.isEmpty ? "Voice Agent" : "Couldn’t resolve instruction", detail: snapshot.notice.isEmpty ? "Listening for commands…" : snapshot.notice, symbol: "waveform")
        }
        lastToolUndo = !recording && snapshot.confirmation == nil ? action?.undo : nil
        overlayController.updateAgent(transcript: PartialTranscript(text: snapshot.transcript), message: message,
                                      recording: recording, phase: phase, allowsUndo: lastToolUndo != nil)
    }

    /// Feedback before execution; the typed result supplies truthful terminal feedback.
    private func actionPresentation(for intent: CommandIntent, confirmation: Bool = false) -> OverlayMessage {
        let title: String
        let verb: String
        let symbol: String
        switch intent {
        case .nativeAction(let action): (title, verb, symbol) = (action.summary, "Running", "gearshape")
        case .openApplication(let app): (title, verb, symbol) = (app.name, "Opening", "app")
        case .switchToApplication(let app): (title, verb, symbol) = (app.name, "Switching to", "app")
        case .quitApplication(let app): (title, verb, symbol) = (app.name, "Quitting", "app")
        case .openURL(let url): (title, verb, symbol) = (url.host ?? "Website", "Opening", "globe")
        case .searchWeb(_, let provider, _): (title, verb, symbol) = (provider, "Searching", "magnifyingglass")
        case .spotifySearchAndPlay: (title, verb, symbol) = ("Spotify", "Opening", "music.note")
        case .spotifyControl(let action):
            title = "Spotify"
            symbol = "music.note"
            switch action {
            case .resume: verb = "Resuming"
            case .pause: verb = "Pausing"
            case .next: verb = "Skipping track"
            case .previous: verb = "Going to previous track"
            }
        case .mute: (title, verb, symbol) = ("System audio", "Muting", "speaker.slash")
        case .unmute: (title, verb, symbol) = ("System audio", "Unmuting", "speaker.wave.2")
        case .sleepDisplay: (title, verb, symbol) = ("Display", "Sleeping", "display")
        case .lockScreen: (title, verb, symbol) = ("This Mac", "Locking", "lock")
        }
        return OverlayMessage(title: title, detail: confirmation ? "\(verb) \(title). Continue?" : "\(verb)…", symbol: symbol)
    }

    /// Immediately invalidates UI/injection ownership; actor cleanup cannot cancel a newer session.
    private func cancelStreamingSession() {
        recordingID = nil
        transcriptState = TranscriptState()
        streamingEventsTask?.cancel()
        streamingEventsTask = nil
        if let startTask = streamingStartTask {
            startTask.cancel()
            Task {
                let session = await startTask.value
                await streamingRouter.cancel(sessionID: session.id)
            }
        }
        streamingStartTask = nil
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
