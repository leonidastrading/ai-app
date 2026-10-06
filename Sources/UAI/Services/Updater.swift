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
final class Updater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    /// True once Sparkle has found a newer version (drives the in-app badge).
    @Published private(set) var updateAvailable = false
    @Published private(set) var availableVersion = ""

    /// True when this build carries a Sparkle public key, so updates are live.
    let isConfigured: Bool

    /// Called on the main thread the first time a given newer version is found,
    /// so the app can also surface it in the in-app Activity panel (not just as
    /// a macOS banner + toolbar badge).
    var onUpdateFound: (@MainActor (String) -> Void)?

    private var controller: SPUStandardUpdaterController?
    private var notifiedVersion = ""

    override init() {
        let key = (Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        isConfigured = !key.isEmpty && key != "__SPARKLE_PUBKEY__"
        super.init()

        guard isConfigured else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
        // Silently check a few seconds after launch (Sparkle's own schedule is
        // hourly), so the in-app "Update available" badge/notification appears
        // promptly when a newer build exists. Shows UI only if one is found.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak controller] in
            controller?.updater.checkForUpdatesInBackground()
        }
    }

    func checkForUpdates() {
        controller?.updater.checkForUpdates()
    }

    // MARK: - SPUUpdaterDelegate (detect a new version for the in-app badge)

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Task { @MainActor in
            self.updateAvailable = true
            self.availableVersion = version
            if self.notifiedVersion != version {
                self.notifiedVersion = version
                Notifier.shared.announce(title: "UAI update available",
                                         body: "Version \(version) is ready — it will install on the next relaunch, or update now from the toolbar.")
                self.onUpdateFound?(version)
            }
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in self.updateAvailable = false }
    }

    /// App version shown in Settings (e.g. "0.1.37").
    static var versionString: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        return short
    }
}
