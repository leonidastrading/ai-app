import SwiftUI

/// Universal AI's icon: an animated spiral galaxy.
///
/// Drop-in replacement for the old static `GalaxyIcon` — same `GalaxyIcon(size:)`
/// call sites keep working. ~260 stars on two spiral arms orbit the core; inner
/// stars move faster than outer ones, so the arms slowly wind into a swirl.
/// Pass `animated: false` for small or repeated uses (e.g. list rows).
/// Honors the system "Reduce motion" setting by drawing a still frame.
struct GalaxyIcon: View {
    var size: CGFloat = 48
    var animated: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let still = !animated || reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: still)) { timeline in
            let seconds = still ? 0 : timeline.date.timeIntervalSince(GalaxyField.start)
            Canvas { context, canvasSize in
                GalaxyField.draw(in: &context, size: canvasSize, seconds: seconds)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

/// The star field and drawing code, shared by every GalaxyIcon so all icons stay in sync.
enum GalaxyField {
    struct Star { let angle: Double; let radius: Double; let dot: Double; let color: Color }

    static let start = Date()
    static let spin = 0.24 // radians per second at the core

    private static let palette: [Color] = [
        Color(galaxyHex: 0xFF7AB8), Color(galaxyHex: 0xB28CFF), Color(galaxyHex: 0x7FD6FF), .white, Color(galaxyHex: 0xFFB3D1),
    ]

    /// Generated once per launch, so every launch gets a slightly different galaxy.
    static let stars: [Star] = (0..<260).map { (i: Int) -> Star in
        let arm = Double(i % 2)
        let t = Double.random(in: 0..<1)
        return Star(angle: arm * .pi + t * 5.5 + (Double.random(in: 0..<1) - 0.5) * 0.6,
                    radius: t * 0.82,
                    dot: Double.random(in: 0.6..<2.2),
                    color: palette.randomElement()!)
    }

    static func draw(in context: inout GraphicsContext, size: CGSize, seconds: Double) {
        let w = Double(min(size.width, size.height))
        let c = CGPoint(x: Double(size.width) / 2, y: Double(size.height) / 2)
        let r = w / 2
        let rot = seconds * spin

        // Deep-space disc.
        context.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: w, height: w)),
                     with: .radialGradient(Gradient(stops: [
                        .init(color: Color(galaxyHex: 0x3B2F9E), location: 0),
                        .init(color: Color(galaxyHex: 0x17145C), location: 0.55),
                        .init(color: Color(galaxyHex: 0x0A0930), location: 1),
                     ]), center: c, startRadius: 0, endRadius: r))

        // Stars: inner ones orbit faster (rot * (1.3 - radius)), winding the arms over time.
        var field = context
        field.opacity = 0.85
        for s in stars {
            let a = s.angle + rot * (1.3 - s.radius)
            let d = s.radius * r
            let dotR = s.dot * w / 176
            let p = CGPoint(x: c.x + cos(a) * d, y: c.y + sin(a) * d)
            field.fill(Path(ellipseIn: CGRect(x: p.x - dotR, y: p.y - dotR, width: dotR * 2, height: dotR * 2)),
                       with: .color(s.color))
        }

        // Glowing core.
        let coreR = r * 0.28
        context.fill(Path(ellipseIn: CGRect(x: c.x - coreR, y: c.y - coreR, width: coreR * 2, height: coreR * 2)),
                     with: .radialGradient(Gradient(colors: [
                        Color(red: 1, green: 220 / 255, blue: 240 / 255).opacity(0.95),
                        Color(red: 1, green: 120 / 255, blue: 190 / 255).opacity(0),
                     ]), center: c, startRadius: 0, endRadius: coreR))
    }
}

private extension Color {
    init(galaxyHex hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}
