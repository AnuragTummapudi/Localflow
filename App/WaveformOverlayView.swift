import AppKit
import SwiftUI
import Shared

/// Live waveform levels driving the listening pill bars.
@MainActor
public final class WaveformOverlayModel: ObservableObject {
    public enum PillState: Equatable { case listening, transcribing, polishing, terminal(TerminalKind), cancelled }
    public enum TerminalKind: Equatable { case success, unchanged, error }
    public static let barCount = 11
    private static let envelope: [CGFloat] = [0.42, 0.60, 0.78, 0.92, 0.98, 1.00, 0.98, 0.92, 0.78, 0.60, 0.42]

    /// Normalized bar heights in 0…1 (left → right), 11 bars.
    @Published public var levels: [CGFloat] = Array(repeating: 0.15, count: 11)

    /// The active session mode (push-to-talk vs. locked hands-free).
    @Published public var mode: DictationSessionMode = .pushToTalk

    /// Whether the session is in the "Transcript cancelled" undo state.
    @Published public var isCancelled: Bool = false

    /// Whether the session is in the "Polished" state.
    @Published public var isPolished: Bool = false

    /// Whether recorded audio is being transcribed before insertion.
    @Published public var isProcessing: Bool = false
    @Published public var pillState: PillState = .listening

    /// Message to display in the polish state.
    @Published public var polishMessage: String = "Polished"

    /// Progress ratio (1.0 down to 0.0) for the cancellation countdown line.
    @Published public var cancelProgress: Double = 1.0

    /// Callbacks triggered from interactive buttons.
    public var onCancel: (() -> Void)?
    public var onFinishAndPaste: (() -> Void)?
    public var onUndo: (() -> Void)?

    private var countdownTask: Task<Void, Never>?

    /// Creates a waveform model.
    public init() {}

    /// Updates bars from microphone waveform samples.
    public func update(levels raw: [Float]) {
        guard !raw.isEmpty else {
            levels = Array(repeating: 0.15, count: Self.barCount)
            return
        }
        var next: [CGFloat] = []
        next.reserveCapacity(Self.barCount)
        for index in 0..<Self.barCount {
            let src = raw[index % raw.count]
            let env = Self.envelope[index]
            // Keep a visible idle floor so bars still breathe naturally between syllables.
            let boosted = min(1.0, max(0.12, CGFloat(src) * 1.45 + 0.10)) * env
            next.append(boosted)
        }
        // Light smoothing against the previous frame to keep waves fluid and professional.
        if levels.count == next.count {
            levels = zip(levels, next).map { prev, neu in prev * 0.40 + neu * 0.60 }
        } else {
            levels = next
        }
    }

    /// Triggers the "Transcript cancelled" countdown timer.
    public func triggerCancelled(durationSeconds: Double = 3.5, onDismiss: @escaping () -> Void) {
        countdownTask?.cancel()
        isCancelled = true
        pillState = .cancelled
        cancelProgress = 1.0

        let startTime = Date()
        countdownTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 30_000_000)
                } catch {
                    break
                }
                guard !Task.isCancelled, let self else { break }
                let elapsed = Date().timeIntervalSince(startTime)
                let remaining = max(0.0, 1.0 - (elapsed / durationSeconds))
                self.cancelProgress = remaining
                if remaining <= 0.0 {
                    self.countdownTask = nil
                    onDismiss()
                    break
                }
            }
        }
    }

    /// Resets from the cancelled state back to active.
    public func resetCancellation() {
        countdownTask?.cancel()
        countdownTask = nil
        isCancelled = false
        pillState = .listening
        cancelProgress = 1.0
    }

    /// Resets all temporary states (cancelled, polished) back to active.
    public func resetAll() {
        countdownTask?.cancel()
        countdownTask = nil
        isCancelled = false
        isPolished = false
        isProcessing = false
        pillState = .listening
        cancelProgress = 1.0
    }
}

/// Floating listening pill with rhythmic voice-reactive waveform bars, hands-free controls, and cancellation states.
public struct WaveformOverlayView: View {
    @ObservedObject public var model: WaveformOverlayModel

    @State private var hoveredButton: HoveredButton? = nil
    @State private var isCancelHovered = false
    @State private var isFinishHovered = false
    @State private var isUndoHovered = false

    public enum HoveredButton: Equatable, Sendable {
        case cancel
        case finish
    }

    private var initialHover: HoveredButton? = nil

