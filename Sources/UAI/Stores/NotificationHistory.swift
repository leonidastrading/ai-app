import Foundation

/// A past "AI replied" notification, kept so you can see what came in while
/// you were elsewhere.
struct NotifItem: Identifiable, Codable, Hashable {
    var id = UUID()
    let provider: ProviderID
    let title: String
    let preview: String
    let date: Date
    let url: String?
    /// Optional so old saved notifications (without this key) still decode.
    /// When true, this is an app-update notice, not an "AI replied" item.
    var isUpdate: Bool? = nil
}

@MainActor
final class NotificationHistory: ObservableObject {
    @Published private(set) var items: [NotifItem] = []
    private static let file = "notifications.json"

    init() { items = JSONFile.load([NotifItem].self, from: Self.file) ?? [] }

    func add(provider: ProviderID, title: String, preview: String, url: String?) {
        items.insert(NotifItem(provider: provider, title: title, preview: preview, date: Date(), url: url), at: 0)
        if items.count > 200 { items.removeLast(items.count - 200) }
        JSONFile.save(items, to: Self.file)
    }

    /// Surface an available app update in the in-app Activity panel (in addition
    /// to the macOS banner + toolbar badge). De-duplicates by version so the
    /// same update isn't listed repeatedly across background checks.
    func addUpdate(version: String) {
        let title = "Version \(version) is ready"
        if items.contains(where: { $0.isUpdate == true && $0.title == title }) { return }
        items.insert(NotifItem(provider: ProviderID(rawValue: "uai"),
                               title: title,
                               preview: "Click to install — or it installs on next relaunch.",
                               date: Date(), url: nil, isUpdate: true), at: 0)
        if items.count > 200 { items.removeLast(items.count - 200) }
        JSONFile.save(items, to: Self.file)
    }

    func clear() {
        items = []
        JSONFile.save(items, to: Self.file)
    }
}
