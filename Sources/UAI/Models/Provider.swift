import SwiftUI

/// Identifies one AI in the rail. Built-in AIs have fixed IDs; AIs you add
/// with the + button get a generated one.
struct ProviderID: RawRepresentable, Hashable, Codable, Identifiable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    var id: String { rawValue }

    static let claude = ProviderID(rawValue: "claude")
    static let chatgpt = ProviderID(rawValue: "chatgpt")
    static let gemini = ProviderID(rawValue: "gemini")
    static let deepseek = ProviderID(rawValue: "deepseek")
    static let muse = ProviderID(rawValue: "muse")
    static let xai = ProviderID(rawValue: "xai")
    static let grok = ProviderID(rawValue: "grok")
    static let vercel = ProviderID(rawValue: "vercel")
}

/// One AI service shown in the left rail. Each provider is the service's own
/// web app, so it runs under the user's own login and its chats stay synced
/// with the official apps.
struct Provider: Identifiable, Hashable {
    let id: ProviderID
    let name: String
    let maker: String
    let defaultHomeURL: URL
    /// URL fragments (path or query) that identify a single conversation,
    /// used to index chat titles for the global search.
    let conversationPathHints: [String]
    let tint: Color
    /// What this provider is best at. Shown in the UI and given to the router.
    let strengths: String
    /// Hosts that belong to this AI, including its sign-in pages. Used to open
    /// emailed sign-in links in the right AI.
    let hosts: [String]
    var isCustom = false
    /// Circle color for logos that sit on a solid tile, used if it can't be
    /// read from the logo itself.
    var iconFill: Color? = nil
    /// Explicit icon URL when the site's favicon is wrong or missing.
    var iconURLOverride: URL? = nil
    /// Name of a bundled image (in Resources) to use instead of the favicon.
    var localIcon: String? = nil

    static let builtIn: [Provider] = [
        Provider(
            id: .claude, name: "Claude", maker: "Anthropic",
            defaultHomeURL: URL(string: "https://claude.ai/new")!,
            conversationPathHints: ["/chat/"],
            tint: Color(red: 0.85, green: 0.47, blue: 0.34),
            strengths: "coding, debugging, long documents, careful writing and editing, analysis, reports",
            hosts: ["claude.ai", "anthropic.com"],
            iconFill: Color(red: 0.85, green: 0.47, blue: 0.34)
        ),
        Provider(
            id: .chatgpt, name: "ChatGPT", maker: "OpenAI",
            defaultHomeURL: URL(string: "https://chatgpt.com/")!,
            conversationPathHints: ["/c/"],
            tint: Color(red: 0.06, green: 0.64, blue: 0.50),
            strengths: "general questions, brainstorming, voice chat, image generation as a second choice",
            hosts: ["chatgpt.com", "openai.com"]
        ),
        Provider(
            id: .gemini, name: "Gemini", maker: "Google",
            defaultHomeURL: URL(string: "https://gemini.google.com/app")!,
            conversationPathHints: ["/app/"],
            tint: Color(red: 0.26, green: 0.52, blue: 0.96),
            strengths: "image generation and photo editing (Nano Banana, the best image model), video generation (Veo), Google Search grounded research, YouTube, Gmail, Docs, Maps",
            hosts: ["gemini.google.com"]
        ),
        Provider(
            id: .deepseek, name: "DeepSeek", maker: "DeepSeek",
            defaultHomeURL: URL(string: "https://chat.deepseek.com/")!,
            conversationPathHints: ["/chat/s/"],
            tint: Color(red: 0.30, green: 0.42, blue: 0.99),
            strengths: "math, step-by-step reasoning, competitive programming puzzles",
            hosts: ["deepseek.com"]
        ),
        Provider(
            id: .muse, name: "Muse", maker: "muse.ai",
            defaultHomeURL: URL(string: "https://muse.ai/")!,
            conversationPathHints: ["/chat/", "/c/", "/search"],
            tint: Color(red: 0.54, green: 0.28, blue: 0.86),
            strengths: "a personal AI assistant with long-term memory and an avatar: everyday help, reminders, proactive updates, web browsing, and doing multi-step tasks across your connected accounts (email, calendar, shopping, YouTube)",
            hosts: ["muse.ai"]
        ),
        Provider(
            id: .xai, name: "xAI", maker: "xAI",
            defaultHomeURL: URL(string: "https://grok.com/")!,
            conversationPathHints: ["/c/", "/chat/"],
            tint: Color(white: 0.15),
            strengths: "xAI's standalone assistant: deep reasoning, real-time web search, image and video generation (Imagine)",
            hosts: ["grok.com", "x.ai"],
            iconFill: .black
        ),
        Provider(
            id: .grok, name: "Grok Bot", maker: "X",
            defaultHomeURL: URL(string: "https://x.com/i/grok")!,
            conversationPathHints: ["conversation="],
            tint: Color(white: 0.05),
            strengths: "the Grok bot inside X: explaining X posts, trends and breaking news on X/Twitter, accounts and threads",
            hosts: ["x.com", "twitter.com"],
            iconFill: .black,
            localIcon: "GrokBot"
        ),
        Provider(
            id: .vercel, name: "Vercel", maker: "Vercel v0",
            defaultHomeURL: URL(string: "https://v0.app/")!,
            conversationPathHints: ["/chat/"],
            tint: .black,
            strengths: "building websites, web apps and UI from a description: React, Next.js, Tailwind, landing pages, dashboards, prototypes, deploying to Vercel",
            hosts: ["v0.app", "v0.dev", "vercel.com"],
            iconFill: .black
        ),
    ]

    /// Built-in AIs followed by the ones you added.
    static var all: [Provider] { ProviderRegistry.shared.all }