    /// Creates the listening overlay.
    public init(model: WaveformOverlayModel, initialHover: HoveredButton? = nil) {
        self.model = model
        self.initialHover = initialHover
    }

    public var body: some View {
        Group {
            if model.pillState == .transcribing || model.pillState == .polishing {
                processingView
            } else if case .terminal = model.pillState {
                polishedView
            } else if model.pillState == .cancelled {
                cancelledView
            } else if model.mode == .handsFree {
                handsFreeView
            } else {
                pushToTalkView
            }
        }
    }

    // MARK: - Hands-Free Mode (Wispr Flow style)

    private var handsFreeView: some View {
        let effectiveHover = hoveredButton ?? initialHover
        let isCancelActive = isCancelHovered || effectiveHover == .cancel
        let isFinishActive = isFinishHovered || effectiveHover == .finish

        return VStack(spacing: 8) {
            // Floating hover tooltip pill
            HStack {
                if effectiveHover == .cancel {
                    tooltipPill("Cancel")
                        .padding(.leading, -12)
                    Spacer(minLength: 0)
                } else if effectiveHover == .finish {
                    Spacer(minLength: 0)
                    tooltipPill("Finish and paste")
                        .padding(.trailing, -28)
                }
            }
            .frame(width: LocalFlowDesign.handsFreePillSize.width, height: 28)
            .animation(.easeInOut(duration: 0.12), value: effectiveHover)

            // Main hands-free pill
            HStack(alignment: .center, spacing: 10) {
                // Circular Cancel button
                Button(action: { model.onCancel?() }) {
                    ZStack {
                        Circle()
                            .fill(isCancelActive ? Color.white.opacity(0.28) : Color.white.opacity(0.18))
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.white)
                    }
                    .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .onHover { isHovered in
                    isCancelHovered = isHovered
                    withAnimation(.easeInOut(duration: 0.12)) {
                        if isHovered {
                            hoveredButton = .cancel
                        } else if hoveredButton == .cancel {
                            hoveredButton = nil
                        }
                    }
                }

                // Clean 11-bar waveform
                HStack(alignment: .center, spacing: 2.6) {
                    ForEach(Array(model.levels.enumerated()), id: \.offset) { _, level in
                        Capsule(style: .continuous)
                            .fill(Color.white)
                            .frame(width: 2.8, height: max(4, level * 20))
                    }
                }
                .frame(width: 60)

                // Circular Finish & Paste button
                Button(action: { model.onFinishAndPaste?() }) {
                    ZStack {
                        Circle()
                            .fill(Color.white)
                            .opacity(isFinishActive ? 0.92 : 1.0)
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color(red: 0.08, green: 0.08, blue: 0.10))
                    }
                    .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .onHover { isHovered in
                    isFinishHovered = isHovered
                    withAnimation(.easeInOut(duration: 0.12)) {
                        if isHovered {
                            hoveredButton = .finish
                        } else if hoveredButton == .finish {
                            hoveredButton = nil
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .frame(width: LocalFlowDesign.handsFreePillSize.width, height: LocalFlowDesign.handsFreePillSize.height)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(red: 0.08, green: 0.08, blue: 0.09).opacity(0.96))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    )
            )
            .shadow(color: Color.black.opacity(0.35), radius: 14, y: 6)
        }
        .frame(width: LocalFlowDesign.handsFreeWindowSize.width, height: LocalFlowDesign.handsFreeWindowSize.height, alignment: .bottom)
        .accessibilityLabel("Hands-free recording")
        .animation(.easeOut(duration: 0.08), value: model.levels)
    }

    private func tooltipPill(_ text: String) -> some View {
        Text(text)
            .font(LocalFlowDesign.generalSans(size: 13, weight: .regular))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(red: 0.08, green: 0.08, blue: 0.09).opacity(0.96))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                    )
            )
            .shadow(color: Color.black.opacity(0.35), radius: 8, y: 3)
    }

    // MARK: - "Polished ✨" State (Option + 1)

    private var processingView: some View {
        HStack(spacing: 9) {
            ProgressView()
                .controlSize(.small)
                .tint(Color.white)

            Text(model.polishMessage)
                .font(LocalFlowDesign.generalSans(size: 13, weight: .medium))
                .foregroundStyle(Color.white)
        }
        .padding(.horizontal, 16)
        .frame(width: LocalFlowDesign.processingPillSize.width, height: LocalFlowDesign.processingPillSize.height)
        .background(
            Capsule(style: .continuous)
                .fill(Color(red: 0.08, green: 0.08, blue: 0.09).opacity(0.96))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
        .shadow(color: Color.black.opacity(0.35), radius: 14, y: 6)
        .accessibilityLabel("Transcribing your dictation")
    }

    private var polishedView: some View {
        let isError: Bool = { if case .terminal(.error) = model.pillState { return true }; return false }()
        let isUnchanged: Bool = { if case .terminal(.unchanged) = model.pillState { return true }; return false }()
        return HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : (isUnchanged ? "checkmark.circle" : "sparkles"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isError ? LocalFlowDesign.destructiveRed : LocalFlowDesign.signal)

            Text(model.polishMessage)
                .font(LocalFlowDesign.generalSans(size: 13.5, weight: .medium))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(Color.white)

            Image(systemName: isError ? "xmark" : "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(isError ? LocalFlowDesign.destructiveRed : LocalFlowDesign.signal)
        }
        .padding(.horizontal, 16)
        .frame(width: LocalFlowDesign.polishPillSize.width, height: LocalFlowDesign.polishPillSize.height)
        .background(
            Capsule(style: .continuous)
                .fill(Color(red: 0.08, green: 0.08, blue: 0.09).opacity(0.96))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
        .shadow(color: Color.black.opacity(0.35), radius: 14, y: 6)
        .accessibilityLabel(model.polishMessage)
    }

    // MARK: - "Transcript cancelled" State with Undo & Progress Countdown

    private var cancelledView: some View {
        ZStack(alignment: .bottomLeading) {
            HStack(spacing: 10) {
                Text("Transcript cancelled")
                    .font(LocalFlowDesign.generalSans(size: 13.5, weight: .medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(Color.white)

                Spacer(minLength: 8)

                Button(action: { model.onUndo?() }) {
                    Text("Undo")
                        .font(LocalFlowDesign.generalSans(size: 12.5, weight: .medium))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isUndoHovered ? Color.white.opacity(0.24) : Color.white.opacity(0.15))
                        )
                }
                .buttonStyle(.plain)
                .onHover { isUndoHovered = $0 }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .frame(width: LocalFlowDesign.cancelledPillSize.width, height: LocalFlowDesign.cancelledPillSize.height)

            // Progress countdown line along the bottom edge
            GeometryReader { geo in
                VStack(alignment: .leading) {
                    Spacer(minLength: 0)
                    Rectangle()
                        .fill(Color(white: 0.92))
                        .frame(width: max(0, geo.size.width * CGFloat(model.cancelProgress)), height: 2)
                }
            }
            .frame(width: LocalFlowDesign.cancelledPillSize.width, height: LocalFlowDesign.cancelledPillSize.height)
            .clipShape(Capsule(style: .continuous))
        }
        .frame(width: LocalFlowDesign.cancelledPillSize.width, height: LocalFlowDesign.cancelledPillSize.height)
        .background(
            Capsule(style: .continuous)
                .fill(Color(red: 0.08, green: 0.08, blue: 0.09).opacity(0.96))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
        .shadow(color: Color.black.opacity(0.35), radius: 14, y: 6)
        .accessibilityLabel("Transcript cancelled. Tap Undo to restore.")
    }

    // MARK: - Push-to-Talk Mode (Compact Waveform, No Buttons)

    private var pushToTalkView: some View {
        HStack(alignment: .center, spacing: 2.6) {
            ForEach(Array(model.levels.enumerated()), id: \.offset) { _, level in
                Capsule(style: .continuous)
                    .fill(Color.white)
                    .frame(width: 2.8, height: max(4, level * 20))
            }
        }
        .padding(.horizontal, 14)
        .frame(width: LocalFlowDesign.overlaySize.width, height: LocalFlowDesign.overlaySize.height)
        .background(
            Capsule(style: .continuous)
                .fill(Color(red: 0.08, green: 0.08, blue: 0.09).opacity(0.96))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
        .shadow(color: Color.black.opacity(0.30), radius: 12, y: 5)
        .accessibilityLabel("Listening")
        .animation(.easeOut(duration: 0.08), value: model.levels)
    }
}

/// Back-compat name used by older call sites.
public typealias ListeningOrbOverlayView = WaveformOverlayView
public typealias ListeningOrbModel = WaveformOverlayModel
