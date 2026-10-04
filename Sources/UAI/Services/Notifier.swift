import AppKit
import UserNotifications

/// Posts "Claude replied" style notifications and routes clicks back to the
/// right AI.
///
/// Delivery is layered so it works even for a side-loaded, ad-hoc-signed app:
/// `UNUserNotificationCenter` is used when the system actually authorized it,
/// otherwise we fall back to the older `NSUserNotification` (which needs no
/// authorization and keeps working for non-notarized apps). On top of either,
/// we always chime and bounce the Dock, so a reply is noticeable even when the
/// OS suppresses banners for an unsigned app.
final class Notifier: NSObject, UNUserNotificationCenterDelegate, NSUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Called on the main thread when a notification is clicked.
    var onOpen: ((ProviderID) -> Void)?

    /// Whether modern UserNotifications banners are actually authorized.
    private var modernReady = false

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.notifications) as? Bool ?? true
    }

    var soundEnabled: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.notificationSound) as? Bool ?? true
    }

    func start() {
        NSUserNotificationCenter.default.delegate = self
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, _ in
            self?.modernReady = granted
        }
        // Re-check actual status (authorization can already exist from a prior run).
        center.getNotificationSettings { [weak self] settings in
            let ok = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            if ok { self?.modernReady = true }
        }
    }

    func replied(_ provider: Provider, title: String, preview: String) {
        guard isEnabled else { return }
        let body = preview.isEmpty ? "Your answer is ready." : preview
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let subtitle = (!cleanTitle.isEmpty && cleanTitle != provider.name) ? cleanTitle : nil

        // Always: chime and bounce the Dock. These work with no authorization
        // and no signing, so you still notice even if banners are suppressed.
        DispatchQueue.main.async {
            if self.soundEnabled { NSSound(named: "Glass")?.play() }
            if !NSApp.isActive { NSApp.requestUserAttention(.criticalRequest) }
        }

        if modernReady {
            deliverModern(provider: provider, subtitle: subtitle, body: body)
        } else {
            deliverLegacy(provider: provider, subtitle: subtitle, body: body)
        }
    }

    private func deliverModern(provider: Provider, subtitle: String?, body: String) {
        let content = UNMutableNotificationContent()
        content.title = "\(provider.name) replied"
        if let subtitle { content.subtitle = subtitle }
        content.body = body
        content.sound = soundEnabled ? .default : nil
        content.threadIdentifier = provider.id.rawValue
        content.userInfo = ["provider": provider.id.rawValue]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            // If the modern API rejects it (common for ad-hoc apps), fall back.
            if error != nil {
                self?.modernReady = false
                DispatchQueue.main.async { self?.deliverLegacy(provider: provider, subtitle: subtitle, body: body) }
            }
        }
    }

    private func deliverLegacy(provider: Provider, subtitle: String?, body: String) {
        let n = NSUserNotification()
        n.title = "\(provider.name) replied"
        if let subtitle { n.subtitle = subtitle }
        n.informativeText = body
        if soundEnabled { n.soundName = NSUserNotificationDefaultSoundName }
        n.userInfo = ["provider": provider.id.rawValue]
        NSUserNotificationCenter.default.deliver(n)
    }

    /// Opens System Settings at UAI's notification settings.
    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func open(providerRaw raw: String) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            self.onOpen?(ProviderID(rawValue: raw))
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    // Show banners even while UAI is open (you may be in a different AI).
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let raw = response.notification.request.content.userInfo["provider"] as? String { open(providerRaw: raw) }
        completionHandler()
    }

    // MARK: NSUserNotificationCenterDelegate (legacy fallback)

    func userNotificationCenter(_ center: NSUserNotificationCenter, shouldPresent notification: NSUserNotification) -> Bool {
        true   // show even when UAI is frontmost
    }

    func userNotificationCenter(_ center: NSUserNotificationCenter, didActivate notification: NSUserNotification) {
        if let raw = notification.userInfo?["provider"] as? String { open(providerRaw: raw) }
    }
}
