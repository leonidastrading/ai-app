import SwiftUI

struct MainView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var webViews: WebViewStore

    var body: some View {
        HStack(spacing: 0) {
            ModelRail()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .top) {
                    if !app.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                        SearchResultsView()
                            .padding(.top, 8)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .overlay(alignment: .bottom) {
                    if let toast = app.toast {
                        Text(toast)
                            .font(.callout)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(.regularMaterial, in: Capsule())
                            .shadow(radius: 8)
                            .padding(.bottom, 24)
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: app.searchText.isEmpty)
                .animation(.easeOut(duration: 0.2), value: app.toast)
        }
        .toolbar { TopBar() }
        .toolbarBackground(Theme.toolbar, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .toolbarColorScheme(.dark, for: .windowToolbar)
        .tint(Theme.pink)
    }

    @ViewBuilder
    private var content: some View {
        ZStack {
            // Every AI that has been opened stays alive in the background so
            // switching is instant and in-progress answers keep streaming.
            ForEach(Provider.all) { provider in
                if webViews.loaded.contains(provider.id) || app.destination == .provider(provider.id) {
                    WebPane(provider: provider, isActive: app.destination == .provider(provider.id))
                        .zIndex(app.destination == .provider(provider.id) ? 1 : 0)
                }
            }
            if app.destination == .universal {
                UniversalView().zIndex(2)
            }
            if app.destination == .media {
                MediaView().zIndex(2)
            }
        }
    }
}

/// Slack-style top bar: history arrows on the left, one search field across
/// every AI in the middle, Media on the right.
struct TopBar: ToolbarContent {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var webViews: WebViewStore

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { app.back(webViews: webViews) } label: { Image(systemName: "chevron.left") }
                .help("Back (⌘[)")
                .disabled(!app.canGoBack(webViews: webViews))
            Button { app.forward(webViews: webViews) } label: { Image(systemName: "chevron.right") }
                .help("Forward (⌘])")
                .disabled(!app.canGoForward(webViews: webViews))
        }
        ToolbarItem(placement: .principal) {
            GlobalSearchField()
        }
        ToolbarItem(placement: .primaryAction) {
            Button { app.toggleMedia() } label: {
                Label("Media", systemImage: app.destination == .media ? "photo.on.rectangle.angled.fill" : "photo.on.rectangle.angled")
                    .labelStyle(.titleAndIcon)
            }
            .help("Everything your AIs generated (⇧⌘M)")
        }
    }
}

struct GlobalSearchField: View {
    @EnvironmentObject private var app: AppState
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.7))
            TextField("Search all AIs", text: $app.searchText)
                .textFieldStyle(.plain)
                .foregroundStyle(.white)
                .focused($focused)
                .onExitCommand { app.searchText = ""; focused = false }
            if !app.searchText.isEmpty {
                Button { app.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 520, height: 26)
        .background(Theme.searchField, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(.white.opacity(focused ? 0.5 : 0.15)))
        .onChange(of: app.focusSearchTick) { focused = true }
    }
}
