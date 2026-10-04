import SwiftUI

/// The right-hand panel: your notifications history on the top half and
/// suggestions on the bottom half. Fold it away with the chevron up top.
struct RightBar: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var history: NotificationHistory
    @EnvironmentObject private var webViews: WebViewStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            GeometryReader { geo in
                VStack(spacing: 0) {
                    notifications
                        .frame(height: geo.size.height / 2)
                    Divider()
                    suggestions
                        .frame(height: geo.size.height / 2)
                }
            }
        }
        .frame(width: 300)
        .background(Theme.contentBackground)
        .overlay(Rectangle().frame(width: 1).foregroundStyle(.white.opacity(0.08)), alignment: .leading)
    }

    private var header: some View {
        HStack {
            Text("Activity").font(.headline)
            Spacer()
            Button { withAnimation(.easeInOut(duration: 0.2)) { app.showRightBar = false } } label: {
                Image(systemName: "arrow.right.to.line")
            }
            .buttonStyle(.borderless)
            .help("Hide this panel")
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
    }

    // MARK: Notifications (top half)

    private var notifications: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Notifications", systemImage: "bell.fill").font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                if !history.items.isEmpty {
                    Button("Clear") { history.clear() }.buttonStyle(.borderless).font(.caption)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)

            if history.items.isEmpty {
                emptyNote("No notifications yet", "When an AI finishes replying while you're elsewhere, it shows here.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(history.items) { item in
                            NotifRow(item: item) {
                                app.go(.provider(item.provider))
                                if let s = item.url, let url = URL(string: s) { webViews.open(url, in: item.provider) }
                            }
                        }
                    }
                    .padding(.horizontal, 8).padding(.bottom, 8)
                }
            }
        }
    }

    // MARK: Suggestions (bottom half)

    private struct Suggestion: Identifiable { let id = UUID(); let icon: String; let text: String }
    private let suggestionList: [Suggestion] = [
        Suggestion(icon: "photo", text: "Make me an image of…"),
        Suggestion(icon: "chart.line.uptrend.xyaxis", text: "Summarize today's market news"),
        Suggestion(icon: "chevron.left.forwardslash.chevron.right", text: "Write a script to…"),
        Suggestion(icon: "doc.text", text: "Draft an email about…"),
        Suggestion(icon: "video", text: "Create a short video of…"),
        Suggestion(icon: "magnifyingglass", text: "Research and compare…"),
    ]

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("Suggestions", systemImage: "sparkles").font(.caption.bold()).foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.vertical, 8)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(suggestionList) { s in
                        Button {
                            app.go(.universal)
                            app.pendingPrompt = s.text
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: s.icon).frame(width: 18).foregroundStyle(Theme.pink)
                                Text(s.text).lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 10)
            }
        }
    }

    private func emptyNote(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text(detail).font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 16)
    }
}

private struct NotifRow: View {
    let item: NotifItem
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                ProviderIcon(provider: Provider.get(item.provider), size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    HStack {
                        Text("\(Provider.get(item.provider).name) replied").font(.caption.bold())
                        Spacer()
                        Text(item.date.formatted(.relative(presentation: .numeric))).font(.caption2).foregroundStyle(.tertiary)
                    }
                    if !item.title.isEmpty {
                        Text(item.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if !item.preview.isEmpty {
                        Text(item.preview).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
                    }
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(hovering ? 0.12 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
