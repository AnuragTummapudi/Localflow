import AppKit
import SwiftUI
import Combine

/// Displays a floating card with transcribed text when dictation completes without a focused text target.
@MainActor
public final class FloatingResultCardController {
    private var window: NSPanel?
    private var dismissTask: Task<Void, Never>?
    private let autoDismissDuration: TimeInterval = 12.0
    private let copiedDismissDuration: TimeInterval = 1.0

    /// Creates a floating result card controller.
    public init() {}

    /// Shows the floating result card at the same bottom-center anchor as the listening pill.
    public func show(text: String, status: String = "No text field selected", persistent: Bool = false) {
        dismissTask?.cancel()

        let view = FloatingResultCardView(
            text: text,
            status: status,
            onCopy: { [weak self] in
                // Keep the confirmation visible long enough to be read, then remove the card.
                self?.scheduleDismiss(after: self?.copiedDismissDuration ?? 1.0)
            },
            onClose: { [weak self] in
                self?.hide()
            }
        )

        let hosting = NSHostingController(rootView: view)
        let cardSize = CGSize(
            width: FloatingResultCardView.cardWidth,
            height: FloatingResultCardView.cardHeight(for: text)
        )

        let panel = ensurePanel(contentViewController: hosting, size: cardSize)
        positionAtBottomCenter(panel, size: cardSize)
        panel.orderFrontRegardless()

        if !persistent { scheduleDismiss(after: autoDismissDuration) }
    }

    /// Hides the card and cancels pending timers.
    public func hide() {
        dismissTask?.cancel()
        dismissTask = nil
        window?.orderOut(nil)
    }

    private func scheduleDismiss(after seconds: TimeInterval) {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.hide()
            } catch {}
        }
    }

    private func ensurePanel(contentViewController: NSViewController, size: CGSize) -> NSPanel {
        if let existing = window {
            existing.contentViewController = contentViewController
            existing.setContentSize(size)
            return existing
        }

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentViewController = contentViewController
        panel.setContentSize(size)
        self.window = panel
        return panel
    }

    private func positionAtBottomCenter(_ panel: NSPanel, size: CGSize) {
        let mouse = NSEvent.mouseLocation
        let screens = NSScreen.screens
        // NSScreen.main is often the built-in display even while the user is working
        // in a full-screen app or on an external display. Anchor to the active pointer
        // display first so the fallback card stays at the bottom of the active workspace.
        let targetScreen = screens.first(where: { NSPointInRect(mouse, $0.frame) }) ?? NSScreen.main ?? screens.first
        guard let screen = targetScreen else {
            return
        }
        let frame = screen.visibleFrame
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + 12
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}
