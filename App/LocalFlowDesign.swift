import AppKit
import SwiftUI

/// Shared visual constants for LocalFlow's native app surfaces.
public enum LocalFlowDesign {
    /// Canvas background — warm parchment, not stark white.
    public static let canvas = Color(red: 0.957, green: 0.961, blue: 0.945)

    /// Slightly lighter card surface on Canvas.
    public static let card = Color(red: 0.980, green: 0.980, blue: 0.973)

    /// Dark product-preview / overlay pill surface (Canvas-dark #1C1E22).
    public static let darkSurface = Color(red: 0.110, green: 0.118, blue: 0.133)
    public static let canvasDark = darkSurface

    /// Primary text color for light surfaces.
    public static let ink = Color(red: 0.125, green: 0.125, blue: 0.118)

    /// Primary text color for dark surfaces (Ink-dark #EDEFEC).
    public static let inkDark = Color(red: 0.929, green: 0.937, blue: 0.925)

    /// Secondary text color — calibrated to #5C6370 to ensure WCAG AA (4.74:1) on Canvas.
    public static let graphite = Color(red: 0.392, green: 0.420, blue: 0.471)

    /// Signal accent — primary interactive color (never system blue).
    public static let signal = Color(red: 0.184, green: 0.298, blue: 0.867)

    /// Marker accent — sparing use only for sketch/transient layer.
    public static let marker = Color(red: 1.000, green: 0.353, blue: 0.212)

    /// Destructive action warning red (#FF3B30) — distinct from Marker sketch accent.
    public static let destructiveRed = Color(red: 1.000, green: 0.231, blue: 0.188)

    /// Subtle hover background on Canvas (#E4E7E1).
    public static let canvasHover = Color(red: 0.914, green: 0.922, blue: 0.910)

    /// Soft violet used inside the listening orb.
    public static let orbViolet = Color(red: 0.620, green: 0.380, blue: 0.920)

    /// Warm amber used inside the listening orb.
    public static let orbWarm = Color(red: 1.000, green: 0.620, blue: 0.380)

    /// Sidebar selection highlight — Signal at low opacity.
    public static let sidebarHighlight = Color(red: 0.184, green: 0.298, blue: 0.867).opacity(0.12)

    /// Hairline border for cards.
    public static let hairline = Color(red: 0.361, green: 0.388, blue: 0.439).opacity(0.18)

    /// Fixed onboarding content size.
    public static let onboardingSize = CGSize(width: 640, height: 440)

    /// Fixed settings content size — wide enough for sidebar + detail.
    public static let settingsSize = CGSize(width: 900, height: 600)

    /// Compact floating listening-pill size (clean 11 waveform bars).
    public static let overlaySize = CGSize(width: 114, height: 36)

    /// Floating hands-free listening-pill size (Cancel circle + 11 waveform bars + Finish circle).
    public static let handsFreePillSize = CGSize(width: 164, height: 36)

    /// Floating hands-free window size (allows hover tooltip to float above pill without clipping).
    public static let handsFreeWindowSize = CGSize(width: 252, height: 80)

    /// Cancelled "Transcript cancelled" pill size with Undo button and progress bar.
    public static let cancelledPillSize = CGSize(width: 286, height: 46)

    /// Intrinsic progress HUD size. Status copy stays on one line when practical and
    /// grows to two lines only for unusually long actionable guidance.
    public static func processingPillSize(for message: String) -> CGSize {
        statusPillSize(for: message, minimumWidth: 132, accessoryWidth: 47)
    }

    /// Intrinsic terminal HUD size. The leading state glyph is included in the
    /// accessory allowance so result and error copy never competes with the icon.
    public static func polishPillSize(for message: String) -> CGSize {
        statusPillSize(for: message, minimumWidth: 124, accessoryWidth: 47)
    }

    private static func statusPillSize(
        for message: String,
        minimumWidth: CGFloat,
        accessoryWidth: CGFloat
    ) -> CGSize {
        let font = NSFont(name: "Matter-Medium", size: 12.5)
            ?? NSFont.systemFont(ofSize: 12.5, weight: .medium)
        let textWidth = ceil((message as NSString).size(withAttributes: [.font: font]).width)
        let maximumWidth: CGFloat = 420
        let desiredWidth = textWidth + accessoryWidth
        let width = min(maximumWidth, max(minimumWidth, desiredWidth))
        let needsSecondLine = desiredWidth > maximumWidth
        return CGSize(width: width, height: needsSecondLine ? 54 : 36)
    }

    /// Backwards compatibility alias for handsFreeOverlaySize.
    public static let handsFreeOverlaySize = handsFreePillSize

    /// Signal accent color as `NSColor`.
    public static let nsSignal = NSColor(red: 0.184, green: 0.298, blue: 0.867, alpha: 1)

