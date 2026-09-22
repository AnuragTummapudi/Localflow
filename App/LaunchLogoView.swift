import AppKit
import SwiftUI
import Shared

/// The one-time sketch-to-clean LocalFlow launch mark animation.
public struct LaunchLogoView: View {
    @State private var trimEnd = 0.0
    @State private var showResolved = false
    @State private var resolvedScale: CGFloat = 0.86
    @State private var showWordmark = false

    private let settings: LocalFlowSettings
    private let completion: () -> Void

    /// Creates the launch logo view.
    public init(settings: LocalFlowSettings = .shared, completion: @escaping () -> Void) {
        self.settings = settings
        self.completion = completion
    }

    /// The view body.
    public var body: some View {
        HStack(spacing: 14) {
            ZStack {
                SketchyWaveform()
                    .trim(from: 0, to: trimEnd)
                    .stroke(LocalFlowDesign.marker, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    .opacity(showResolved ? 0 : 1)

                ResolvedWaveform()
                    .fill(LocalFlowDesign.signal)
                    .scaleEffect(resolvedScale)
                    .opacity(showResolved ? 1 : 0)
            }
            .frame(width: 72, height: 52)

            Text("LocalFlow")
                .font(LocalFlowDesign.instrumentSerif(size: 36))
                .foregroundStyle(LocalFlowDesign.ink)
                .opacity(showWordmark ? 1 : 0)
                .offset(x: showWordmark ? 0 : -8)
        }
        .frame(width: 328, height: 92)
        .onAppear(perform: start)
    }

    private func start() {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            trimEnd = 1
            showResolved = true
            resolvedScale = 1
            showWordmark = true
            finish()
            return
        }
        withAnimation(.easeOut(duration: 0.55)) {
            trimEnd = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.52) {
            // Gentle scale-and-settle into the resolved mark — continuous with the listening orb’s fluid character.
            OnboardingSound.playResolve()
            showResolved = true
            resolvedScale = 0.86
            withAnimation(.spring(response: 0.55, dampingFraction: 0.78)) {
                resolvedScale = 1.0
            }
            withAnimation(.easeOut(duration: 0.35)) {
                // Sketch fades as resolved settles.
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.78) {
            withAnimation(.easeOut(duration: 0.32)) {
                showWordmark = true
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.25, execute: finish)
    }

    private func finish() {
        settings.didPlayLaunchAnimation = true
        completion()
    }
}

@MainActor
private enum OnboardingSound {
    private static var player: NSSound?

    static func playResolve() {
        guard let url = Bundle.main.url(forResource: "OnboardingResolve", withExtension: "mp3"),
              let sound = NSSound(contentsOf: url, byReference: true)
        else { return }

        sound.volume = 0.42
        player = sound
        sound.play()
    }
}

/// The hand-drawn temporary waveform path.
public struct SketchyWaveform: Shape {
    /// Creates the shape path.
    public func path(in rect: CGRect) -> Path {
        var path = Path()
        let y = rect.midY
        path.move(to: CGPoint(x: rect.minX + 4, y: y + 3))
        path.addCurve(to: CGPoint(x: rect.minX + 14, y: y - 18), control1: CGPoint(x: rect.minX + 8, y: y + 8), control2: CGPoint(x: rect.minX + 11, y: y - 16))
        path.addCurve(to: CGPoint(x: rect.minX + 25, y: y + 15), control1: CGPoint(x: rect.minX + 17, y: y - 21), control2: CGPoint(x: rect.minX + 21, y: y + 14))
        path.addCurve(to: CGPoint(x: rect.minX + 36, y: y - 20), control1: CGPoint(x: rect.minX + 29, y: y + 17), control2: CGPoint(x: rect.minX + 31, y: y - 20))
        path.addCurve(to: CGPoint(x: rect.minX + 48, y: y + 16), control1: CGPoint(x: rect.minX + 40, y: y - 19), control2: CGPoint(x: rect.minX + 43, y: y + 16))
        path.addCurve(to: CGPoint(x: rect.minX + 59, y: y - 13), control1: CGPoint(x: rect.minX + 52, y: y + 17), control2: CGPoint(x: rect.minX + 55, y: y - 13))
        path.addCurve(to: CGPoint(x: rect.maxX - 4, y: y), control1: CGPoint(x: rect.minX + 63, y: y - 13), control2: CGPoint(x: rect.maxX - 10, y: y + 5))
        return path
    }
}
