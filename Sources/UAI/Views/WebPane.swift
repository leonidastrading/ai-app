import SwiftUI
import WebKit

/// One AI's workspace: a Slack-style channel header over the provider's own web app.
struct WebPane: View {
    @EnvironmentObject private var webViews: WebViewStore
    @EnvironmentObject private var index: ConversationIndex
    @EnvironmentObject private var memory: MemoryStore
    @EnvironmentObject private var app: AppState
    let provider: Provider
    let isActive: Bool
    @State private var reconnectLink = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if webViews.needsSignIn.contains(provider.id) {
                signInTip
                Divider()
            }
            WebViewHost(webView: webViews.webView(for: provider.id), isHidden: !isActive)
                .overlay {
                    // Dark cover until the page first paints, so it never flashes white.
                    if !webViews.firstLoaded.contains(provider.id) {
                        ZStack {
                            Theme.contentBackground
                            ProgressView().controlSize(.large)
                        }
                        .transition(.opacity)
                    }
                }
        }
        .background(Theme.contentBackground)
        .opacity(isActive ? 1 : 0)
        .allowsHitTesting(isActive)
    }

    private var header: some View {
        let web = webViews.existingWebView(for: provider.id)
        _ = webViews.navigationTick
        return HStack(spacing: 10) {
            ProviderIcon(provider: provider, size: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(provider.name).font(.headline)
                Text("\(provider.maker) · your account · \(index.count(for: provider.id)) chats indexed")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if web?.isLoading == true {
                ProgressView().controlSize(.small).padding(.leading, 4)
            }
            Spacer()
            chatsMenu
            Button(action: shareMemory) { Label("Memory", systemImage: "brain.head.profile") }
                .help("Put your shared memory and related chats from your other AIs into this chat's message box")
            Button { webViews.goHome(provider.id) } label: { Label("New chat", systemImage: "square.and.pencil") }
                .help("Start a new chat")
            Button { webViews.reload(provider.id) } label: { Image(systemName: "arrow.clockwise") }
                .help("Reload")
            Button {
                if let url = web?.url { NSWorkspace.shared.open(url) }
            } label: { Image(systemName: "safari") }
                .help("Open this page in your browser")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .frame(height: 48)
    }

    /// Your chats for this AI, indexed by UAI — a reliable way to reopen one
    /// even when the AI's own sidebar is collapsed or empty.
    private var recentChats: [IndexedConversation] {
        index.items.values.filter { $0.provider == provider.id }
            .sorted { $0.lastSeen > $1.lastSeen }
    }

    @ViewBuilder
    private var chatsMenu: some View {
        let chats = recentChats
        Menu {
            if chats.isEmpty {
                Text("No chats indexed yet. Open some in \(provider.name).")
            } else {
                ForEach(chats.prefix(30)) { chat in
                    Button(chat.title.isEmpty ? "Untitled chat" : chat.title) {
                        if let url = URL(string: chat.url) { webViews.open(url, in: provider.id) }
                    }
                }
            }
        } label: {
            Label("Chats", systemImage: "bubble.left.and.bubble.right")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Open one of your \(provider.name) chats")
    }

    private var signInTip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "key.fill").foregroundStyle(Theme.indigo)
                Text("Sign in to \(provider.name) below. You only do this once; UAI keeps you signed in.")
                    .font(.callout)
                Spacer()
            }
            HStack(spacing: 8) {
                Text("Got a sign-in link by email?").font(.caption).foregroundStyle(.secondary)
                TextField("Paste the login link here", text: $reconnectLink)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(openPastedLink)
                Button("Reconnect", action: openPastedLink)
                    .controlSize(.small)
                    .disabled(reconnectLink.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Theme.aqua.opacity(0.18))
    }

    /// Loads a pasted sign-in / magic link into THIS AI's window so the login
    /// finishes inside UAI (same session) instead of in your browser.
    private func openPastedLink() {
        let text = reconnectLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), url.scheme?.hasPrefix("http") == true else {
            app.show(toast: "That doesn't look like a link. Paste the full https:// sign-in link from your email.")
            return
        }
        reconnectLink = ""
        webViews.open(url, in: provider.id)
        app.show(toast: "Opening your sign-in link in \(provider.name)…")
    }

    private func shareMemory() {
        // Related chats are matched against what's on screen (the chat's title).
        let topic = webViews.existingWebView(for: provider.id)?.title ?? ""
        guard let context = memory.context(for: topic, excluding: provider.id) else {
            app.show(toast: "Memory is empty. Add notes in Memory (top right) first.")
            return
        }
        Task {
            let result = await webViews.deliver(context + "\n\n", to: provider.id, autoSend: false, newChat: false)
            if result == .failed {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(context, forType: .string)
                app.show(toast: "Memory copied. Paste it into \(provider.name) with ⌘V.")
            } else {
                app.show(toast: "Memory added to your message. Write your question after it.")
            }
        }
    }
}

/// Hosts a long-lived WKWebView. The same web view instance is reused across
/// SwiftUI updates so sessions and in-flight answers survive tab switches.
struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    let isHidden: Bool

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if webView.superview !== container { attach(to: container) }
        container.isHidden = isHidden
    }

    private func attach(to container: NSView) {
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}
