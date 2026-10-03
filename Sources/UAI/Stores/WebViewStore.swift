import AppKit
import Combine
import WebKit

/// Owns one long-lived WKWebView per provider. Each one loads the provider's
/// official web app and shares the default persistent website data store, so
/// you sign in once with your own accounts and stay signed in across launches.
@MainActor
final class WebViewStore: NSObject, ObservableObject {
    /// Safari's user agent. Google (and sites using "Sign in with Google")
    /// refuse logins from user agents they don't recognize as a browser.
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    @Published private(set) var loaded: Set<ProviderID> = []
    /// Bumped whenever a web view's back/forward/loading state changes.
    @Published private(set) var navigationTick = 0
    @Published var lastDownload: URL?

    let index: ConversationIndex
    let media: MediaLibrary

    private var webViews: [ProviderID: WKWebView] = [:]
    private var observers: [NSKeyValueObservation] = []
    private var popups: [NSWindow] = []
    private var indexTimer: Timer?

    init(index: ConversationIndex, media: MediaLibrary) {
        self.index = index
        self.media = media
        super.init()
        indexTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.indexAll() }
        }
    }

    // MARK: - Web views

    func webView(for id: ProviderID) -> WKWebView {
        if let existing = webViews[id] { return existing }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.isElementFullscreenEnabled = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = Self.userAgent
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.navigationDelegate = self
        webView.uiDelegate = self

        for keyPath in [\WKWebView.canGoBack, \WKWebView.canGoForward, \WKWebView.isLoading] as [KeyPath<WKWebView, Bool>] {
            observers.append(webView.observe(keyPath, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.navigationTick &+= 1 }
            })
        }

        webViews[id] = webView
        // Often called while SwiftUI is building views; publish on the next turn.
        DispatchQueue.main.async { self.loaded.insert(id) }
        webView.load(URLRequest(url: Provider.get(id).homeURL))
        return webView
    }

    func existingWebView(for id: ProviderID) -> WKWebView? { webViews[id] }

    func provider(of webView: WKWebView?) -> ProviderID? {
        guard let webView else { return nil }
        return webViews.first { $0.value === webView }?.key
    }

    func goHome(_ id: ProviderID) {
        webView(for: id).load(URLRequest(url: Provider.get(id).homeURL))
    }

    func reload(_ id: ProviderID) {
        webViews[id]?.reload()
    }

    func open(_ url: URL, in id: ProviderID) {
        webView(for: id).load(URLRequest(url: url))
    }

    // MARK: - Sending a prompt into a provider's composer

    enum DeliveryResult { case sent, inserted, failed }

    /// Starts a new chat in the provider and types `prompt` into its message box,
    /// pressing send when `autoSend` is on. Works by scripting the provider's
    /// own page, so the chat is created under your account and syncs everywhere.
    func deliver(_ prompt: String, to id: ProviderID, autoSend: Bool) async -> DeliveryResult {
        let webView = webView(for: id)
        webView.load(URLRequest(url: Provider.get(id).homeURL))

        // Wait for the new-chat page to load before looking for the composer.
        try? await Task.sleep(for: .milliseconds(600))
        for _ in 0..<40 where webView.isLoading {
            try? await Task.sleep(for: .milliseconds(250))
        }

        let script = Self.deliverScript(prompt: prompt, autoSend: autoSend)
        for _ in 0..<30 {
            let result = await evaluate(script, in: webView)
            switch result {
            case "sent": return .sent
            case "inserted": return .inserted
            default: try? await Task.sleep(for: .milliseconds(500))
            }
        }
        return .failed
    }

    private static func deliverScript(prompt: String, autoSend: Bool) -> String {
        let literal = (try? String(data: JSONEncoder().encode(prompt), encoding: .utf8)) ?? "\"\""
        return """
        (() => {
          const text = \(literal);
          const autoSend = \(autoSend ? "true" : "false");
          const visible = el => {
            const r = el.getBoundingClientRect();
            return r.width > 80 && r.height > 12 && el.offsetParent !== null && !el.disabled && !el.readOnly;
          };
          const boxes = [...document.querySelectorAll('textarea, [contenteditable="true"], div[role="textbox"]')].filter(visible);
          if (!boxes.length) return 'no-input';
          // The chat composer is the lowest text box on screen.
          boxes.sort((a, b) => b.getBoundingClientRect().bottom - a.getBoundingClientRect().bottom);
          const box = boxes[0];
          box.focus();
          if (box.tagName === 'TEXTAREA') {
            const setter = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value').set;
            setter.call(box, text);
            box.dispatchEvent(new Event('input', { bubbles: true }));
          } else {
            document.execCommand('selectAll', false, null);
            document.execCommand('insertText', false, text);
            box.dispatchEvent(new InputEvent('input', { bubbles: true }));
          }
          if (!autoSend) return 'inserted';
          setTimeout(() => {
            const selectors = [
              'button[data-testid="send-button"]', 'button[aria-label*="Send" i]',
              'button[aria-label*="Submit" i]', 'div[role="button"][aria-label*="Send" i]', 'button[type="submit"]'
            ];
            for (const s of selectors) {
              const b = [...document.querySelectorAll(s)].find(b => !b.disabled && b.offsetParent !== null);
              if (b) { b.click(); return; }
            }
            const opts = { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true };
            box.dispatchEvent(new KeyboardEvent('keydown', opts));
            box.dispatchEvent(new KeyboardEvent('keyup', opts));
          }, 500);
          return 'sent';
        })()
        """
    }

    // MARK: - Indexing chats for global search

    func indexAll() {
        for (id, webView) in webViews where !webView.isLoading {
            indexChats(in: webView, provider: id)
        }
    }

    private func indexChats(in webView: WKWebView, provider id: ProviderID) {
        let hints = Provider.get(id).conversationPathHints
        let hintsJSON = (try? String(data: JSONEncoder().encode(hints), encoding: .utf8)) ?? "[]"
        let script = """
        (() => {
          const hints = \(hintsJSON);
          const match = path => hints.some(h => path.includes(h) && path.length > path.indexOf(h) + h.length);
          const links = [];
          const seen = new Set();
          for (const a of document.querySelectorAll('a[href]')) {
            let u; try { u = new URL(a.href, location.href); } catch (e) { continue; }
            if (u.host !== location.host || !match(u.pathname)) continue;
            const key = u.origin + u.pathname;
            const title = (a.innerText || a.getAttribute('aria-label') || a.title || '').trim().replace(/\\s+/g, ' ');
            if (!title || title.length > 300 || seen.has(key)) continue;
            seen.add(key);
            links.push({ url: key, title });
          }
          let current = null;
          if (match(location.pathname)) {
            const main = document.querySelector('main') || document.body;
            current = {
              url: location.origin + location.pathname,
              title: document.title,
              body: (main.innerText || '').slice(0, 40000)
            };
          }
          return JSON.stringify({ links, current });
        })()
        """
        Task {
            guard let json = await evaluate(script, in: webView),
                  let data = json.data(using: .utf8),
                  let scraped = try? JSONDecoder().decode(Scraped.self, from: data) else { return }
            for link in scraped.links {
                index.upsert(provider: id, url: link.url, title: link.title, body: nil)
            }
            if let current = scraped.current {
                let title = index.items[current.url]?.title ?? Self.cleanTitle(current.title, provider: id)
                index.upsert(provider: id, url: current.url, title: title, body: current.body)
            }
        }
    }

    private struct Scraped: Decodable {
        struct Link: Decodable { let url: String; let title: String }
        struct Current: Decodable { let url: String; let title: String; let body: String }
        let links: [Link]
        let current: Current?
    }

    private static func cleanTitle(_ title: String, provider: ProviderID) -> String {
        var t = title
        for suffix in [" - Claude", " | Claude", " - ChatGPT", " - Gemini", " - DeepSeek", " - Grok", " | Meta AI"] {
            if t.hasSuffix(suffix) { t = String(t.dropLast(suffix.count)) }
        }
        return t
    }

    private func evaluate(_ script: String, in webView: WKWebView) async -> String? {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { result, _ in
                continuation.resume(returning: result as? String)
            }
        }
    }
}

