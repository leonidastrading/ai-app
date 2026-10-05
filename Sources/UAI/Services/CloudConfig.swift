import Foundation

/// Firebase + Google OAuth configuration for UAI cloud sign-in & sync.
///
/// These placeholder values are overwritten in CI (.github/workflows/build.yml)
/// from GitHub Actions secrets before the app is built, so real credentials
/// never live in git. The Google client secret for a Desktop ("installed") app
/// is not truly confidential — Google's loopback flow ships it inside the app.
enum CloudConfig {
    static let firebaseApiKey = "YOUR_FIREBASE_API_KEY"
    static let projectId = "YOUR_FIREBASE_PROJECT_ID"
    static let googleClientId = "YOUR_GOOGLE_DESKTOP_CLIENT_ID"
    static let googleClientSecret = "YOUR_GOOGLE_DESKTOP_CLIENT_SECRET"

    /// True once real credentials have been baked in (CI build).
    static var isConfigured: Bool { !googleClientId.hasPrefix("YOUR_") }
}
