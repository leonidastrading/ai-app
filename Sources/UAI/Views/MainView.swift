import SwiftUI

struct MainView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var webViews: WebViewStore
    @EnvironmentObject private var profile: Profile
    @ObservedObject private var registry = ProviderRegistry.shared

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
                .overlay(alignment: .top) {
                    if let link = app.pendingLink, app.searchText.isEmpty {
                        LinkBanner(provider: Provider.get(link.provider), url: link.url)
                            .padding(.top, 10)
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
        .preferredColorScheme(.dark)
        .sheet(isPresented: $app.showAddAI) { AddAISheet() }
        .onAppear(perform: connectNotifications)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            app.markRead()
            app.checkPasteboardForLink()
        }
    }

    /// Wires "AI finished replying" events to unread badges and notifications.
    private func connectNotifications() {
        let state = app
        webViews.onReply = { [weak state] id, title, preview in
            guard let state, state.replyArrived(from: id) else { return }
            Notifier.shared.replied(Provider.get(id), title: title, preview: preview)
        }
        Notifier.shared.onOpen = { [weak state] id in state?.go(.provider(id)) }
        // When Gemini is ready and the profile is empty, fill name + photo from Google.
        webViews.onGeminiReady = {
            guard profile.name.isEmpty, profile.avatar == nil else { return }
            Task { _ = await profile.importFromGoogle(using: webViews) }
        }
    }

    @ViewBuilder
    private var content: some View {
        ZStack {
            // Every AI that has been opened stays alive in the background so
            // switching is instant and in-progress answers keep streaming.
            ForEach(registry.all) { provider in
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
            if app.destination == .memory {
                MemoryView().zIndex(2)
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
        ToolbarItemGroup(placement: .primaryAction) {
            Button { app.toggleMemory() } label: {
                Label("Memory", systemImage: "brain.head.profile")
                    .labelStyle(.titleAndIcon)
            }
            .help("Shared memory for all your AIs (⇧⌘Y)")
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
            TextField("", text: $app.searchText, prompt: Text("Search all AIs").foregroundColor(.white.opacity(0.75)))
                .textFieldStyle(.plain)
                .foregroundStyle(.white)
                .autocorrectionDisabled(true)
                .focused($focused)
                .onExitCommand { app.searchText = ""; focused = false }
                .onSubmit { app.submitSearch() }
                .onChange(of: app.searchText) { app.searchSelection = 0 }
                .onKeyPress(.downArrow) { app.moveSearchSelection(1); return .handled }
                .onKeyPress(.upArrow) { app.moveSearchSelection(-1); return .handled }
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

/// "Open this copied link in Claude?" Shown when you copy a link that belongs
/// to one of your AIs, such as a sign-in link from an email.
private struct LinkBanner: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var webViews: WebViewStore
    let provider: Provider
    let url: URL

    var body: some View {
        HStack(spacing: 10) {
            ProviderIcon(provider: provider, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text("Open the link you copied in \(provider.name)?").font(.callout.bold())
                Text(url.absoluteString).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: 360, alignment: .leading)
            Button("Open in UAI") { app.open(url, in: provider.id, webViews: webViews) }
                .buttonStyle(.borderedProminent)
            Button { app.pendingLink = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
    }
}
