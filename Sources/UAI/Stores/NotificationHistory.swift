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

    func clear() {
        items = []
        JSONFile.save(items, to: Self.file)
    }
}
