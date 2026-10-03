import SwiftUI

/// One AI service shown in the left rail. Each provider is the service's own
/// web app, so it runs under the user's own login and its chats stay synced
/// with the official apps.
enum ProviderID: String, CaseIterable, Codable, Identifiable, Hashable {
    case claude, chatgpt, gemini, deepseek, muse, grok

    var id: String { rawValue }
}

struct Provider: Identifiable, Hashable {
    let id: ProviderID
    let name: String
    let maker: String
    let defaultHomeURL: URL
    /// URL path fragments that identify a single conversation, used to index
    /// chat titles for the global search.
    let conversationPathHints: [String]
    let tint: Color
    /// What this provider is best at. Shown in the UI and given to the router.
    let strengths: String

    static let all: [Provider] = [
        Provider(
            id: .claude, name: "Claude", maker: "Anthropic",
            defaultHomeURL: URL(string: "https://claude.ai/new")!,
            conversationPathHints: ["/chat/"],
            tint: Color(red: 0.85, green: 0.47, blue: 0.34),
            strengths: "coding, debugging, long documents, careful writing and editing, analysis, reports"
        ),
        Provider(
            id: .chatgpt, name: "ChatGPT", maker: "OpenAI",
            defaultHomeURL: URL(string: "https://chatgpt.com/")!,
            conversationPathHints: ["/c/"],
            tint: Color(red: 0.06, green: 0.64, blue: 0.50),
            strengths: "image generation and editing, general questions, brainstorming, voice"
        ),
        Provider(
            id: .gemini, name: "Gemini", maker: "Google",
            defaultHomeURL: URL(string: "https://gemini.google.com/app")!,
            conversationPathHints: ["/app/"],
            tint: Color(red: 0.26, green: 0.52, blue: 0.96),
            strengths: "video generation, Google Search grounded research, YouTube, Gmail, Docs, Maps"
        ),
        Provider(
            id: .deepseek, name: "DeepSeek", maker: "DeepSeek",
            defaultHomeURL: URL(string: "https://chat.deepseek.com/")!,
            conversationPathHints: ["/chat/s/"],
            tint: Color(red: 0.30, green: 0.42, blue: 0.99),
            strengths: "math, step-by-step reasoning, competitive programming puzzles"
        ),
        Provider(
            id: .muse, name: "Muse", maker: "Meta",
            defaultHomeURL: URL(string: "https://www.meta.ai/")!,
            conversationPathHints: ["/prompt/", "/c/"],
            tint: Color(red: 0.00, green: 0.51, blue: 0.98),
            strengths: "casual chat, Instagram/Facebook/WhatsApp content, quick image ideas"
        ),
        Provider(
            id: .grok, name: "Grok", maker: "xAI",
            defaultHomeURL: URL(string: "https://grok.com/")!,
            conversationPathHints: ["/c/", "/chat/"],
            tint: Color(white: 0.15),
            strengths: "breaking news, real-time X/Twitter posts and trends, image and video generation (Imagine)"
        ),
    ]

    static func get(_ id: ProviderID) -> Provider {
        all.first { $0.id == id }!
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

    /// Small favicon used for the rail icon; falls back to a letter tile.
    var iconURL: URL {
        URL(string: "https://www.google.com/s2/favicons?sz=128&domain=\(defaultHomeURL.host ?? "")")!
    }
}

enum SettingsKey {
    static func homeURL(_ id: ProviderID) -> String { "provider.\(id.rawValue).url" }
    static func enabled(_ id: ProviderID) -> String { "provider.\(id.rawValue).enabled" }
    static let autoSend = "universal.autoSend"
    static let smartRouting = "universal.smartRouting"
}
