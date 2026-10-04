import SwiftUI

/// Results for the top search bar: chats from every AI account, prompts sent
/// through Universal AI, and files in Media.
struct SearchResultsView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var index: ConversationIndex
    @EnvironmentObject private var universal: UniversalStore
    @EnvironmentObject private var media: MediaLibrary
    @EnvironmentObject private var webViews: WebViewStore

    /// One flat, ordered list so Return/arrow keys can act on a selection.
    private struct Hit: Identifiable {
        let id: String
        let group: String
        let icon: AnyView
        let title: String
        let subtitle: String
        let open: () -> Void
    }

    private func hits(query: String) -> [Hit] {
        var hits: [Hit] = []
        for chat in index.search(query) {
            hits.append(Hit(id: "chat:" + chat.url, group: "Chats",
                            icon: AnyView(ProviderIcon(provider: Provider.get(chat.provider), size: 20)),
                            title: chat.title,
                            subtitle: snippet(chat.body, query: query) ?? Provider.get(chat.provider).name) {
                app.searchText = ""
                app.go(.provider(chat.provider))
                if let url = URL(string: chat.url) { webViews.open(url, in: chat.provider) }
            })
        }
        for entry in universal.search(query).prefix(10) {
            hits.append(Hit(id: "prompt:" + entry.id.uuidString, group: "Universal AI",
                            icon: AnyView(GalaxyIcon(size: 20, animated: false)), title: entry.prompt,
                            subtitle: "Sent to \(Provider.get(entry.provider).name) · \(entry.date.formatted(date: .abbreviated, time: .shortened))") {
                app.searchText = ""
                app.go(.universal)
            })
        }
        for item in media.search(query).prefix(10) {
            hits.append(Hit(id: "file:" + item.url.path, group: "Media",
                            icon: AnyView(Image(systemName: item.kind.symbol).frame(width: 20)),
                            title: item.name,
                            subtitle: item.provider.map { Provider.get($0).name } ?? "Media") {
                app.searchText = ""
                NSWorkspace.shared.open(item.url)
            })
        }
        return hits
    }

    var body: some View {
        let query = app.searchText.trimmingCharacters(in: .whitespaces)
        let hits = hits(query: query)
        let selected = hits.isEmpty ? 0 : min(app.searchSelection, hits.count - 1)

        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if hits.isEmpty {
                            Text("No results for “\(query)”").foregroundStyle(.secondary).padding(.vertical, 20)
                                .frame(maxWidth: .infinity)
                        }
                        ForEach(groups(of: hits), id: \.0) { group, groupHits in
                            section(group) {
                                ForEach(groupHits) { hit in
                                    let isSelected = hits.firstIndex { $0.id == hit.id } == selected
                                    SearchRow(icon: hit.icon, title: hit.title, subtitle: hit.subtitle,
                                              selected: isSelected, action: hit.open)
                                        .id(hit.id)
                                }
                            }
                        }
                    }
                    .padding(14)
                }
                .onChange(of: selected) {
                    if hits.indices.contains(selected) {
                        withAnimation { proxy.scrollTo(hits[selected].id, anchor: .center) }
                    }
                }
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
        .onAppear { app.searchResultCount = hits.count }
        .onChange(of: hits.count) { app.searchResultCount = hits.count }
        // Return in the search field bumps this; open the highlighted result.
        .onChange(of: app.submitSearchTick) {
            if hits.indices.contains(selected) { hits[selected].open() }
        }
    }

    private func groups(of hits: [Hit]) -> [(String, [Hit])] {
        var order: [String] = []
        var map: [String: [Hit]] = [:]
        for hit in hits {
            if map[hit.group] == nil { order.append(hit.group) }
            map[hit.group, default: []].append(hit)
        }
        return order.map { ($0, map[$0]!) }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(.caption.bold()).foregroundStyle(.secondary).padding(.bottom, 4)
            content()
        }
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
    var selected: Bool = false
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
                if selected {
                    Image(systemName: "return").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 5).padding(.horizontal, 6)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(selected ? 0.25 : (hovering ? 0.15 : 0))))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
