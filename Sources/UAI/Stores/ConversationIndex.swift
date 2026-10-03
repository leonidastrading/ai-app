import Foundation

/// A chat found in one of the providers' web apps. Collected from the chat
/// list in each provider's sidebar (and the text of chats you open), so the
/// global search can find conversations across every account at once.
struct IndexedConversation: Codable, Identifiable, Hashable {
    var id: String { url }
    let provider: ProviderID
    let url: String
    var title: String
    /// Visible text of the conversation, captured when it was last opened in UAI.
    var body: String
    var lastSeen: Date
}

@MainActor
final class ConversationIndex: ObservableObject {
    @Published private(set) var items: [String: IndexedConversation] = [:]

    private static let file = "conversation-index.json"
    private var saveScheduled = false

    init() {
        let saved = JSONFile.load([IndexedConversation].self, from: Self.file) ?? []
        items = Dictionary(saved.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func upsert(provider: ProviderID, url: String, title: String, body: String?) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var entry = items[url] ?? IndexedConversation(
            provider: provider, url: url, title: cleanTitle, body: "", lastSeen: Date())
        if !cleanTitle.isEmpty { entry.title = cleanTitle }
        if let body, !body.isEmpty { entry.body = String(body.prefix(40_000)) }
        entry.lastSeen = Date()
        if items[url] != entry {
            items[url] = entry
            scheduleSave()
        }
    }

    func search(_ query: String, limit: Int = 60) -> [IndexedConversation] {
        let terms = query.lowercased().split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return [] }
        return items.values
            .compactMap { item -> (IndexedConversation, Int)? in
                let title = item.title.lowercased()
                let body = item.body.lowercased()
                var score = 0
                for term in terms {
                    if title.contains(term) { score += 10 }
                    else if body.contains(term) { score += 1 }
                    else { return nil }
                }
                return (item, score)
            }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.lastSeen > $1.0.lastSeen }
            .prefix(limit)
            .map(\.0)
    }

    /// Chats that share significant words with `text`, with a short excerpt
    /// around the first match. Used to share related history between AIs.
    func related(to text: String, limit: Int) -> [(chat: IndexedConversation, excerpt: String)] {
        let stop: Set<String> = ["about", "after", "again", "also", "because", "been", "before", "being",
                                 "could", "does", "doing", "from", "have", "help", "into", "just", "like",
                                 "make", "more", "most", "need", "please", "should", "some", "than", "that",
                                 "their", "them", "then", "there", "these", "they", "this", "what", "when",
                                 "where", "which", "while", "will", "with", "would", "your", "write", "tell"]
        let terms = Set(text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 4 && !stop.contains($0) })
        guard !terms.isEmpty else { return [] }

        let scored = items.values.compactMap { chat -> (IndexedConversation, Int, String)? in
            let title = chat.title.lowercased()
            let body = chat.body.lowercased()
            var score = 0
            var firstHit: String?
            for term in terms {
                if title.contains(term) { score += 3; firstHit = firstHit ?? term }
                if body.contains(term) { score += 1; firstHit = firstHit ?? term }
            }
            guard score >= 3, let hit = firstHit else { return nil }
            return (chat, score, hit)
        }
        return scored
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.lastSeen > $1.0.lastSeen }
            .prefix(limit)
            .map { chat, _, term in (chat, Self.excerpt(of: chat.body, around: term)) }
    }

    static func excerpt(of body: String, around term: String, radius: Int = 160) -> String {
        guard let range = body.range(of: term, options: .caseInsensitive) else {
            return String(body.prefix(radius * 2)).replacingOccurrences(of: "\n", with: " ")
        }
        let start = body.index(range.lowerBound, offsetBy: -radius, limitedBy: body.startIndex) ?? body.startIndex
        let end = body.index(range.upperBound, offsetBy: radius, limitedBy: body.endIndex) ?? body.endIndex
        return "…" + body[start..<end].replacingOccurrences(of: "\n", with: " ") + "…"
    }

    func count(for provider: ProviderID) -> Int {
        items.values.filter { $0.provider == provider }.count
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            JSONFile.save(Array(self.items.values), to: Self.file)
        }
    }
}
