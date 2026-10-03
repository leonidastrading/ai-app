import Foundation

/// Something UAI remembers about you, shared with every AI.
struct MemoryNote: Codable, Identifiable, Hashable {
    var id = UUID()
    var text: String
    var source: String   // "You" or "Learned from chats"
    var date = Date()
}

/// Shared memory across all your AIs, stored only on this Mac
/// (~/Library/Application Support/UAI/memory.json).
///
/// It has two parts:
/// - notes: facts and preferences about you, written by you or learned
///   from your chats with Claude's help;
/// - your chat history from every AI, captured by the conversation index.
///
/// When you send a prompt (through Universal AI, or with the Memory button
/// in any AI), UAI adds the notes plus excerpts of related past chats from
/// any AI, so each AI knows what you told the others.
@MainActor
final class MemoryStore: ObservableObject {
    @Published private(set) var notes: [MemoryNote] = []
    @Published private(set) var learning = false
    @Published var lastError: String?

    private static let file = "memory.json"
    let index: ConversationIndex

    init(index: ConversationIndex) {
        self.index = index
        notes = JSONFile.load([MemoryNote].self, from: Self.file) ?? []
    }

    var isSharing: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.shareMemory) as? Bool ?? true
    }

    func add(_ text: String, source: String = "You") {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty,
              !notes.contains(where: { $0.text.caseInsensitiveCompare(clean) == .orderedSame }) else { return }
        notes.insert(MemoryNote(text: clean, source: source), at: 0)
        save()
    }

    func update(_ note: MemoryNote, text: String) {
        guard let i = notes.firstIndex(where: { $0.id == note.id }) else { return }
        notes[i].text = text
        save()
    }

    func delete(_ note: MemoryNote) {
        notes.removeAll { $0.id == note.id }
        save()
    }

    func clear() {
        notes = []
        save()
    }

    private func save() { JSONFile.save(notes, to: Self.file) }

    // MARK: - Sharing memory with an AI

    /// Context to put in front of a prompt: memory notes plus excerpts of
    /// related chats from other AIs. Nil when there's nothing relevant.
    func context(for prompt: String, excluding target: ProviderID? = nil) -> String? {
        var parts: [String] = []

        let noteLines = notes.prefix(20).map { "- \($0.text)" }
        if !noteLines.isEmpty {
            parts.append("What I've told my other AIs about me:\n" + noteLines.joined(separator: "\n"))
        }

        let related = index.related(to: prompt, limit: 3)
            .filter { target == nil || $0.chat.provider != target }
        if !related.isEmpty {
            let lines = related.map { item in
                "- \(Provider.get(item.chat.provider).name), \"\(item.chat.title)\": \(item.excerpt)"
            }
            parts.append("Related things I discussed with other AIs:\n" + lines.joined(separator: "\n"))
        }

        guard !parts.isEmpty else { return nil }
        return "[Shared memory from UAI, my app that connects my AIs. Use it if relevant.]\n"
            + parts.joined(separator: "\n\n")
    }

    /// The prompt with shared memory in front of it (if sharing is on and there's anything to share).
    func prompt(_ prompt: String, for target: ProviderID?) -> String {
        guard isSharing, let context = context(for: prompt, excluding: target) else { return prompt }
        return context + "\n\n[My message]\n" + prompt
    }

    // MARK: - Learning from chats (optional, uses Claude)

    /// Sends your most recently captured chats to Claude and saves the
    /// lasting facts and preferences it finds as memory notes.
    func learnFromChats() async {
        guard !learning else { return }
        learning = true
        lastError = nil
        defer { learning = false }

        let chats = index.items.values
            .filter { !$0.body.isEmpty }
            .sorted { $0.lastSeen > $1.lastSeen }
            .prefix(15)
        guard !chats.isEmpty else {
            lastError = "No chats captured yet. Open a few chats in any AI first."
            return
        }

        let transcript = chats.map { chat in
            "### \(Provider.get(chat.provider).name): \(chat.title)\n\(chat.body.prefix(3000))"
        }.joined(separator: "\n\n")

        let existing = notes.map { "- \($0.text)" }.joined(separator: "\n")

        let system = """
        You maintain a shared memory for a person who uses several AI assistants. From the chat \
        transcripts, extract durable facts about the person that would help any assistant help them \
        in future: their projects, goals, preferences, tools they use, their writing style, recurring \
        topics. Write each as one short first-person sentence ("I trade options on the S&P 500"). \
        Skip one-off questions, anything already in the existing memory, and sensitive details such \
        as passwords, account numbers, health or financial account information. Return at most 12.
        """

        let user = "Existing memory:\n\(existing.isEmpty ? "(none)" : existing)\n\nRecent chats:\n\(transcript)"

        let schema: [String: Any] = [
            "type": "object",
            "properties": ["facts": ["type": "array", "items": ["type": "string"]]],
            "required": ["facts"],
            "additionalProperties": false,
        ]

        do {
            let result = try await AnthropicClient.structured(
                system: system, user: user, schema: schema,
                effort: "medium", maxTokens: 16000, timeout: 180)
            let facts = result["facts"] as? [String] ?? []
            for fact in facts.reversed() { add(fact, source: "Learned from chats") }
            if facts.isEmpty { lastError = "Nothing new to remember." }
        } catch {
            lastError = error.localizedDescription
        }
    }
}
