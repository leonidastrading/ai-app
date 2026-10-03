import SwiftUI

/// Universal AI's icon: a spiral galaxy in the app's colorway.
struct GalaxyIcon: View {
    var size: CGFloat = 48

    var body: some View {
        Canvas { context, canvasSize in
            let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            let radius = min(canvasSize.width, canvasSize.height) / 2

            // Deep-space background with a violet glow.
            let disc = Path(ellipseIn: CGRect(origin: .zero, size: canvasSize))
            context.fill(disc, with: .radialGradient(
                Gradient(colors: [Theme.violet.opacity(0.9), Theme.indigo, Theme.space]),
                center: center, startRadius: 0, endRadius: radius))

            // Background stars.
            var rng = SeededRandom(seed: 7)
            for _ in 0..<26 {
                let p = CGPoint(x: rng.next() * canvasSize.width, y: rng.next() * canvasSize.height)
                let s = 0.4 + rng.next() * radius * 0.035
                context.fill(Path(ellipseIn: CGRect(x: p.x, y: p.y, width: s, height: s)),
                             with: .color(.white.opacity(0.35 + rng.next() * 0.5)))
            }

            // Two logarithmic spiral arms made of glowing dots, pink then aqua.
            let arms: [(Double, Color)] = [(0, Theme.pink), (.pi, Theme.aqua)]
            for (offset, color) in arms {
                for i in 0..<70 {
                    let t = Double(i) / 70
                    let angle = offset + t * 3.4 * .pi
                    let r = radius * (0.10 + 0.78 * t)
                    let jitter = (rng.next() - 0.5) * radius * 0.10
                    let x = center.x + CGFloat(cos(angle)) * (r + jitter)
                    let y = center.y + CGFloat(sin(angle)) * (r + jitter) * 0.82
                    let dot = radius * (0.075 - 0.05 * t)
                    let shade = t < 0.25 ? Color.white : color
                    context.fill(Path(ellipseIn: CGRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot)),
                                 with: .color(shade.opacity(0.95 - 0.5 * t)))
                }
            }

            // Bright core.
            let core = CGRect(x: center.x - radius * 0.32, y: center.y - radius * 0.32,
                              width: radius * 0.64, height: radius * 0.64)
            context.fill(Path(ellipseIn: core), with: .radialGradient(
                Gradient(colors: [.white, Theme.pink.opacity(0.7), .clear]),
                center: center, startRadius: 0, endRadius: radius * 0.32))
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

/// Deterministic random numbers so the galaxy looks the same every launch.
private struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 }
    mutating func next() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat(state >> 11) / CGFloat(1 << 53)
    }
}
