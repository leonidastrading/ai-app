import SwiftUI

/// Opened by the + button: add any AI that has a web app.
struct AddAISheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var strengths = ""

    private static let suggestions: [(String, String, String)] = [
        ("Perplexity", "https://www.perplexity.ai/", "web research with cited sources"),
        ("Mistral", "https://chat.mistral.ai/", "fast answers, European languages"),
        ("Copilot", "https://copilot.microsoft.com/", "Microsoft 365, Bing search"),
        ("Qwen", "https://chat.qwen.ai/", "multilingual chat, coding"),
        ("Kimi", "https://www.kimi.ai/", "very long documents"),
        ("Midjourney", "https://www.midjourney.com/imagine", "artistic image generation"),
    ]

    private var url: URL? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), url.host?.contains(".") == true else { return nil }
        return url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add an AI").font(.title2.bold())
            Text("Any AI with a website works. It opens inside UAI, signed in with your own account.")
                .foregroundStyle(.secondary)

            Form {
                TextField("Name", text: $name, prompt: Text("Perplexity"))
                TextField("Web address", text: $address, prompt: Text("perplexity.ai"))
                TextField("Good at (optional)", text: $strengths, prompt: Text("web research with sources"))
            }
            .formStyle(.grouped)
            .frame(height: 170)

            Text("Suggestions").font(.caption.bold()).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                ForEach(Self.suggestions, id: \.0) { suggestion in
                    Button(suggestion.0) {
                        name = suggestion.0
                        address = suggestion.1
                        strengths = suggestion.2
                    }
                    .buttonStyle(.bordered)
                    .disabled(Provider.all.contains { $0.name == suggestion.0 })
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    guard let url else { return }
                    let title = name.trimmingCharacters(in: .whitespaces)
                    let id = ProviderRegistry.shared.add(
                        name: title.isEmpty ? (url.host ?? "AI") : title,
                        url: url, strengths: strengths.trimmingCharacters(in: .whitespaces))
                    dismiss()
                    app.go(.provider(id))
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Theme.pink)
                .disabled(url == nil)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
