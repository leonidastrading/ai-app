import SwiftUI

/// Slack-inspired palette.
enum Theme {
    static let rail = Color(red: 0.15, green: 0.04, blue: 0.16)          // deep aubergine
    static let toolbar = Color(red: 0.25, green: 0.08, blue: 0.26)       // Slack top bar
    static let sidebar = Color(red: 0.25, green: 0.08, blue: 0.26)
    static let searchField = Color.white.opacity(0.14)
    static let selectionRing = Color.white
    static let accent = Color(red: 0.07, green: 0.39, blue: 0.64)        // Slack blue
    static let universalGradient = LinearGradient(
        colors: [Color(red: 0.88, green: 0.12, blue: 0.35),
                 Color(red: 0.93, green: 0.70, blue: 0.18),
                 Color(red: 0.18, green: 0.71, blue: 0.49),
                 Color(red: 0.21, green: 0.77, blue: 0.94)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
}
