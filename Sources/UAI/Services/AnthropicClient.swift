import Foundation

/// Minimal Anthropic Messages API client (raw HTTPS; there's no official
/// Swift SDK). Used only when you add an API key in Settings: for smart
/// routing and for learning memory from your chats.
enum AnthropicClient {
    struct APIError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static var apiKey: String? {
        guard let key = Keychain.read(Keychain.anthropicKey), !key.isEmpty else { return nil }
        return key
    }

    /// Sends one request that must answer with JSON matching `schema`, and
    /// returns the decoded JSON object.
    static func structured(system: String, user: String, schema: [String: Any],
                           effort: String = "low", maxTokens: Int = 4096,
                           timeout: TimeInterval = 60) async throws -> [String: Any] {
        guard let apiKey else { throw APIError(message: "Add an Anthropic API key in Settings first.") }

        let body: [String: Any] = [
            "model": "claude-opus-5-5",
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": user]],
            "output_config": [
                "effort": effort,
                "format": ["type": "json_schema", "schema": schema],
            ],
            // If a request is declined by a safety classifier, retry on
            // Anthropic's recommended fallback model instead of failing.
            "fallbacks": "default",
        ]

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError(message: "No response") }
        guard http.statusCode == 200 else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0["error"] as? [String: Any] }?["message"] as? String
            if let detail, detail.contains("not scoped to a workspace") {
                throw APIError(message: "Your API key is Organization-scoped. Create a key with a “Default workspace” scope at platform.claude.com/settings/keys and paste that one.")
            }
            throw APIError(message: "Anthropic API error \(http.statusCode)\(detail.map { ": \($0)" } ?? "")")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError(message: "Malformed response")
        }
        if json["stop_reason"] as? String == "refusal" {
            throw APIError(message: "Claude declined this request.")
        }
        if json["stop_reason"] as? String == "max_tokens" {
            throw APIError(message: "The answer was cut off. Try again with fewer chats.")
        }
        let blocks = json["content"] as? [[String: Any]] ?? []
        guard let text = blocks.last(where: { $0["type"] as? String == "text" })?["text"] as? String,
              let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw APIError(message: "Unexpected answer format")
        }
        return object
    }
}
