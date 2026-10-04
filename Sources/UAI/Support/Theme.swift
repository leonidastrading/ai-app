import SwiftUI

/// Colorway taken from the shoe: hot pink upper, indigo-violet midsole,
/// aqua outsole and light gray knit.
enum Theme {
    static let pink = Color(red: 0.95, green: 0.40, blue: 0.62)        // #F2669E
    static let indigo = Color(red: 0.27, green: 0.29, blue: 0.78)      // #4549C7
    static let violet = Color(red: 0.47, green: 0.38, blue: 0.86)      // #7861DB
    static let aqua = Color(red: 0.45, green: 0.74, blue: 0.80)        // #73BDCC
    static let mesh = Color(red: 0.94, green: 0.94, blue: 0.95)        // #F0F0F2
    static let space = Color(red: 0.08, green: 0.07, blue: 0.20)
    /// The flat near-black used behind every window and web view, so nothing
    /// ever flashes white. Matches the user-provided background.
    static let windowBackground = Color(red: 0.102, green: 0.102, blue: 0.102)   // #1A1A1A
    static let windowBackgroundNS = NSColor(red: 0.102, green: 0.102, blue: 0.102, alpha: 1)

    /// Left rail: the midsole fade, indigo into violet into pink, landing on aqua.
    static let rail = LinearGradient(
        stops: [.init(color: indigo, location: 0),
                .init(color: violet, location: 0.35),
                .init(color: pink.opacity(0.95), location: 0.70),
                .init(color: aqua, location: 1)],
        startPoint: .top, endPoint: .bottom)

    /// Top bar: the diagonal stripe band, indigo to pink.
    static let toolbar = LinearGradient(colors: [indigo, violet, pink],
                                        startPoint: .leading, endPoint: .trailing)

    static let searchField = Color.white.opacity(0.22)
    static let selectionRing = Color.white
    static let accent = pink
    /// Content area background (near-black, same as every window).
    static let contentBackground = windowBackground
    static let card = Color.white.opacity(0.06)
}