    static func get(_ id: ProviderID) -> Provider {
        all.first { $0.id == id } ?? builtIn.first { $0.id == id } ?? Provider(
            id: id, name: "Removed AI", maker: "", defaultHomeURL: URL(string: "about:blank")!,
            conversationPathHints: [], tint: .gray, strengths: "", hosts: [], isCustom: true)
    }

    /// The provider whose hosts include `url`'s host.
    static func matching(_ url: URL) -> Provider? {
        guard let host = url.host?.lowercased() else { return nil }
        return all.first { p in p.hosts.contains { host == $0 || host.hasSuffix("." + $0) } }
    }

    /// The home URL, honoring a custom URL set in Settings.
    var homeURL: URL {
        if let custom = UserDefaults.standard.string(forKey: SettingsKey.homeURL(id)),
           let url = URL(string: custom), url.scheme?.hasPrefix("http") == true {
            return url
        }
        return defaultHomeURL
    }

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.enabled(id)) as? Bool ?? true
    }

    /// Small favicon used for the rail icon; falls back to a letter badge.
    var iconURL: URL {
        iconURLOverride
            ?? URL(string: "https://www.google.com/s2/favicons?sz=128&domain=\(defaultHomeURL.host ?? "")")!
    }
}

/// An AI you added with the + button.
struct CustomProvider: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var url: String
    var strengths: String

    var provider: Provider {
        let home = URL(string: url) ?? URL(string: "about:blank")!
        let palette: [Color] = [Theme.pink, Theme.indigo, Theme.violet, Theme.aqua]
        let host = home.host?.lowercased().replacingOccurrences(of: "www.", with: "") ?? ""
        return Provider(
            id: ProviderID(rawValue: id), name: name, maker: host,
            defaultHomeURL: home,
            conversationPathHints: ["/c/", "/chat/", "/conversation/", "/thread/", "/search/"],
            tint: palette[id.unicodeScalars.reduce(0) { $0 + Int($1.value) } % palette.count],
            strengths: strengths.isEmpty ? "general questions" : strengths,
            hosts: host.isEmpty ? [] : [host],
            isCustom: true)
    }
}

/// Holds the AIs you added. Saved in Application Support.
final class ProviderRegistry: ObservableObject {
    static let shared = ProviderRegistry()
    private static let file = "custom-ais.json"

    @Published private(set) var custom: [CustomProvider]
    /// Rail order you set by dragging icons (provider IDs).
    @Published private(set) var order: [String]
    private static let orderKey = "rail.order"

    private init() {
        custom = JSONFile.load([CustomProvider].self, from: Self.file) ?? []
        order = UserDefaults.standard.stringArray(forKey: Self.orderKey) ?? []
    }

    /// All AIs in rail order. AIs not yet placed (new built-ins, new
    /// additions) keep their natural position at the end.
    var all: [Provider] {
        let natural = Provider.builtIn + custom.map(\.provider)
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return natural.enumerated()
            .sorted { a, b in
                let ra = rank[a.element.id.rawValue], rb = rank[b.element.id.rawValue]
                switch (ra, rb) {
                case let (x?, y?): return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.offset < b.offset
                }
            }
            .map(\.element)
    }

    /// Moves `id` to the position of `target` (dragging in the rail).
    func move(_ id: ProviderID, to target: ProviderID) {
        guard id != target else { return }
        var ids = all.map(\.id.rawValue)
        guard let from = ids.firstIndex(of: id.rawValue), let to = ids.firstIndex(of: target.rawValue) else { return }
        ids.remove(at: from)
        ids.insert(id.rawValue, at: to)
        save(ids)
    }

    /// Moves `id` up or down by `offset` positions (right-click menu).
    func move(_ id: ProviderID, by offset: Int) {
        var ids = all.map(\.id.rawValue)
        guard let from = ids.firstIndex(of: id.rawValue) else { return }
        let to = max(0, min(ids.count - 1, from + offset))
        guard to != from else { return }
        let moved = ids.remove(at: from)
        ids.insert(moved, at: to)
        save(ids)
    }

    func moveToTop(_ id: ProviderID) {
        var ids = all.map(\.id.rawValue)
        guard let from = ids.firstIndex(of: id.rawValue), from != 0 else { return }
        let moved = ids.remove(at: from)
        ids.insert(moved, at: 0)
        save(ids)
    }

    func isFirst(_ id: ProviderID) -> Bool { all.first?.id == id }
    func isLast(_ id: ProviderID) -> Bool { all.last?.id == id }

    private func save(_ ids: [String]) {
        order = ids
        UserDefaults.standard.set(ids, forKey: Self.orderKey)
    }

    @discardableResult
    func add(name: String, url: URL, strengths: String) -> ProviderID {
        let id = "custom-" + UUID().uuidString.prefix(8).lowercased()
        custom.append(CustomProvider(id: id, name: name, url: url.absoluteString, strengths: strengths))
        JSONFile.save(custom, to: Self.file)
        return ProviderID(rawValue: id)
    }

    func remove(_ id: ProviderID) {
        custom.removeAll { $0.id == id.rawValue }
        JSONFile.save(custom, to: Self.file)
    }
}

enum SettingsKey {
    static func homeURL(_ id: ProviderID) -> String { "provider.\(id.rawValue).url" }
    static func enabled(_ id: ProviderID) -> String { "provider.\(id.rawValue).enabled" }
    static let autoSend = "universal.autoSend"
    static let smartRouting = "universal.smartRouting"
    static let notifications = "notifications.replies"
    static let notificationSound = "notifications.sound"
    static let shareMemory = "memory.share"
    static let autoCaptureMedia = "media.autoCapture"
}
