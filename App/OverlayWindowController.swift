import AppKit
import SwiftUI
import Combine
import Shared

/// Shows the floating listening pill while dictation is active.
///
/// Reuses a single nonactivating panel (create-once) so subsequent hotkey
/// presses remain reliable — tearing down/recreating the panel caused missed
/// shows and AppKit layout warnings.
@MainActor
public final class OverlayWindowController {
    private var window: NSPanel?
    private let model = WaveformOverlayModel()
    private var levelsCancellable: AnyCancellable?
    private var terminalDismissTask: Task<Void, Never>?

    /// Callbacks invoked when interactive overlay buttons are tapped.
    public var onCancel: (() -> Void)? {
        get { model.onCancel }
        set { model.onCancel = newValue }
    }

    public var onFinishAndPaste: (() -> Void)? {
        get { model.onFinishAndPaste }
        set { model.onFinishAndPaste = newValue }
    }

    public var onUndo: (() -> Void)? {
        get { model.onUndo }
        set { model.onUndo = newValue }
    }

    /// Creates an overlay controller.
    public init() {}

    /// Shows the listening pill and begins observing waveform levels.
    public func show(mode: DictationSessionMode = .pushToTalk, levelsPublisher: AnyPublisher<[Float], Never>) {
        cancelTerminalDismissal()
        levelsCancellable?.cancel()
        model.resetCancellation()
        model.mode = mode
        model.pillState = .listening
        model.update(levels: Array(repeating: 0.15, count: WaveformOverlayModel.barCount))

        let size = mode == .handsFree ? LocalFlowDesign.handsFreeWindowSize : LocalFlowDesign.overlaySize
        let panel = ensurePanel(size: size)
        panel.ignoresMouseEvents = (mode == .pushToTalk)
        panel.setContentSize(size)
        position(panel, size: size)
        panel.orderFrontRegardless()

        levelsCancellable = levelsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] levels in
                self?.model.update(levels: levels)
            }
    }

    /// Convenience for one-shot initial levels without a live publisher.
    public func show(mode: DictationSessionMode = .pushToTalk, levels: [Float]) {
        model.mode = mode
        model.update(levels: levels)
        show(mode: mode, levelsPublisher: Just(levels).eraseToAnyPublisher())
    }

    /// Displays the "Transcript cancelled" state with Undo button and animated progress bar.
    public func showCancelled(durationSeconds: Double = 3.5, onDismiss: @escaping () -> Void) {
        cancelTerminalDismissal()
        levelsCancellable?.cancel()
        levelsCancellable = nil

        let size = LocalFlowDesign.cancelledPillSize
        let panel = ensurePanel(size: size)
        panel.ignoresMouseEvents = false
        panel.setContentSize(size)
        position(panel, size: size)
        panel.orderFrontRegardless()

        model.triggerCancelled(durationSeconds: durationSeconds) { [weak self] in
            self?.hide()
            onDismiss()
        }
    }

    /// Displays the "Polished ✨" state at the bottom center of the screen (same anchor as speaking pill).
    public func showPolished(message: String = "Polished", durationSeconds: Double = 1.6) {
        showTerminal(message: message, kind: .success, durationSeconds: durationSeconds)
    }

    public func showNoChanges() { showTerminal(message: "Already clean", kind: .unchanged, durationSeconds: 1.8) }
    public func showError(_ message: String) { showTerminal(message: message, kind: .error, durationSeconds: 3.0) }
    public func showPolishing(message: String = "Rewriting privately on this Mac…") { showWorking(state: .polishing, message: message) }

    private func showTerminal(message: String, kind: WaveformOverlayModel.TerminalKind, durationSeconds: Double) {
        levelsCancellable?.cancel()
        levelsCancellable = nil
        cancelTerminalDismissal()

        model.resetAll()
        model.isPolished = true
        model.polishMessage = message
        model.pillState = .terminal(kind)

        let size = LocalFlowDesign.polishPillSize(for: message)
        let panel = ensurePanel(size: size)
        panel.ignoresMouseEvents = true
        panel.setContentSize(size)
        position(panel, size: size)
        panel.orderFrontRegardless()

        terminalDismissTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(durationSeconds * 1_000_000_000)) } catch { return }
            guard let self, self.model.pillState == .terminal(kind) else { return }
            self.hide()
        }
    }

    /// Keeps a compact progress indicator visible between recording and insertion.
    public func showProcessing() {
        showWorking(state: .transcribing, message: "Transcribing")
    }

    private func showWorking(state: WaveformOverlayModel.PillState, message: String) {
        cancelTerminalDismissal()
        levelsCancellable?.cancel()
        levelsCancellable = nil

        model.resetAll()
        model.isProcessing = true
        model.pillState = state
        model.polishMessage = message

        let size = LocalFlowDesign.processingPillSize(for: message)
        let panel = ensurePanel(size: size)
        panel.ignoresMouseEvents = true
        panel.setContentSize(size)
        position(panel, size: size)
        panel.orderFrontRegardless()
    }

    /// Hides the overlay without destroying the panel (keeps it ready for reuse).
    public func hide() {
        cancelTerminalDismissal()
        levelsCancellable?.cancel()
        levelsCancellable = nil
        model.resetAll()
        window?.orderOut(nil)
    }

    // MARK: - Private

    private func ensurePanel(size: CGSize) -> NSPanel {
        if let window {
            return window
        }

        let hosting = NSHostingController(rootView: WaveformOverlayView(model: model))
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // A status-bar-level panel may remain behind a different application's native
        // full-screen window. screenSaver is the standard non-key overlay level that stays
        // visible across full-screen Spaces without activating LocalFlow.
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentViewController = hosting
        panel.setContentSize(size)
        self.window = panel
        return panel
    }

    private func position(_ panel: NSPanel, size: CGSize) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSPointInRect(mouse, $0.frame) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        // `visibleFrame` stops above the Dock and leaves the pill visually stranded on
        // larger screens. Use the full display frame so this stays anchored to the actual
        // bottom edge, including while the frontmost app is full screen.
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1470, height: 956)
        let origin = NSPoint(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.minY + 12
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func cancelTerminalDismissal() {
        terminalDismissTask?.cancel()
        terminalDismissTask = nil
    }
}
