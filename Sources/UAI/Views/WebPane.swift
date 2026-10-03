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

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if webViews.needsSignIn.contains(provider.id) {
                signInTip
                Divider()
            }
            WebViewHost(webView: webViews.webView(for: provider.id), isHidden: !isActive)
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

    private var signInTip: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill").foregroundStyle(Theme.indigo)
            Text("Sign in to \(provider.name) below. You only do this once; UAI keeps you signed in.")
                .font(.callout)
            Spacer()
            Text("Got a sign-in link by email? Copy it and come back to UAI.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Open Copied Link") { app.openCopiedLink(webViews: webViews) }
                .controlSize(.small)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Theme.aqua.opacity(0.18))
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
