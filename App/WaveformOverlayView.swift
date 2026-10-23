import AppKit
import SwiftUI
import Shared
import CommandMode

/// Observable rendering state for the single native island panel.
@MainActor
public final class WaveformOverlayModel: ObservableObject {
    public static let barCount = 11
    @Published public private(set) var presentation = OverlayState()
    @Published public private(set) var levels: [CGFloat] = Array(repeating: 0.15, count: barCount)
    @Published public var surfaceSize = CGSize(width: 256, height: 48)
    @Published public var cancelProgress: Double = 1

    public var onCancel: (() -> Void)?
    public var onFinishAndPaste: (() -> Void)?
    public var onUndo: (() -> Void)?
    public var onConfirm: (() -> Void)?
    public var onDismiss: (() -> Void)?

    public init() {}

    public func listen(mode: DictationSessionMode) { presentation.listen(mode: mode) }
    @discardableResult
    public func update(transcript: PartialTranscript?) -> Bool { presentation.update(transcript) }
    public func present(_ phase: OverlayPhase, message: OverlayMessage, allowsUndo: Bool = false) {
        presentation.present(phase, message: message, allowsUndo: allowsUndo)
        cancelProgress = 1
    }
    public func agent(transcript: PartialTranscript?, message: OverlayMessage?, recording: Bool, phase: OverlayPhase, allowsUndo: Bool) {
        presentation.agent(transcript: transcript, message: message, recording: recording, phase: phase, allowsUndo: allowsUndo)
    }
    public func hide() { presentation.hide() }

    public func update(levels raw: [Float]) {
        guard !raw.isEmpty else { return }
        let envelope: [CGFloat] = [0.42, 0.60, 0.78, 0.92, 0.98, 1, 0.98, 0.92, 0.78, 0.60, 0.42]
        levels = (0..<Self.barCount).map { index in
            let sample = raw[index % raw.count]
            let finite = sample.isFinite ? CGFloat(sample) : 0
            let next = min(1, max(0.12, finite * 1.45 + 0.10)) * envelope[index]
            return levels[index] * 0.4 + next * 0.6
        }
    }
}

/// Compact, native recording and action surface. The AppKit panel owns placement/focus.
public struct WaveformOverlayView: View {
    @ObservedObject public var model: WaveformOverlayModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    public init(model: WaveformOverlayModel) { self.model = model }

