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

    // Colorway: indigo -> violet -> pink -> aqua, like the shoe's midsole.
    let indigo = NSColor(red: 0.27, green: 0.29, blue: 0.78, alpha: 1)
    let violet = NSColor(red: 0.47, green: 0.38, blue: 0.86, alpha: 1)
    let pink = NSColor(red: 0.95, green: 0.40, blue: 0.62, alpha: 1)
    let aqua = NSColor(red: 0.45, green: 0.74, blue: 0.80, alpha: 1)
    NSGradient(colors: [indigo, violet, pink, aqua])!.draw(in: tile, angle: -60)

    // Diagonal knit stripes across the top half.
    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    NSColor.white.withAlphaComponent(0.12).setStroke()
    let stripe = NSBezierPath()
    stripe.lineWidth = max(1, size * 0.012)
    var x = rect.minX - rect.height
    while x < rect.maxX {
        stripe.move(to: NSPoint(x: x, y: rect.midY))
        stripe.line(to: NSPoint(x: x + rect.height * 0.5, y: rect.maxY))
        x += size * 0.035
    }
    stripe.stroke()
    NSGraphicsContext.restoreGraphicsState()

    // A spiral galaxy in the middle, matching the Universal AI icon.
    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    let center = NSPoint(x: rect.midX, y: rect.midY)
    let radius = rect.width * 0.34
    func seeded(_ i: Int) -> CGFloat {
        let v = sin(Double(i) * 12.9898) * 43758.5453
        return CGFloat(v - floor(v))
    }
    // Bright core glow.
    NSGradient(colors: [NSColor.white, pink.withAlphaComponent(0.6), NSColor.clear])!
        .draw(in: NSBezierPath(ovalIn: NSRect(x: center.x - radius * 0.4, y: center.y - radius * 0.4,
                                              width: radius * 0.8, height: radius * 0.8)),
              relativeCenterPosition: .zero)
    // Two spiral arms of glowing dots, pink and aqua.
    for (offset, color) in [(0.0, pink), (Double.pi, aqua)] {
        for i in 0..<70 {
            let t = Double(i) / 70
            let angle = offset + t * 3.4 * Double.pi
            let r = radius * (0.12 + 0.88 * CGFloat(t))
            let jitter = (seeded(i + Int(offset * 100)) - 0.5) * radius * 0.10
            let x = center.x + CGFloat(cos(angle)) * (r + jitter)
            let y = center.y + CGFloat(sin(angle)) * (r + jitter) * 0.82
            let dot = radius * (0.09 - 0.055 * CGFloat(t))
            let shade = t < 0.25 ? NSColor.white : color
            shade.withAlphaComponent(0.95 - 0.5 * CGFloat(t)).setFill()
            NSBezierPath(ovalIn: NSRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot)).fill()
        }
    }
    // A few background stars.
    for i in 0..<18 {
        let x = rect.minX + seeded(i * 7) * rect.width
        let y = rect.minY + seeded(i * 13) * rect.height
        let s = size * 0.006 + seeded(i) * size * 0.01
        NSColor.white.withAlphaComponent(0.35 + seeded(i * 3) * 0.4).setFill()
        NSBezierPath(ovalIn: NSRect(x: x, y: y, width: s, height: s)).fill()
    }
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
