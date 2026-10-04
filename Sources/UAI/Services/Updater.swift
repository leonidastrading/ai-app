import Combine
import Sparkle
import SwiftUI

/// Wraps Sparkle's standard updater — the macOS counterpart to the Windows
/// app's electron-updater. It checks the appcast feed (SUFeedURL in Info.plist),
/// verifies each update with the embedded EdDSA public key (SUPublicEDKey), and
/// (with SUAutomaticallyUpdate on) downloads and installs new builds in the
/// background, prompting to relaunch. "Check for Updates…" drives it manually.
///
/// Updates are only wired up once an EdDSA public key has been baked into the
/// build. Before that (while you're still setting up signing), `isConfigured`
/// is false, the updater never starts, and no error alert is shown on launch.
@MainActor
final class Updater: ObservableObject {
    @Published private(set) var canCheckForUpdates = false

    /// True when this build carries a Sparkle public key, so updates are live.
    let isConfigured: Bool

    private let controller: SPUStandardUpdaterController?

    init() {
        let key = (Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        isConfigured = !key.isEmpty && key != "__SPARKLE_PUBKEY__"

        guard isConfigured else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller?.updater.checkForUpdates()
    }

    /// App version shown in Settings (e.g. "0.1.37").
    static var versionString: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        return short
    }
}