// MARK: - Navigation, downloads

extension WebViewStore: WKNavigationDelegate, WKDownloadDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        if let url = navigationAction.request.url, let scheme = url.scheme,
           !["http", "https", "about", "blob", "data", "javascript"].contains(scheme) {
            NSWorkspace.shared.open(url)  // mailto:, tel:, app links…
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        if !navigationResponse.canShowMIMEType || disposition.hasPrefix("attachment") {
            decisionHandler(.download)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let id = provider(of: webView) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak webView] in
                guard let self, let webView else { return }
                self.indexChats(in: webView, provider: id)
            }
        }
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let folder = provider(of: download.webView).map(Paths.mediaFolder(for:)) ?? Paths.media
        completionHandler(Paths.uniqueFile(named: suggestedFilename, in: folder))
    }

    func downloadDidFinish(_ download: WKDownload) {
        media.reload()
        lastDownload = media.items.first?.url
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        NSSound.beep()
    }
}

// MARK: - Popups (sign-in windows), file pickers, alerts, mic/camera

extension WebViewStore: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Plain links that open a new tab (citations, shared links) go to the
        // default browser. Script-opened windows are usually sign-in popups
        // ("Continue with Google/Apple") and must stay inside the app so the
        // login completes in the same session.
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
            return nil
        }

        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.customUserAgent = Self.userAgent
        popup.uiDelegate = self
        popup.navigationDelegate = self

        let width = windowFeatures.width?.doubleValue ?? 520
        let height = windowFeatures.height?.doubleValue ?? 680
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Sign in"
        window.isReleasedWhenClosed = false
        window.contentView = popup
        window.center()
        window.makeKeyAndOrderFront(nil)
        popups.append(window)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let window = popups.first(where: { $0.contentView === webView }) {
            window.close()
            popups.removeAll { $0 === window }
        }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.begin { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.prompt)
    }
}
