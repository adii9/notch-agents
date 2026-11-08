// Generates Resources/AppIcon.icns. Usage: swift Scripts/make-icon.swift
import AppKit

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x: x * s, y: y * s, width: w * s, height: h * s) }

    // Background squircle with macOS icon margin.
    let bg = NSBezierPath(roundedRect: r(0.1, 0.1, 0.8, 0.8), xRadius: 0.18 * s, yRadius: 0.18 * s)
    NSGradient(colors: [NSColor(red: 0.20, green: 0.17, blue: 0.32, alpha: 1), NSColor(red: 0.05, green: 0.05, blue: 0.09, alpha: 1)])!
        .draw(in: bg, angle: -90)

    // The notch pill hanging from the top edge.
    NSColor.black.setFill()
    NSBezierPath(roundedRect: r(0.24, 0.60, 0.52, 0.30), xRadius: 0.11 * s, yRadius: 0.11 * s).fill()
    NSBezierPath(rect: r(0.24, 0.80, 0.52, 0.10)).fill()

    // Agent rows inside: status dot + activity bar.
    let orange = NSColor(red: 1.0, green: 0.58, blue: 0.20, alpha: 1)
    let green = NSColor(red: 0.30, green: 0.85, blue: 0.45, alpha: 1)
    for (i, c) in [orange, green].enumerated() {
        let y = 0.725 - CGFloat(i) * 0.075
        c.setFill()
        NSBezierPath(ovalIn: r(0.30, y, 0.045, 0.045)).fill()
        NSColor(white: 1, alpha: i == 0 ? 0.85 : 0.45).setFill()
        let w: CGFloat = i == 0 ? 0.26 : 0.18
        NSBezierPath(roundedRect: r(0.375, y + 0.008, w, 0.03), xRadius: 0.015 * s, yRadius: 0.015 * s).fill()
    }

    // Soft glow under the pill.
    NSGradient(colors: [orange.withAlphaComponent(0.35), .clear])!
        .draw(in: NSBezierPath(ovalIn: r(0.28, 0.30, 0.44, 0.22)), relativeCenterPosition: .zero)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath)
let iconset = root.appendingPathComponent("Resources/AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try p.run(); p.waitUntilExit()
try fm.removeItem(at: iconset)
print("wrote Resources/AppIcon.icns")
