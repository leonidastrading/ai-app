import AppKit
import UserNotifications

/// Posts "Claude replied" style notifications and routes clicks back to the
/// right AI.
///
/// Delivery always goes through `UNUserNotificationCenter` (the only API modern
/// macOS actually displays). We never gate it on a cached "authorized" flag,
/// which could get stuck and silently route every notification into the void.
/// On top of the banner we also chime and bounce the Dock, so a reply is
/// noticeable even if the OS suppresses the banner.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Called on the main thread when a notification is clicked.
    var onOpen: ((ProviderID) -> Void)?

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.notifications) as? Bool ?? true
    }

    var soundEnabled: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.notificationSound) as? Bool ?? true
    }

    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // Prompt once if undecided. Whatever the answer, delivery always goes
        // through UNUserNotificationCenter below: the result here is only used
        // to prompt, never to gate delivery (a cached "not ready" used to get
        // stuck and silently route every notification to a dead API).
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
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

        deliverModern(provider: provider, subtitle: subtitle, body: body)
    }

    /// A generic notification not tied to any AI (e.g. "update available").
    func announce(title: String, body: String) {
        guard isEnabled else { return }
        DispatchQueue.main.async {
            if self.soundEnabled { NSSound(named: "Glass")?.play() }
            if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = soundEnabled ? .default : nil
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { _ in }
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
        UNUserNotificationCenter.current().add(request) { _ in }
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

}
