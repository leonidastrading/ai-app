import Foundation

/// A prompt sent through Universal AI and where it was routed.
struct RoutedPrompt: Codable, Identifiable, Hashable {
    var id = UUID()
    let date: Date
    let prompt: String
    let provider: ProviderID
    let reason: String
    let routedBy: String  // "Claude", "Rules", or "UAI" (sent to UAI, not routed)
    var attachments: [RecentAttachment]? = nil
}

@MainActor
final class UniversalStore: ObservableObject {
    @Published private(set) var history: [RoutedPrompt] = []
    private static let file = "universal-history.json"

    init() {
        history = JSONFile.load([RoutedPrompt].self, from: Self.file) ?? []
    }

    func add(_ entry: RoutedPrompt) {
        history.insert(entry, at: 0)
        if history.count > 500 { history.removeLast(history.count - 500) }
        JSONFile.save(history, to: Self.file)
    }

    func clear() {
        history = []
        JSONFile.save(history, to: Self.file)
    }

    /// Replace all history (from a cloud pull).
    func replaceAll(_ items: [RoutedPrompt]) {
        history = Array(items.prefix(500))
        JSONFile.save(history, to: Self.file)
    }

    func search(_ query: String) -> [RoutedPrompt] {
        let q = query.lowercased()
        return history.filter { $0.prompt.lowercased().contains(q) }
    }
}
