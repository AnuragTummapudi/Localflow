import Foundation

/// Presentation only. This model never resolves or executes speech commands.
public enum OverlayPhase: Equatable, Sendable {
    case hidden, listening, handsFree, thinking, acting, success, confirmation, error, cancelled

    public var isRecording: Bool { self == .listening || self == .handsFree }
}

public struct OverlayMessage: Equatable, Sendable {
    public let title: String
    public let detail: String
    public let symbol: String

    public init(title: String, detail: String = "", symbol: String = "waveform") {
        self.title = title
        self.detail = detail
        self.symbol = symbol
    }
}

/// Deterministic state shared by the native panel and tests.
public struct OverlayState: Equatable, Sendable {
    public private(set) var phase: OverlayPhase = .hidden
    public private(set) var transcript: PartialTranscript?
    public private(set) var message = OverlayMessage(title: "")
    public private(set) var allowsUndo = false
    public private(set) var agentMessage: OverlayMessage?

    public init() {}

    public mutating func listen(mode: DictationSessionMode) {
        let previous = phase.isRecording ? transcript : nil
        present(mode == .handsFree ? .handsFree : .listening, message: OverlayMessage(title: "Listening…"))
        transcript = previous
    }

    @discardableResult
    public mutating func update(_ partial: PartialTranscript?) -> Bool {
        guard phase.isRecording, transcript != partial else { return false }
        transcript = partial
        return true
    }

    public mutating func present(_ phase: OverlayPhase, message: OverlayMessage, allowsUndo: Bool = false) {
        agentMessage = nil
        self.phase = phase
        self.message = message
        self.transcript = nil
        self.allowsUndo = (phase == .cancelled || phase == .success) && allowsUndo
    }

    /// Retains live speech and waveform while a native action is running.
    public mutating func agent(transcript: PartialTranscript?, message: OverlayMessage?, recording: Bool,
                               phase: OverlayPhase, allowsUndo: Bool = false) {
        self.phase = recording ? .handsFree : phase
        self.transcript = transcript
        self.message = message ?? OverlayMessage(title: recording ? "Voice Agent listening…" : "Deciding…")
        self.agentMessage = recording ? message : nil
        self.allowsUndo = !recording && phase == .success && allowsUndo
    }

    public mutating func hide() {
        self = OverlayState()
    }

    public var showsStop: Bool { phase.isRecording }
    public var showsConfirm: Bool { phase == .confirmation }
    public var showsCancel: Bool { phase == .handsFree || phase == .confirmation }
    public var showsUndo: Bool { (phase == .cancelled || phase == .success) && allowsUndo }
}

/// Pure geometry policy; NSScreen supplies the actual values in the App layer.
public enum OverlayLayout {
    public static let maximumWidth: CGFloat = 560
    public static let shadowInset: CGFloat = 12

    public static func width(textWidth: CGFloat, phase: OverlayPhase, screenWidth: CGFloat) -> CGFloat {
        let minimum: CGFloat = phase == .confirmation ? 360 : 256
        let accessories: CGFloat = phase == .confirmation ? 80 : (phase == .handsFree ? 176 : 136)
        // Quantization prevents window-frame churn for every character of live text.
        let desired = ceil((max(0, textWidth) + accessories) / 16) * 16
        let limit = max(1, min(maximumWidth, screenWidth - 2 * shadowInset - 24))
        return min(limit, max(minimum, desired))
    }

    /// Public safe-area/auxiliary rectangles can be absent, empty or inconsistent.
    /// Use a physical notch only when both auxiliary areas bound a real top gap.
    public static func notchCenter(
        frame: CGRect, safeTop: CGFloat, left: CGRect?, right: CGRect?
    ) -> CGFloat? {
        guard safeTop > 0, let left, let right, !left.isEmpty, !right.isEmpty,
              left.minX >= frame.minX, right.maxX <= frame.maxX,
              left.maxX < right.minX,
              abs(left.maxY - frame.maxY) <= 1, abs(right.maxY - frame.maxY) <= 1,
              left.height <= safeTop + 1, right.height <= safeTop + 1 else { return nil }
        return (left.maxX + right.minX) / 2
    }

    public static func panelFrame(
        size: CGSize, screenFrame: CGRect, visibleFrame: CGRect, safeTop: CGFloat,
        left: CGRect? = nil, right: CGRect? = nil
    ) -> CGRect {
        let center = notchCenter(frame: screenFrame, safeTop: safeTop, left: left, right: right)
        let top = center == nil
            ? min(screenFrame.maxY - max(0, safeTop), visibleFrame.maxY) - 4
            : screenFrame.maxY - safeTop - 4
        let width = min(size.width, max(1, screenFrame.width - 16))
        let height = min(size.height, max(1, screenFrame.height - 16))
        let x = min(max((center ?? screenFrame.midX) - width / 2, screenFrame.minX + 8), screenFrame.maxX - width - 8)
        let y = max(screenFrame.minY + 8, top - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
