import AppKit
import SwiftUI
import Combine
import Shared

/// One reusable, nonactivating island for recording, decisions and action feedback.
@MainActor
public final class OverlayWindowController {
    private var window: IslandPanel?
    private let model = WaveformOverlayModel()
    private var levelsCancellable: AnyCancellable?
    private var dismissalTask: Task<Void, Never>?
    private var screenObserver: (any NSObjectProtocol)?
    private var anchoredScreen: NSScreen?
    private var presentationID = UUID()

    public var onCancel: (() -> Void)? { get { model.onCancel } set { model.onCancel = newValue } }
    public var onFinishAndPaste: (() -> Void)? { get { model.onFinishAndPaste } set { model.onFinishAndPaste = newValue } }
    public var onUndo: (() -> Void)? { get { model.onUndo } set { model.onUndo = newValue } }
    public var onConfirm: (() -> Void)? { get { model.onConfirm } set { model.onConfirm = newValue } }
    public var isConfirming: Bool { model.presentation.phase == .confirmation }
    public var currentPresentationID: UUID { presentationID }
    public var supportsCancellationUndo: Bool { model.presentation.phase == .cancelled && model.presentation.showsUndo }

    public init() {
        model.onDismiss = { [weak self] in self?.hide() }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.layout() }
        }
    }

    deinit {
        dismissalTask?.cancel()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    public func show(mode: DictationSessionMode = .pushToTalk, levelsPublisher: AnyPublisher<[Float], Never>) {
        beginPresentation()
        model.listen(mode: mode)
        model.update(levels: Array(repeating: 0.15, count: WaveformOverlayModel.barCount))
        layout(resetWidth: true)
        reveal()
        levelsCancellable = levelsPublisher
            .receive(on: RunLoop.main)
            .throttle(for: .milliseconds(16), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] in self?.model.update(levels: $0) }
    }

    public func show(mode: DictationSessionMode = .pushToTalk, levels: [Float]) {
        show(mode: mode, levelsPublisher: Just(levels).eraseToAnyPublisher())
    }

    public func update(transcript: PartialTranscript?) {
        if model.update(transcript: transcript) { layout() }
    }

    /// Update the existing panel without dropping waveform subscriptions or recording controls.
    public func updateAgent(transcript: PartialTranscript?, message: OverlayMessage?, recording: Bool,
                            phase: OverlayPhase, allowsUndo: Bool = false) {
        dismissalTask?.cancel(); dismissalTask = nil
        if !recording { levelsCancellable?.cancel(); levelsCancellable = nil }
        model.agent(transcript: transcript, message: message, recording: recording, phase: phase, allowsUndo: allowsUndo)
        layout(); reveal()
        if !recording, phase == .success || phase == .error || phase == .cancelled {
            dismiss(after: allowsUndo ? 8 : (phase == .error ? 6 : 3))
        }
    }

    public func showProcessing() { showThinking(message: "Transcribing…") }
    public func showThinking(message: String = "Deciding…", detail: String = "") {
        present(.thinking, message: OverlayMessage(title: message, detail: detail, symbol: "ellipsis"))
    }
    public func showPolishing(message: String = "Rewriting privately on this Mac…") {
        showThinking(message: message)
    }
    public func showActing(_ message: OverlayMessage, durationSeconds: Double? = nil) {
        present(.acting, message: message)
        if let durationSeconds { dismiss(after: durationSeconds) }
    }
    public func showConfirmation(_ message: OverlayMessage) {
        present(.confirmation, message: message)
    }
    public func showPolished(message: String = "Done", durationSeconds: Double = 1.6) {
        present(.success, message: OverlayMessage(title: message, symbol: "checkmark.circle.fill"))
        dismiss(after: durationSeconds)
    }
    public func showToolResult(message: String, verified: Bool, allowsUndo: Bool) {
        present(.success, message: OverlayMessage(title: message, detail: verified ? "" : "Request sent · unverified",
                                                  symbol: verified ? "checkmark.circle.fill" : "arrow.up.right.circle"), allowsUndo: allowsUndo)
        dismiss(after: allowsUndo ? 8 : 3)
    }
    public func showNoChanges() { showPolished(message: "Already clean", durationSeconds: 1.8) }
    public func showError(_ message: String) {
        present(.error, message: OverlayMessage(title: "Couldn’t finish", detail: message, symbol: "exclamationmark.triangle.fill"))
        dismiss(after: 6)
    }

    /// Retains the existing 3.5 second Undo window; monotonic time avoids clock changes.
    public func showCancelled(durationSeconds: Double = 3.5, allowsUndo: Bool = true, message: String = "Transcript cancelled", onDismiss: @escaping () -> Void = {}) {
        present(.cancelled, message: OverlayMessage(title: message, symbol: "xmark.circle"), allowsUndo: allowsUndo)
        let id = presentationID
        dismissalTask = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            let start = clock.now
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(32)) } catch { return }
                guard let self, self.presentationID == id else { return }
                let elapsed = start.duration(to: clock.now)
                let components = elapsed.components
                let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
                self.model.cancelProgress = max(0, 1 - seconds / max(0.01, durationSeconds))
                if seconds >= durationSeconds {
                    self.hide()
                    onDismiss()
                    return
                }
            }
        }
    }

    public func hide() {
        beginPresentation()
        model.hide()
        window?.orderOut(nil)
        anchoredScreen = nil
    }

    /// Dismiss idle feedback with Escape without interrupting a real recording.
    public func dismissTransient() {
        if !model.presentation.phase.isRecording { hide() }
    }

    private func present(_ phase: OverlayPhase, message: OverlayMessage, allowsUndo: Bool = false) {
        beginPresentation()
        model.present(phase, message: message, allowsUndo: allowsUndo)
        layout(resetWidth: true)
        reveal()
    }

    private func beginPresentation() {
        presentationID = UUID()
        dismissalTask?.cancel()
        dismissalTask = nil
        levelsCancellable?.cancel()
        levelsCancellable = nil
    }

    private func dismiss(after seconds: Double) {
        let id = presentationID
        dismissalTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(max(0.01, seconds))) } catch { return }
            guard let self, self.presentationID == id else { return }
            self.hide()
        }
    }

    private func reveal() {
        guard let window, anchoredScreen != nil else { return }
        window.ignoresMouseEvents = model.presentation.phase == .thinking || model.presentation.phase == .acting
        window.orderFrontRegardless()
    }

    private func screen() -> NSScreen? {
        if let anchoredScreen, NSScreen.screens.contains(where: { $0 == anchoredScreen }) { return anchoredScreen }
        let mouse = NSEvent.mouseLocation
        let selected = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main ?? NSScreen.screens.first
        anchoredScreen = selected
        return selected
    }

    private func layout(resetWidth: Bool = false) {
        guard model.presentation.phase != .hidden, let screen = screen() else { return }
        let state = model.presentation
        let text = state.phase.isRecording ? String((state.transcript?.text ?? "Listening…").suffix(240)) : state.message.title
        let font = NSFont(name: "Matter-Medium", size: 13.5) ?? .systemFont(ofSize: 13.5, weight: .medium)
        let titleWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        let detailWidth = ceil((String(state.message.detail.prefix(240)) as NSString).size(withAttributes: [.font: font]).width)
        let desired = OverlayLayout.width(textWidth: max(titleWidth, detailWidth), phase: state.phase, screenWidth: screen.frame.width)
        let limit = OverlayLayout.width(textWidth: .greatestFiniteMagnitude, phase: state.phase, screenWidth: screen.frame.width)
        let width = state.phase.isRecording && !resetWidth ? min(limit, max(model.surfaceSize.width, desired)) : desired
        let baseHeight: CGFloat = state.agentMessage != nil ? 64 : (state.phase == .confirmation ? 96 : (state.phase == .error ? 72 : (state.phase.isRecording ? 48 : 52)))
        let height = baseHeight + (!state.phase.isRecording && state.transcript != nil ? 20 : 0)
        model.surfaceSize = CGSize(width: width, height: height)
        let size = CGSize(width: width + 2 * OverlayLayout.shadowInset, height: height + 2 * OverlayLayout.shadowInset)
        let panel = ensurePanel(size: size)
        let frame = OverlayLayout.panelFrame(
            size: size, screenFrame: screen.frame, visibleFrame: screen.visibleFrame, safeTop: screen.safeAreaInsets.top,
            left: screen.auxiliaryTopLeftArea, right: screen.auxiliaryTopRightArea
        )
        // SwiftUI handles the restrained spring. Frame changes themselves remain direct
        // so hit testing always matches the visible capsule and never covers the menu bar.
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    private func ensurePanel(size: CGSize) -> IslandPanel {
        if let window { return window }
        let panel = IslandPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.title = "LocalFlow Island"
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true
        let hosting = IslandHostingView(rootView: WaveformOverlayView(model: model))
        hosting.sizingOptions = []
        panel.contentView = hosting
        self.window = panel
        return panel
    }
}

/// Even clicking Stop/Confirm must leave the foreground application's keyboard focus intact.
private final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class IslandHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { false }
    override var acceptsFirstResponder: Bool { false }
}
