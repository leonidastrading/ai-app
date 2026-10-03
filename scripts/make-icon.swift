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
    NSGradient(colors: [NSColor(red: 0.29, green: 0.08, blue: 0.30, alpha: 1),
                        NSColor(red: 0.13, green: 0.03, blue: 0.14, alpha: 1)])!.draw(in: tile, angle: -90)

    // Four Slack-like colored dots for the four corners of "all AIs".
    let colors: [NSColor] = [
        NSColor(red: 0.88, green: 0.12, blue: 0.35, alpha: 1), NSColor(red: 0.93, green: 0.70, blue: 0.18, alpha: 1),
        NSColor(red: 0.18, green: 0.71, blue: 0.49, alpha: 1), NSColor(red: 0.21, green: 0.77, blue: 0.94, alpha: 1),
    ]
    let dot = rect.width * 0.09
    let positions = [(0.22, 0.78), (0.78, 0.78), (0.22, 0.22), (0.78, 0.22)]
    for (i, p) in positions.enumerated() {
        colors[i].setFill()
        NSBezierPath(ovalIn: NSRect(x: rect.minX + rect.width * p.0 - dot / 2,
                                    y: rect.minY + rect.height * p.1 - dot / 2, width: dot, height: dot)).fill()
    }

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
