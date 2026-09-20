import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let destination = root.appendingPathComponent("Resources/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

let sizes = [16, 32, 64, 128, 256, 512, 1024]

func resolvedWaveformPath(in rect: NSRect) -> NSBezierPath {
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
    path.line(to: NSPoint(x: rect.maxX, y: mid + rect.height * 0.14))
    points.dropLast().reversed().forEach { point in
        path.line(to: NSPoint(x: point.x, y: point.y + rect.height * 0.14))
    }
    path.close()
    return path
}

for size in sizes {
    // Force a 1x bitmap representation so Retina hosts don't double pixel dimensions.
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "LocalFlowIcon", code: 1)
    }
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    NSColor(red: 0.933, green: 0.941, blue: 0.925, alpha: 1).setFill()
    NSBezierPath(
        roundedRect: NSRect(x: 0, y: 0, width: size, height: size),
        xRadius: CGFloat(size) * 0.22,
        yRadius: CGFloat(size) * 0.22
    ).fill()

    NSColor(red: 0.184, green: 0.298, blue: 0.867, alpha: 1).setFill()
    let markRect = NSRect(
        x: CGFloat(size) * 0.16,
        y: CGFloat(size) * 0.38,
        width: CGFloat(size) * 0.68,
        height: CGFloat(size) * 0.24
    )
    resolvedWaveformPath(in: markRect).fill()

    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "LocalFlowIcon", code: 2)
    }
    try png.write(to: destination.appendingPathComponent("localflow-icon-\(size).png"))
}
