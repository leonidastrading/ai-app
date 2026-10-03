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

    let text = NSAttributedString(string: "UAI", attributes: [
        .font: NSFont.systemFont(ofSize: rect.width * 0.30, weight: .heavy),
        .foregroundColor: NSColor.white,
    ])
    let ts = text.size()
    text.draw(at: NSPoint(x: rect.midX - ts.width / 2, y: rect.midY - ts.height / 2))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
