import Foundation

struct RouteDecision: Equatable {
    let provider: ProviderID
    let reason: String
    let routedBy: String
}

/// Decides which AI should handle a prompt sent to Universal AI.
///
/// Two strategies:
/// - `rules`: instant, offline keyword matching.
/// - `claude`: asks Claude (via an optional Anthropic API key in Settings)
///   to pick, falling back to rules if the call fails.
enum Router {
    static func route(_ prompt: String, among enabled: [ProviderID]) async -> RouteDecision {
        let smart = UserDefaults.standard.object(forKey: SettingsKey.smartRouting) as? Bool ?? true
        if smart, let key = AnthropicClient.apiKey,
           let decision = try? await ClaudeRouter.route(prompt, among: enabled, apiKey: key) {
            return decision
        }
        return rules(prompt, among: enabled)
    }

    // MARK: Rules

    private struct Rule {
        let providers: [ProviderID]  // in order of preference
        let reason: String
        let keywords: [String]
    }

    private static let rulesTable: [Rule] = [
        Rule(providers: [.gemini, .xai], reason: "Video generation",
             keywords: ["video", "animate", "animation", "clip", "footage", "veo", "short film", "reel"]),
        Rule(providers: [.gemini, .chatgpt, .xai], reason: "Image generation (Nano Banana)",
             keywords: ["image", "picture", "photo", "draw", "drawing", "illustrat", "logo", "poster",
                        "wallpaper", "render", "sketch", "painting", "avatar", "icon", "generate a pic"]),
        Rule(providers: [.grok, .xai], reason: "Posts and trends on X",
             keywords: ["tweet", "twitter", "x.com", " on x ", "this post", "thread", "trending", "elon", "viral"]),
        Rule(providers: [.xai, .grok], reason: "Real-time news",
             keywords: ["news", "today", "latest", "right now", "this week", "breaking", "live score", "stock price"]),
        Rule(providers: [.vercel, .claude], reason: "Building a website or app UI",
             keywords: ["website", "web site", "landing page", "web app", "webapp", "frontend", "front-end",
                        "next.js", "nextjs", "react", "tailwind", "dashboard", "prototype", "ui ", "deploy",
                        "build me a site", "portfolio site"]),
        Rule(providers: [.claude], reason: "Coding",
             keywords: ["code", "coding", "bug", "debug", "function", "compile", "error:", "stack trace",
                        "swift", "python", "javascript", "typescript", "sql", "regex", "api", "refactor",
                        "unit test", "github", "script", "html", "css", "rust", "java "]),
        Rule(providers: [.deepseek, .claude], reason: "Math and step-by-step reasoning",
             keywords: ["solve", "equation", "integral", "derivative", "proof", "prove", "calculate",
                        "probability", "math", "algebra", "geometry", "theorem", "puzzle"]),
        Rule(providers: [.gemini], reason: "Google services and web research",
             keywords: ["youtube", "gmail", "google doc", "google sheet", "google drive", "maps",
                        "directions", "nearby", "research", "sources", "cite"]),
        Rule(providers: [.muse], reason: "Personal assistant task",
             keywords: ["remind me", "my email", "my inbox", "my calendar", "keep an eye", "notify me",
                        "my accounts", "do this for me", "every morning", "book ", "order me", "schedule a"]),
        Rule(providers: [.claude], reason: "Writing, editing and reports",
             keywords: ["write", "essay", "email", "letter", "report", "summarize", "summary", "edit",
                        "proofread", "rewrite", "document", "pdf", "contract", "analyze", "analysis"]),
    ]

    static func rules(_ prompt: String, among enabled: [ProviderID]) -> RouteDecision {
        let text = " " + prompt.lowercased() + " "
        var best: (Rule, Int)?
        for rule in rulesTable {
            let hits = rule.keywords.filter { text.contains($0) }.count
            if hits > 0, hits > (best?.1 ?? 0), rule.providers.contains(where: enabled.contains) {
                best = (rule, hits)
            }
        }
        if let rule = best?.0, let provider = rule.providers.first(where: enabled.contains) {
            return RouteDecision(provider: provider, reason: rule.reason, routedBy: "Rules")
        }
        let fallback: ProviderID = enabled.contains(.claude) ? .claude : (enabled.first ?? .claude)
        return RouteDecision(provider: fallback, reason: "General question", routedBy: "Rules")
    }
}

/// Routes with Claude: it reads the prompt and the list of AIs (including
/// ones you added) and picks one.
enum ClaudeRouter {
    static func route(_ prompt: String, among enabled: [ProviderID], apiKey: String) async throws -> RouteDecision {
        let catalog = enabled.map { id in
            let p = Provider.get(id)
            return "- \(id.rawValue): \(p.name) by \(p.maker). Best for: \(p.strengths)."
        }.joined(separator: "\n")

        let system = """
        You are the router inside UAI, a Mac app that gives one user access to several AI assistants \
        through their own accounts. Pick the single assistant best suited to the user's request.

        Available assistants:
        \(catalog)

        Give a short reason (under 8 words) describing the kind of task, e.g. "Image generation" or "Debugging Swift code".
        """

        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "provider": ["type": "string", "enum": enabled.map(\.rawValue)],
                "reason": ["type": "string"],
            ],
            "required": ["provider", "reason"],
            "additionalProperties": false,
        ]

        let choice = try await AnthropicClient.structured(system: system, user: prompt, schema: schema, timeout: 30)
        guard let raw = choice["provider"] as? String, enabled.contains(ProviderID(rawValue: raw)) else {
            throw AnthropicClient.APIError(message: "Unexpected routing answer")
        }
        let reason = (choice["reason"] as? String) ?? "Best match"
        return RouteDecision(provider: ProviderID(rawValue: raw), reason: reason, routedBy: "Claude")
    }
}