    private var state: OverlayState { model.presentation }
    private var secondary: Color { Color(white: 0.72) }
    private var spring: Animation? { reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.92) }

    public var body: some View {
        VStack(spacing: 8) {
            if state.phase.isRecording {
                recordingRow
            } else {
                statusRow
                if let transcript = state.transcript, !transcript.text.isEmpty {
                    Text(String(transcript.text.suffix(240)))
                        .font(LocalFlowDesign.generalSans(size: 11, weight: .regular))
                        .foregroundStyle(secondary)
                        .lineLimit(1).truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Agent transcript")
                        .accessibilityValue(transcript.text)
                }
                if state.showsConfirm { confirmationControls }
            }
        }
        .padding(.horizontal, 16)
        .frame(width: model.surfaceSize.width, height: model.surfaceSize.height)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.black)
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Color.white.opacity(contrast == .increased ? 0.5 : 0.15), lineWidth: 1)
                }
        }
        .overlay(alignment: .bottom) {
            if state.phase == .cancelled, state.showsUndo, !reduceMotion {
                Capsule().fill(Color.white.opacity(0.65))
                    .frame(width: max(0, (model.surfaceSize.width - 48) * model.cancelProgress), height: 2)
                    .padding(.bottom, 4)
                    .accessibilityHidden(true)
            }
        }
        .shadow(color: .black.opacity(0.22), radius: 8, y: 4)
        .animation(spring, value: model.surfaceSize)
        .animation(spring, value: state.phase)
        .padding(OverlayLayout.shadowInset)
        .preferredColorScheme(.dark)
    }

    private var recordingRow: some View {
        HStack(spacing: 12) {
            waveform
            VStack(alignment: .leading, spacing: 2) {
                let text = state.transcript?.text ?? ""
                Text(text.isEmpty ? "Listening…" : String(text.suffix(240)))
                    .font(LocalFlowDesign.generalSans(size: 13.5, weight: .medium))
                    .foregroundStyle(text.isEmpty ? secondary : LocalFlowDesign.inkDark)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Live transcript")
                    .accessibilityValue(text.isEmpty ? "Listening" : text)
                if let action = state.agentMessage {
                    Label(action.title + (action.detail.isEmpty ? "" : " · " + action.detail), systemImage: action.symbol)
                        .font(LocalFlowDesign.generalSans(size: 11, weight: .medium))
                        .foregroundStyle(secondary)
                        .lineLimit(1).truncationMode(.tail)
                        .accessibilityLabel("Current action")
                        .accessibilityValue(action.title + ". " + action.detail)
                } else if state.phase == .handsFree {
                    Text("Hands-free")
                        .font(LocalFlowDesign.generalSans(size: 11, weight: .medium))
                        .tracking(0.2)
                        .foregroundStyle(secondary)
                }
            }
            if state.showsCancel {
                iconButton("xmark", label: "Cancel recording", action: model.onCancel)
            }
            iconButton("stop.fill", label: "Stop recording and transcribe", prominent: true, action: model.onFinishAndPaste)
        }
    }

    private var waveform: some View {
        HStack(spacing: 2.4) {
            ForEach(0..<WaveformOverlayModel.barCount, id: \.self) { index in
                Capsule()
                    .fill(LocalFlowDesign.inkDark)
                    .frame(width: 2.5, height: reduceMotion ? 8 : max(3, model.levels[index] * 20))
            }
        }
        .frame(width: 52, height: 24)
        .animation(reduceMotion ? nil : .spring(response: 0.15, dampingFraction: 1), value: model.levels)
        .accessibilityHidden(true)
    }

    private var statusRow: some View {
        HStack(spacing: 12) {
            Image(systemName: state.phase == .success ? "checkmark.circle.fill" : state.message.symbol)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(state.phase == .error ? LocalFlowDesign.destructiveRed : LocalFlowDesign.inkDark)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(state.message.title)
                    .font(LocalFlowDesign.generalSans(size: 13.5, weight: .medium))
                    .foregroundStyle(LocalFlowDesign.inkDark)
                    .lineLimit(1).truncationMode(.tail)
                if !state.message.detail.isEmpty {
                    Text(state.message.detail)
                        .font(LocalFlowDesign.generalSans(size: 12, weight: .regular))
                        .foregroundStyle(secondary)
                        .lineLimit(state.phase == .error ? 2 : 1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(state.message.title)
            .accessibilityValue(state.message.detail)
            if state.phase == .error, let url = NativePermissionReadiness.settingsURL(forFailure: state.message.title + " " + state.message.detail) {
                Button("Settings") { NSWorkspace.shared.open(url) }
                    .buttonStyle(IslandButtonStyle(prominent: false)).focusable(false)
                    .accessibilityLabel("Open required permission settings")
            } else if state.showsUndo {
                Button("Undo") { model.onUndo?() }
                    .buttonStyle(IslandButtonStyle(prominent: false))
                    .accessibilityLabel(state.phase == .cancelled ? "Undo cancellation and start a new recording" : "Undo the last action")
                    .focusable(false)
            } else if state.phase == .error || state.phase == .success {
                iconButton("xmark", label: "Dismiss notification", action: model.onDismiss)
            }
        }
    }

    private var confirmationControls: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Button("Cancel") { model.onCancel?() }
                .buttonStyle(IslandButtonStyle(prominent: false))
                .accessibilityLabel("Cancel command").focusable(false)
            Button("Confirm") { model.onConfirm?() }
                .buttonStyle(IslandButtonStyle(prominent: true))
                .accessibilityLabel("Confirm command").focusable(false)
        }
    }

    private func iconButton(_ symbol: String, label: String, prominent: Bool = false, action: (() -> Void)?) -> some View {
        Button { action?() } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(IslandButtonStyle(prominent: prominent, circular: true))
        .accessibilityLabel(label)
        .help(label)
        .focusable(false)
    }
}

private struct IslandButtonStyle: ButtonStyle {
    let prominent: Bool
    var circular = false
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(LocalFlowDesign.generalSans(size: 12, weight: .medium))
            .foregroundStyle(prominent ? Color.black : LocalFlowDesign.inkDark)
            .padding(.horizontal, circular ? 0 : 12)
            .frame(height: 28)
            .background {
                RoundedRectangle(cornerRadius: circular ? 14 : 10, style: .continuous)
                    .fill(prominent ? Color.white.opacity(configuration.isPressed ? 0.75 : 1) : Color.white.opacity(hovered || configuration.isPressed ? 0.24 : 0.12))
            }
            .onHover { hovered = $0 }
    }
}

public typealias ListeningOrbOverlayView = WaveformOverlayView
public typealias ListeningOrbModel = WaveformOverlayModel
