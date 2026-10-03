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

    static let builtIn: [Provider] = [
        Provider(
            id: .claude, name: "Claude", maker: "Anthropic",
            defaultHomeURL: URL(string: "https://claude.ai/new")!,
            conversationPathHints: ["/chat/"],
            tint: Color(red: 0.85, green: 0.47, blue: 0.34),
            strengths: "coding, debugging, long documents, careful writing and editing, analysis, reports",
            hosts: ["claude.ai", "anthropic.com"]
        ),
        Provider(
            id: .chatgpt, name: "ChatGPT", maker: "OpenAI",
            defaultHomeURL: URL(string: "https://chatgpt.com/")!,
            conversationPathHints: ["/c/"],
            tint: Color(red: 0.06, green: 0.64, blue: 0.50),
            strengths: "image generation and editing, general questions, brainstorming, voice",
            hosts: ["chatgpt.com", "openai.com"]
        ),
        Provider(
            id: .gemini, name: "Gemini", maker: "Google",
            defaultHomeURL: URL(string: "https://gemini.google.com/app")!,
            conversationPathHints: ["/app/"],
            tint: Color(red: 0.26, green: 0.52, blue: 0.96),
            strengths: "video generation, Google Search grounded research, YouTube, Gmail, Docs, Maps",
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
            id: .muse, name: "Muse", maker: "Meta",
            defaultHomeURL: URL(string: "https://www.meta.ai/")!,
            conversationPathHints: ["/prompt/", "/c/"],
            tint: Color(red: 0.00, green: 0.51, blue: 0.98),
            strengths: "casual chat, Instagram/Facebook/WhatsApp content, quick image ideas",
            hosts: ["meta.ai", "meta.com"]
        ),
        Provider(
            id: .xai, name: "xAI", maker: "xAI",
            defaultHomeURL: URL(string: "https://grok.com/")!,
            conversationPathHints: ["/c/", "/chat/"],
            tint: Color(white: 0.15),
            strengths: "xAI's standalone assistant: deep reasoning, real-time web search, image and video generation (Imagine)",
            hosts: ["grok.com", "x.ai"]
        ),
        Provider(
            id: .grok, name: "Grok", maker: "X",
            defaultHomeURL: URL(string: "https://x.com/i/grok")!,
            conversationPathHints: ["conversation="],
            tint: Color(white: 0.05),
            strengths: "the Grok bot inside X: explaining X posts, trends and breaking news on X/Twitter, accounts and threads",
            hosts: ["x.com", "twitter.com"]
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
        URL(string: "https://www.google.com/s2/favicons?sz=128&domain=\(defaultHomeURL.host ?? "")")!
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

    private init() {
        custom = JSONFile.load([CustomProvider].self, from: Self.file) ?? []
    }

    var all: [Provider] { Provider.builtIn + custom.map(\.provider) }

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
    static let shareMemory = "memory.share"
}
