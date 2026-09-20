import AppKit
import SwiftUI
import Shared

/// Floating result card displayed when dictation completes without a focused text target,
/// or when reviewing polished text. Supports native Apple Intelligence Writing Tools on macOS 15+.
public struct FloatingResultCardView: View {
    public static let cardWidth: CGFloat = 350
    private static let cardChromeHeight: CGFloat = 112

    public static func previewHeight(for text: String) -> CGFloat {
        let font = NSFont(name: "GeneralSans-Regular", size: 14) ?? NSFont.systemFont(ofSize: 14)
        let measured = (text as NSString).boundingRect(
            with: NSSize(width: 318, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        ).height
        return min(280, max(80, ceil(measured) + 12))
    }

    public static func cardHeight(for text: String) -> CGFloat {
        cardChromeHeight + previewHeight(for: text)
    }

    public let text: String
    public let status: String
    public let onCopy: () -> Void
    public let onClose: () -> Void

    private let previewHover: Bool?
    @State private var isHovered = false
    @State private var isCopied = false
    @State private var currentText: String
    @State private var triggerWritingToolsAction: (() -> Void)? = nil

    public init(
        text: String,
        status: String = "No text field selected",
        previewHover: Bool? = nil,
        onCopy: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.text = text
        self.status = status
        self._currentText = State(initialValue: text)
        self.previewHover = previewHover
        self.onCopy = onCopy
        self.onClose = onClose
    }

    private var effectiveHover: Bool {
        previewHover ?? isHovered
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header: resolved waveform mark + status text, and hover-revealed close button
            HStack(alignment: .center, spacing: 8) {
                ResolvedWaveform()
                    .fill(LocalFlowDesign.signal)
                    .frame(width: 20, height: 14)

                Text(status)
                    .font(LocalFlowDesign.generalSans(size: 12, weight: .medium))
                    .foregroundStyle(LocalFlowDesign.graphite)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(LocalFlowDesign.graphite)
                        .frame(width: 20, height: 20)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(effectiveHover ? 0.12 : 0))
                        )
                }
                .buttonStyle(.plain)
                .opacity(effectiveHover ? 1.0 : 0.0)
                .animation(.easeInOut(duration: 0.18), value: effectiveHover)
                .help("Close")
            }

            // Body: Selectable text with Apple Intelligence Writing Tools support
            WritingToolsCardTextView(
                text: $currentText,
                onWritingToolsTriggerReady: { trigger in
                    self.triggerWritingToolsAction = trigger
                }
            )
            .frame(height: Self.previewHeight(for: currentText))

            // Bottom row: "Writing Tools (Apple Intelligence)" + pill-shaped "Copy" button
            HStack(spacing: 8) {
                if #available(macOS 15.2, *) {
                    Button(action: {
                        triggerWritingToolsAction?()
                    }) {
                        HStack(spacing: 5) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(LocalFlowDesign.signal)
                            Text("Writing Tools")
                                .font(LocalFlowDesign.generalSans(size: 12, weight: .medium))
                                .foregroundStyle(Color.white)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.white.opacity(0.10))
                                .overlay(
                                    Capsule(style: .continuous)
                                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Open Apple Intelligence Writing Tools (Rewrite, Proofread, Tone)")
                }

                Spacer()

                Button(action: handleCopy) {
                    HStack(spacing: 5) {
                        if isCopied {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Copied")
                                .font(LocalFlowDesign.generalSans(size: 12, weight: .medium))
                        } else {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 11, weight: .regular))
                            Text("Copy")
                                .font(LocalFlowDesign.generalSans(size: 12, weight: .medium))
                        }
                    }
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .background(
                        Capsule(style: .continuous)
                            .fill(isCopied ? Color(red: 0.18, green: 0.70, blue: 0.38) : LocalFlowDesign.signal)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(width: Self.cardWidth)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LocalFlowDesign.canvasDark)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: Color.black.opacity(0.38), radius: 16, x: 0, y: 6)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.18)) {
                isHovered = hovering
            }
        }
    }

    private func handleCopy() {
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.string], owner: nil)
        guard pasteboard.setString(currentText, forType: .string) else { return }

        // Update before scheduling dismissal so the user always receives a clear result.
        isCopied = true
        onCopy()
    }
}

/// AppKit NSTextView wrapper that configures Apple Intelligence Writing Tools behavior.
private struct WritingToolsCardTextView: NSViewRepresentable {
    @Binding var text: String
    var onWritingToolsTriggerReady: (@escaping () -> Void) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.drawsBackground = false
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 320, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView
        textView.isEditable = true
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textColor = NSColor(LocalFlowDesign.inkDark)
        textView.font = NSFont(name: "GeneralSans-Regular", size: 14) ?? NSFont.systemFont(ofSize: 14)
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.string = text
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.delegate = context.coordinator

        if #available(macOS 15.0, *) {
            textView.writingToolsBehavior = .complete
        }

        DispatchQueue.main.async {
            textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
            self.onWritingToolsTriggerReady { [weak textView] in
                guard let textView else { return }
                if #available(macOS 15.2, *) {
                    // Select all text if nothing is selected so Writing Tools acts on the whole content
                    if textView.selectedRange().length == 0 {
                        textView.selectAll(nil)
                    }
                    textView.showWritingTools(nil)
                }
            }
        }

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: WritingToolsCardTextView

        init(_ parent: WritingToolsCardTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}
