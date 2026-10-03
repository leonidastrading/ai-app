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
    /// AIs whose page is currently a sign-in screen.
    @Published private(set) var needsSignIn: Set<ProviderID> = []

    /// Called when an AI finishes writing a reply: (provider, page title, preview).
    var onReply: ((ProviderID, String, String) -> Void)?

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
        config.userContentController.addUserScript(WKUserScript(
            source: Self.replyWatcherScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        // Consent banners often live in iframes, so this one runs in every frame.
        config.userContentController.addUserScript(WKUserScript(
            source: Self.acceptCookiesScript, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        config.userContentController.add(ScriptMessageProxy(target: self), name: "uai")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = Self.userAgent
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.underPageBackgroundColor = NSColor(red: 0.09, green: 0.08, blue: 0.17, alpha: 1)
        webView.navigationDelegate = self
        webView.uiDelegate = self

        for keyPath in [\WKWebView.canGoBack, \WKWebView.canGoForward, \WKWebView.isLoading] as [KeyPath<WKWebView, Bool>] {
            observers.append(webView.observe(keyPath, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.navigationTick &+= 1 }
            })
        }

        observers.append(webView.observe(\.url, options: [.new]) { [weak self] web, _ in
            Task { @MainActor in self?.updateSignInState(for: web) }
        })

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

    /// Forgets a removed AI's web view.
    func close(_ id: ProviderID) {
        webViews[id]?.removeFromSuperview()
        webViews[id] = nil
        loaded.remove(id)
        needsSignIn.remove(id)
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
    func deliver(_ prompt: String, to id: ProviderID, autoSend: Bool, newChat: Bool = true) async -> DeliveryResult {
        let webView = webView(for: id)
        if newChat {
            webView.load(URLRequest(url: Provider.get(id).homeURL))
            // Wait for the new-chat page to load before looking for the composer.
            try? await Task.sleep(for: .milliseconds(600))
        }
        for _ in 0..<40 where webView.isLoading {
            try? await Task.sleep(for: .milliseconds(250))
        }

        let script = Self.deliverScript(prompt: prompt, autoSend: autoSend, replace: newChat)
        for _ in 0..<(newChat ? 30 : 4) {
            let result = await evaluate(script, in: webView)
            switch result {
            case "sent": return .sent
            case "inserted": return .inserted
            default: try? await Task.sleep(for: .milliseconds(500))
            }
        }
        return .failed
    }

    private static func deliverScript(prompt: String, autoSend: Bool, replace: Bool) -> String {
        let literal = (try? String(data: JSONEncoder().encode(prompt), encoding: .utf8)) ?? "\"\""
        return """
        (() => {
          const text = \(literal);
          const autoSend = \(autoSend ? "true" : "false");
          const replace = \(replace ? "true" : "false");
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
            setter.call(box, replace || !box.value ? text : text + '\\n\\n' + box.value);
            box.dispatchEvent(new Event('input', { bubbles: true }));
          } else {
            if (replace) {
              document.execCommand('selectAll', false, null);
            } else {
              const sel = window.getSelection();
              sel.selectAllChildren(box);
              sel.collapseToStart();
              if (box.innerText.trim()) { document.execCommand('insertText', false, '\\n\\n'); sel.collapseToStart(); }
            }
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
          const hit = (s, h) => s.includes(h) && s.length > s.indexOf(h) + h.length;
          const match = u => hints.some(h => hit(u.pathname, h) || hit(u.search, h));
          const keyOf = u => u.origin + u.pathname + (hints.some(h => hit(u.search, h)) ? u.search : '');
          const links = [];
          const seen = new Set();
          for (const a of document.querySelectorAll('a[href]')) {
            let u; try { u = new URL(a.href, location.href); } catch (e) { continue; }
            if (u.host !== location.host || !match(u)) continue;
            const key = keyOf(u);
            const title = (a.innerText || a.getAttribute('aria-label') || a.title || '').trim().replace(/\\s+/g, ' ');
            if (!title || title.length > 300 || seen.has(key)) continue;
            seen.add(key);
            links.push({ url: key, title });
          }
          let current = null;
          if (match(location)) {
            const main = document.querySelector('main') || document.body;
            current = {
              url: keyOf(location),
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

// MARK: - Sign-in detection and reply notifications

extension WebViewStore {
    private static let signInHosts = [
        "accounts.google.com", "appleid.apple.com", "login.microsoftonline.com", "login.live.com",
        "auth.openai.com", "auth0.openai.com", "accounts.x.ai", "auth.meta.com", "github.com/login",
    ]

    /// True for sign-in and sign-up pages, including "Continue with Google/Apple" flows.
    static func isSignInURL(_ url: URL?) -> Bool {
        guard let url, let host = url.host?.lowercased() else { return false }
        let full = host + url.path.lowercased()
        if signInHosts.contains(where: { full.hasPrefix($0) || host.hasSuffix("." + $0) }) { return true }
        if host.hasSuffix("x.com") || host.hasSuffix("twitter.com"), url.path.contains("/i/flow/login") { return true }
        let path = url.path.lowercased()
        return ["/login", "/log-in", "/signin", "/sign-in", "/signup", "/sign-up", "/auth", "/oauth"]
            .contains { path.hasPrefix($0) || path.contains($0 + "/") }
    }

    func updateSignInState(for webView: WKWebView) {
        guard let id = provider(of: webView) else { return }
        if Self.isSignInURL(webView.url) {
            needsSignIn.insert(id)
        } else {
            needsSignIn.remove(id)
        }
    }

    /// Clicks "Accept all" on cookie banners so they never get in the way.
    /// Generic labels like "OK" or "Got it" are only clicked inside an
    /// element that is clearly a cookie/consent banner.
    static let acceptCookiesScript = """
    (() => {
      if (window.__uaiCookies) return;
      window.__uaiCookies = true;
      const known = [
        '#onetrust-accept-btn-handler', '#accept-recommended-btn-handler',
        '#CybotCookiebotDialogBodyLevelButtonLevelOptinAllowAll', '#CybotCookiebotDialogBodyButtonAccept',
        '#didomi-notice-agree-button', '.fc-cta-consent', '#truste-consent-button',
        '[data-testid="cookie-policy-banner-accept"]', '[data-testid="accept-all-cookies"]',
        '[data-cookiebanner="accept_button"]', 'button[aria-label="Accept all"]'
      ];
      const strong = ['accept all', 'accept all cookies', 'allow all', 'allow all cookies', 'accept cookies',
                      'allow cookies', 'agree to all', 'accept and continue', 'alle akzeptieren',
                      'tout accepter', 'aceptar todo', 'accetta tutto', 'aceitar tudo'];
      const weak = ['accept', 'i accept', 'agree', 'i agree', 'ok', 'okay', 'got it', 'allow', 'continue'];
      const inBanner = el => {
        for (let n = el, i = 0; n && i < 10; n = n.parentElement, i++) {
          const cls = typeof n.className === 'string' ? n.className : '';
          const text = ((n.id || '') + ' ' + cls + ' ' + (n.getAttribute && n.getAttribute('aria-label') || '')).toLowerCase();
          if (/cookie|consent|gdpr|cmp|privacy-banner|onetrust|didomi|truste/.test(text)) return true;
        }
        return false;
      };
      const visible = el => el.offsetParent !== null || el.getClientRects().length > 0;
      const run = () => {
        for (const sel of known) {
          const b = document.querySelector(sel);
          if (b && visible(b)) { b.click(); return true; }
        }
        const candidates = document.querySelectorAll('button, [role="button"], input[type="button"], input[type="submit"], a');
        for (const b of candidates) {
          const label = (b.innerText || b.value || b.getAttribute('aria-label') || '').trim().toLowerCase();
          if (!label || label.length > 40 || !visible(b)) continue;
          if (strong.includes(label) || (weak.includes(label) && inBanner(b))) { b.click(); return true; }
        }
        return false;
      };
      let tries = 0;
      const timer = setInterval(() => { if (run() || ++tries > 25) clearInterval(timer); }, 1000);
    })();
    """

    /// Watches for the "Stop" button that every AI shows while it writes.
    /// When it goes away after a few seconds, the reply is done.
    static let replyWatcherScript = """
    (() => {
      if (window.__uaiReplyWatch) return;
      window.__uaiReplyWatch = true;
      const stopSelector = [
        'button[aria-label*="Stop" i]', 'button[data-testid*="stop" i]',
        '[role="button"][aria-label*="Stop" i]', 'button[title*="Stop" i]'
      ].join(',');
      const replySelector = [
        '[data-message-author-role="assistant"]', '.font-claude-response', '.font-claude-message',
        'model-response', '.ds-markdown', '[data-testid="assistant-message"]', '.message-bubble'
      ].join(',');
      let busy = false, since = 0;
      setInterval(() => {
        const stop = [...document.querySelectorAll(stopSelector)].find(b => {
          const label = (b.getAttribute('aria-label') || b.title || '').toLowerCase();
          return b.offsetParent !== null && !label.includes('record') && !label.includes('dictat');
        });
        const now = Date.now();
        if (stop && !busy) { busy = true; since = now; return; }
        if (!stop && busy) {
          busy = false;
          if (now - since < 2000) return;
          const replies = document.querySelectorAll(replySelector);
          const last = replies.length ? replies[replies.length - 1].innerText : '';
          window.webkit.messageHandlers.uai.postMessage({
            type: 'replyDone', title: document.title,
            preview: (last || '').replace(/\\s+/g, ' ').trim().slice(0, 220)
          });
        }
      }, 800);
    })();
    """
}

extension WebViewStore: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], body["type"] as? String == "replyDone",
              let id = provider(of: message.webView) else { return }
        onReply?(id, body["title"] as? String ?? "", body["preview"] as? String ?? "")
    }
}

/// WKUserContentController retains its message handlers; this proxy keeps
/// that from retaining the store.
private final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
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
        updateSignInState(for: webView)
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
        // Sign-in must happen inside UAI: a login completed in your browser
        // never reaches UAI. So only ordinary outside links (citations,
        // sources) go to the default browser, and never while signing in.
        if let url = navigationAction.request.url, shouldOpenInBrowser(url, from: webView, action: navigationAction) {
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
        window.appearance = NSAppearance(named: .darkAqua)
        let host = navigationAction.request.url?.host ?? ""
        window.title = host.isEmpty ? "Sign in" : "Sign in · " + host
        window.isReleasedWhenClosed = false
        window.contentView = popup
        window.center()
        window.makeKeyAndOrderFront(nil)
        popups.append(window)
        return popup
    }

    /// Hosts that run sign-in for other sites (Google, Apple, Microsoft, X…).
    private static let identityHosts = [
        "google.com", "apple.com", "icloud.com", "microsoft.com", "microsoftonline.com", "live.com",
        "facebook.com", "meta.com", "x.com", "twitter.com", "github.com", "okta.com", "auth0.com",
        "clerk.com", "clerk.dev", "stytch.com", "workos.com", "openai.com", "anthropic.com", "x.ai",
    ]

    private func shouldOpenInBrowser(_ url: URL, from webView: WKWebView, action: WKNavigationAction) -> Bool {
        guard action.navigationType == .linkActivated, url.scheme?.hasPrefix("http") == true,
              let host = url.host?.lowercased() else { return false }
        // Popups opened from sign-in windows, or while an AI is on its sign-in page, stay in UAI.
        guard let id = provider(of: webView), !needsSignIn.contains(id), !Self.isSignInURL(webView.url) else {
            return false
        }
        if Self.isSignInURL(url) { return false }
        let matches: (String) -> Bool = { host == $0 || host.hasSuffix("." + $0) }
        if Self.identityHosts.contains(where: matches) { return false }
        if Provider.get(id).hosts.contains(where: matches) { return false }
        return true
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
