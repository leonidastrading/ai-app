import Foundation

/// An attachment carried with a recent prompt (synced from another app, e.g.
/// the web "Send to UAI"). `dataURL` is a small image thumbnail when present.
struct RecentAttachment: Codable, Hashable {
    var name: String
    var type: String?
    var dataURL: String?   // small inline thumbnail (images)
    var url: String?       // Storage download URL for the original file
}

/// A prompt you sent to any AI — typed directly in that AI, or routed through
/// Universal AI. Shown in the right bar's "Recent" section.
struct RecentPrompt: Codable, Identifiable, Hashable {
    var id = UUID()
    let provider: ProviderID
    let text: String
    let date: Date
    var attachments: [RecentAttachment]? = nil
}

/// Recent prompts across every AI, captured as you send them. Stored on this Mac.
@MainActor
final class GlobalRecents: ObservableObject {
    @Published private(set) var items: [RecentPrompt] = []
    private static let file = "recents.json"

    init() { items = JSONFile.load([RecentPrompt].self, from: Self.file) ?? [] }

    func add(provider: ProviderID, text raw: String) {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Prompts routed through Universal AI carry a shared-memory preamble; keep
        // only the real message so Recent shows what you actually asked.
        if let r = t.range(of: "[My message]\n", options: .backwards) {
            t = String(t[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !t.isEmpty, t.count <= 2000 else { return }
        // Ignore an immediate repeat (e.g. an Enter keydown and a send click for
        // the same message).
        if let first = items.first, first.provider == provider, first.text == t { return }
        items.insert(RecentPrompt(provider: provider, text: t, date: Date()), at: 0)
        if items.count > 100 { items.removeLast(items.count - 100) }
        JSONFile.save(items, to: Self.file)
    }

    func clear() {
        items = []
        JSONFile.save(items, to: Self.file)
    }

    /// Replace all items (from a cloud pull).
    func replaceAll(_ newItems: [RecentPrompt]) {
        items = Array(newItems.prefix(100))
        JSONFile.save(items, to: Self.file)
    }
}