    /// Marker accent color as `NSColor`.
    public static let nsMarker = NSColor(red: 1.000, green: 0.353, blue: 0.212, alpha: 1)

    /// Destructive red as `NSColor`.
    public static let nsDestructiveRed = NSColor(red: 1.000, green: 0.231, blue: 0.188, alpha: 1)

    /// Dark surface color as `NSColor`.
    public static let nsDarkSurface = NSColor(red: 0.110, green: 0.118, blue: 0.133, alpha: 1)

    // MARK: — Canonical Logomark

    /// The canonical geometric LocalFlow zigzag logomark view.
    public static func logomark(size: CGSize = CGSize(width: 20, height: 13), color: Color = signal) -> some View {
        ResolvedWaveform()
            .fill(color)
            .frame(width: size.width, height: size.height)
    }

    /// Generates the canonical geometric zigzag bezier path in the given rect.
    public static func resolvedWaveformPath(in rect: NSRect) -> NSBezierPath {
        let path = NSBezierPath()
        let mid = rect.midY
        let width = rect.width
        let points = [
            NSPoint(x: rect.minX, y: mid),
            NSPoint(x: rect.minX + width * 0.16, y: rect.minY + rect.height * 0.18),
            NSPoint(x: rect.minX + width * 0.32, y: rect.maxY - rect.height * 0.18),
            NSPoint(x: rect.minX + width * 0.50, y: rect.minY + rect.height * 0.12),
            NSPoint(x: rect.minX + width * 0.68, y: rect.maxY - rect.height * 0.18),
            NSPoint(x: rect.minX + width * 0.84, y: rect.minY + rect.height * 0.28),
            NSPoint(x: rect.maxX, y: mid)
        ]
        path.move(to: points[0])
        points.dropFirst().forEach { path.line(to: $0) }
        let thickness = max(2.5, rect.height * 0.22)
        path.line(to: NSPoint(x: rect.maxX, y: mid + thickness))
        points.dropLast().reversed().forEach { point in
            path.line(to: NSPoint(x: point.x, y: point.y + thickness))
        }
        path.close()
        return path
    }

    // MARK: — Typography
    // Custom faces are bundled under Resources/Fonts and registered via ATSApplicationFontsPath.
    // Falls back to system equivalents when a face is unavailable (e.g. unit-test hosts).

    /// Season Mix role — uses a bundled display face when available, then native New York.
    public static func instrumentSerif(size: CGFloat, italic: Bool = false) -> Font {
        let name = italic ? "SeasonMix-Italic" : "SeasonMix-Regular"
        if NSFont(name: name, size: size) != nil {
            return .custom(name, size: size)
        }
        return .system(size: size, weight: .regular, design: .serif)
    }

    /// Alias kept for older call sites — maps to Instrument Serif.
    public static func bricolage(size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        _ = weight
        return instrumentSerif(size: size)
    }

    /// Matter role — native system sans fallback keeps controls legible and macOS-native.
    public static func generalSans(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .medium, .semibold, .bold, .heavy, .black:
            name = weight == .medium ? "Matter-Medium" : "Matter-Semibold"
        default:
            name = "GeneralSans-Regular"
        }
        if NSFont(name: name, size: size) != nil {
            return .custom(name, size: size)
        }
        return .system(size: size, weight: weight)
    }

    /// Fragment Mono — timestamps, technical labels, command strings.
    public static func fragmentMono(size: CGFloat) -> Font {
        let name = "FragmentMono-Regular"
        if NSFont(name: name, size: size) != nil {
            return .custom(name, size: size)
        }
        return .system(size: size, weight: .regular, design: .monospaced)
    }

    // MARK: — Shared chrome

    /// Soft card chrome: lighter Canvas fill, 16px radius, hairline border, no shadow.
    public static func cardBackground(cornerRadius: CGFloat = 16) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(card)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(hairline, lineWidth: 1)
            )
    }
}

// MARK: - Buttons

/// Primary Signal-filled pill button (40–44pt tall, intrinsic width).
public struct LFPrimaryButton: View {
    public let title: String
    public let action: () -> Void
    public var enabled: Bool = true

    public init(_ title: String, enabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.enabled = enabled
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(LocalFlowDesign.generalSans(size: 14, weight: .medium))
                .foregroundStyle(enabled ? Color.white : LocalFlowDesign.graphite)
                .padding(.horizontal, 20)
                .frame(height: 42)
                .background(
                    Capsule(style: .continuous)
                        .fill(enabled ? LocalFlowDesign.signal : LocalFlowDesign.graphite.opacity(0.18))
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// Secondary Graphite-outline pill button.
public struct LFSecondaryButton: View {
    public let title: String
    public let action: () -> Void

    public init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(LocalFlowDesign.generalSans(size: 14, weight: .medium))
                .foregroundStyle(LocalFlowDesign.ink)
                .padding(.horizontal, 20)
                .frame(height: 42)
                .background(
                    Capsule(style: .continuous)
                        .strokeBorder(LocalFlowDesign.graphite.opacity(0.35), lineWidth: 1)
                        .background(Capsule(style: .continuous).fill(LocalFlowDesign.card))
                )
        }
        .buttonStyle(.plain)
    }
}

/// Pane title set in Instrument Serif.
public struct LFPaneTitle: View {
    public let title: String

