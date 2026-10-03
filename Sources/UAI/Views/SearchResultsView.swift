import SwiftUI

/// Results for the top search bar: chats from every AI account, prompts sent
/// through Universal AI, and files in Media.
struct SearchResultsView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var index: ConversationIndex
    @EnvironmentObject private var universal: UniversalStore
    @EnvironmentObject private var media: MediaLibrary
    @EnvironmentObject private var webViews: WebViewStore

    var body: some View {
        let query = app.searchText.trimmingCharacters(in: .whitespaces)
        let chats = index.search(query)
        let prompts = Array(universal.search(query).prefix(10))
        let files = Array(media.search(query).prefix(10))

        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if chats.isEmpty && prompts.isEmpty && files.isEmpty {
                        Text("No results for “\(query)”").foregroundStyle(.secondary).padding(.vertical, 20)
                            .frame(maxWidth: .infinity)
                    }
                    if !chats.isEmpty {
                        section("Chats") {
                            ForEach(chats) { chat in
                                row(icon: AnyView(ProviderIcon(provider: Provider.get(chat.provider), size: 20)),
                                    title: chat.title,
                                    subtitle: snippet(chat.body, query: query) ?? Provider.get(chat.provider).name) {
                                    app.searchText = ""
                                    app.go(.provider(chat.provider))
                                    if let url = URL(string: chat.url) { webViews.open(url, in: chat.provider) }
                                }
                            }
                        }
                    }
                    if !prompts.isEmpty {
                        section("Universal AI") {
                            ForEach(prompts) { entry in
                                row(icon: AnyView(GalaxyIcon(size: 20)),
                                    title: entry.prompt,
                                    subtitle: "Sent to \(Provider.get(entry.provider).name) · \(entry.date.formatted(date: .abbreviated, time: .shortened))") {
                                    app.searchText = ""
                                    app.go(.universal)
                                }
                            }
                        }
                    }
                    if !files.isEmpty {
                        section("Media") {
                            ForEach(files) { item in
                                row(icon: AnyView(Image(systemName: item.kind.symbol).frame(width: 20)),
                                    title: item.name,
                                    subtitle: item.provider.map { Provider.get($0).name } ?? "Media") {
                                    app.searchText = ""
                                    NSWorkspace.shared.open(item.url)
                                }
                            }
                        }
                    }
                }
                .padding(14)
            }
            Divider()
            Text("Searching \(index.items.count) chats indexed from your AI accounts. Open an AI in UAI to index its chat list.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .frame(width: 640)
        .frame(maxHeight: 520)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.25)))
        .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(.caption.bold()).foregroundStyle(.secondary).padding(.bottom, 4)
            content()
        }
    }

    private func row(icon: AnyView, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        SearchRow(icon: icon, title: title, subtitle: subtitle, action: action)
    }

    private func snippet(_ body: String, query: String) -> String? {
        guard let term = query.split(separator: " ").first,
              let range = body.range(of: term, options: .caseInsensitive) else { return nil }
        let start = body.index(range.lowerBound, offsetBy: -50, limitedBy: body.startIndex) ?? body.startIndex
        let end = body.index(range.upperBound, offsetBy: 90, limitedBy: body.endIndex) ?? body.endIndex
        return "…" + body[start..<end].replacingOccurrences(of: "\n", with: " ") + "…"
    }
}

private struct SearchRow: View {
    let icon: AnyView
    let title: String
    let subtitle: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                icon
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .padding(.vertical, 5).padding(.horizontal, 6)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(hovering ? 0.15 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
