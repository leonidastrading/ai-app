// Draws the UAI app icon and writes an .iconset folder.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let size = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let inset = size * 0.09
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let tile = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)

    // Colorway: indigo / violet / pink / aqua, like the shoe's midsole, but
    // kept deep so the galaxy reads as the star of the icon.
    let indigo = NSColor(red: 0.27, green: 0.29, blue: 0.78, alpha: 1)
    let violet = NSColor(red: 0.47, green: 0.38, blue: 0.86, alpha: 1)
    let pink = NSColor(red: 0.98, green: 0.45, blue: 0.68, alpha: 1)
    let aqua = NSColor(red: 0.50, green: 0.82, blue: 0.88, alpha: 1)

    // Dark space background: a deep indigo corner fading to near-black, so the
    // bright galaxy pops instead of getting washed out by a loud gradient.
    let deepIndigo = NSColor(red: 0.16, green: 0.13, blue: 0.40, alpha: 1)
    let space = NSColor(red: 0.04, green: 0.03, blue: 0.10, alpha: 1)
    NSGradient(colors: [deepIndigo, space])!.draw(in: tile, angle: -60)

    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    let center = NSPoint(x: rect.midX, y: rect.midY)
    // The galaxy now fills most of the tile instead of being a speck.
    let radius = rect.width * 0.60
    func seeded(_ i: Int) -> CGFloat {
        let v = sin(Double(i) * 12.9898) * 43758.5453
        return CGFloat(v - floor(v))
    }

    // Scattered background stars across the whole tile.
    for i in 0..<60 {
        let x = rect.minX + seeded(i * 7) * rect.width
        let y = rect.minY + seeded(i * 13) * rect.height
        let s = size * 0.004 + seeded(i) * size * 0.012
        NSColor.white.withAlphaComponent(0.25 + seeded(i * 3) * 0.5).setFill()
        NSBezierPath(ovalIn: NSRect(x: x, y: y, width: s, height: s)).fill()
    }

    // Soft outer halo so the disk feels like it glows — kept subtle so the
    // dark space background still shows in the corners.
    NSGradient(colors: [violet.withAlphaComponent(0.30), pink.withAlphaComponent(0.08), NSColor.clear])!
        .draw(in: NSBezierPath(ovalIn: NSRect(x: center.x - radius * 0.95, y: center.y - radius * 0.95,
                                              width: radius * 1.9, height: radius * 1.9)),
              relativeCenterPosition: .zero)

    // Bright, tight core glow.
    let coreR = radius * 0.30
    NSGradient(colors: [NSColor.white, pink.withAlphaComponent(0.85), NSColor.clear])!
        .draw(in: NSBezierPath(ovalIn: NSRect(x: center.x - coreR, y: center.y - coreR,
                                              width: coreR * 2, height: coreR * 2)),
              relativeCenterPosition: .zero)

    // Two spiral arms of glowing dots, pink and aqua, tilted for a disk look.
    let tilt = CGFloat.pi / 9      // ~20° tilt
    let cosT = cos(tilt), sinT = sin(tilt)
    let flatten: CGFloat = 0.72    // squash vertically into an ellipse
    for (offset, color) in [(0.0, pink), (Double.pi, aqua)] {
        for i in 0..<140 {
            let t = Double(i) / 140
            let angle = offset + t * 3.4 * Double.pi
            let r = radius * (0.10 + 0.90 * CGFloat(t))
            let jitter = (seeded(i + Int(offset * 100)) - 0.5) * radius * 0.08
            // Point on the spiral, then squashed and rotated into the disk plane.
            let px = CGFloat(cos(angle)) * (r + jitter)
            let py = CGFloat(sin(angle)) * (r + jitter) * flatten
            let x = center.x + px * cosT - py * sinT
            let y = center.y + px * sinT + py * cosT
            let dot = radius * (0.075 - 0.045 * CGFloat(t))
            let shade = t < 0.22 ? NSColor.white : color
            shade.withAlphaComponent(0.95 - 0.45 * CGFloat(t)).setFill()
            NSBezierPath(ovalIn: NSRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot)).fill()
        }
    }
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