    public init(_ title: String) {
        self.title = title
    }

    public var body: some View {
        Text(title)
            .font(LocalFlowDesign.instrumentSerif(size: 28))
            .foregroundStyle(LocalFlowDesign.ink)
    }
}

/// The original LocalFlow geometric mark, preserved for the established brand identity.
public struct ResolvedWaveform: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        let mid = rect.midY
        let width = rect.width
        let points = [
            CGPoint(x: rect.minX, y: mid),
            CGPoint(x: rect.minX + width * 0.16, y: rect.minY + rect.height * 0.18),
            CGPoint(x: rect.minX + width * 0.32, y: rect.maxY - rect.height * 0.18),
            CGPoint(x: rect.minX + width * 0.50, y: rect.minY + rect.height * 0.12),
            CGPoint(x: rect.minX + width * 0.68, y: rect.maxY - rect.height * 0.18),
            CGPoint(x: rect.minX + width * 0.84, y: rect.minY + rect.height * 0.28),
            CGPoint(x: rect.maxX, y: mid)
        ]
        path.move(to: points[0])
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        let thickness = max(2.5, min(7.0, rect.height * 0.22))
        path.addLine(to: CGPoint(x: rect.maxX, y: mid + thickness))
        for point in points.dropLast().reversed() {
            path.addLine(to: CGPoint(x: point.x, y: point.y + thickness))
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Focus Rings

public struct SignalFocusRing: ViewModifier {
    public let isFocused: Bool
    public let cornerRadius: CGFloat

    public func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(isFocused ? LocalFlowDesign.signal : Color.clear, lineWidth: 2)
            )
            .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}

public struct SignalCapsuleFocusRing: ViewModifier {
    public let isFocused: Bool

    public func body(content: Content) -> some View {
        content
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(isFocused ? LocalFlowDesign.signal : Color.clear, lineWidth: 2)
            )
            .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}

public extension View {
    func signalFocusRing(isFocused: Bool, cornerRadius: CGFloat = 10) -> some View {
        modifier(SignalFocusRing(isFocused: isFocused, cornerRadius: cornerRadius))
    }

    func signalCapsuleFocusRing(isFocused: Bool) -> some View {
        modifier(SignalCapsuleFocusRing(isFocused: isFocused))
    }
}

/// Custom geometric line-art lock/pin glyph in Signal blue for hands-free mode.
public struct LockGlyph: View {
    public var color: Color = LocalFlowDesign.signal
    public var lineWidth: CGFloat = 1.6

    public init(color: Color = LocalFlowDesign.signal, lineWidth: CGFloat = 1.6) {
        self.color = color
        self.lineWidth = lineWidth
    }

    public var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height

            // Body: rounded rectangle on lower half
            let bodyRect = CGRect(x: w * 0.12, y: h * 0.40, width: w * 0.76, height: h * 0.54)
            let bodyPath = Path(roundedRect: bodyRect, cornerRadius: min(3.5, w * 0.16))

            // Shackle: arch on top
            var shacklePath = Path()
            let shackleLeft = w * 0.28
            let shackleRight = w * 0.72
            let radius = (shackleRight - shackleLeft) / 2
            let shackleCenterY = h * 0.40 - radius * 0.2

            shacklePath.move(to: CGPoint(x: shackleLeft, y: h * 0.40))
            shacklePath.addLine(to: CGPoint(x: shackleLeft, y: shackleCenterY))
            shacklePath.addArc(
                center: CGPoint(x: w * 0.50, y: shackleCenterY),
                radius: radius,
                startAngle: .degrees(180),
                endAngle: .degrees(0),
                clockwise: false
            )
            shacklePath.addLine(to: CGPoint(x: shackleRight, y: h * 0.40))

            // Keyhole pin dot
            let keyhole = Path(ellipseIn: CGRect(x: w * 0.50 - 1.2, y: h * 0.62 - 1.2, width: 2.4, height: 2.4))

            context.stroke(shacklePath, with: .color(color), lineWidth: lineWidth)
            context.stroke(bodyPath, with: .color(color), lineWidth: lineWidth)
            context.fill(keyhole, with: .color(color))
        }
        .frame(width: 16, height: 18)
    }
}
