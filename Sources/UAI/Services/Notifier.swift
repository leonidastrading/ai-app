import AppKit
import UserNotifications

/// Posts "Claude replied" style notifications and routes clicks back to the
/// right AI.
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
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func replied(_ provider: Provider, title: String, preview: String) {
        guard isEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(provider.name) replied"
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanTitle.isEmpty && cleanTitle != provider.name { content.subtitle = cleanTitle }
        content.body = preview.isEmpty ? "Your answer is ready." : preview
        content.sound = soundEnabled ? .default : nil
        content.threadIdentifier = provider.id.rawValue
        content.userInfo = ["provider": provider.id.rawValue]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
        // Also play an audible chime directly, so you hear it even when banners are muted.
        if soundEnabled { NSSound(named: "Glass")?.play() }
    }

    /// Opens System Settings at UAI's notification settings.
    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // Show banners even while UAI is open (you may be in a different AI).
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let raw = response.notification.request.content.userInfo["provider"] as? String {
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                self.onOpen?(ProviderID(rawValue: raw))
            }
        }
        completionHandler()
    }
}
