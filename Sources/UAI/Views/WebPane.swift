import SwiftUI
import WebKit

/// One AI's workspace: a Slack-style channel header over the provider's own web app.
struct WebPane: View {
    @EnvironmentObject private var webViews: WebViewStore
    @EnvironmentObject private var index: ConversationIndex
    let provider: Provider
    let isActive: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            WebViewHost(webView: webViews.webView(for: provider.id), isHidden: !isActive)
        }
        .background(Color(nsColor: .windowBackgroundColor))
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
