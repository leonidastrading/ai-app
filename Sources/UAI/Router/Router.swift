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
        if smart, let key = Keychain.read(Keychain.anthropicKey), !key.isEmpty,
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
        Rule(providers: [.gemini, .grok], reason: "Video generation",
             keywords: ["video", "animate", "animation", "clip", "footage", "veo", "short film", "reel"]),
        Rule(providers: [.chatgpt, .grok, .gemini], reason: "Image generation",
             keywords: ["image", "picture", "photo", "draw", "drawing", "illustrat", "logo", "poster",
                        "wallpaper", "render", "sketch", "painting", "avatar", "icon", "generate a pic"]),
        Rule(providers: [.grok], reason: "Real-time news and X/Twitter",
             keywords: ["news", "today", "latest", "trending", "right now", "this week", "tweet", "twitter",
                        "x.com", "elon", "breaking", "live score", "stock price"]),
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
        Rule(providers: [.muse], reason: "Meta apps (Instagram, Facebook, WhatsApp)",
             keywords: ["instagram", "facebook", "whatsapp", "threads post", "meta "]),
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

/// Routes with Claude through the Anthropic Messages API (raw HTTPS; there's
/// no official Swift SDK). Uses structured output so the reply is always a
/// valid choice.
enum ClaudeRouter {
    struct RouterError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

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

        let body: [String: Any] = [
            "model": "claude-opus-5-5",
            "max_tokens": 4096,
            "system": system,
            "messages": [["role": "user", "content": prompt]],
            "output_config": [
                "effort": "low",
                "format": ["type": "json_schema", "schema": schema],
            ],
            "fallbacks": "default",
        ]

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RouterError(message: "No response") }
        guard http.statusCode == 200 else {
            throw RouterError(message: "HTTP \(http.statusCode): \(String(data: data, encoding: .utf8) ?? "")")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RouterError(message: "Malformed response")
        }
        if json["stop_reason"] as? String == "refusal" {
            throw RouterError(message: "Declined")
        }
        let blocks = json["content"] as? [[String: Any]] ?? []
        guard let text = blocks.last(where: { $0["type"] as? String == "text" })?["text"] as? String,
              let choice = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let raw = choice["provider"] as? String,
              let provider = ProviderID(rawValue: raw), enabled.contains(provider) else {
            throw RouterError(message: "Unexpected routing answer")
        }
        let reason = (choice["reason"] as? String) ?? "Best match"
        return RouteDecision(provider: provider, reason: reason, routedBy: "Claude")
    }
}
