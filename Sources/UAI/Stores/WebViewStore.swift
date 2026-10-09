import AppKit
import Combine
import CryptoKit
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
    /// AIs whose page has painted at least once, so we can cover the web view
    /// with a dark panel until then and never show a white flash.
    @Published private(set) var firstLoaded: Set<ProviderID> = []

    /// Called when an AI finishes writing a reply: (provider, page title, preview).
    var onReply: ((ProviderID, String, String) -> Void)?
    /// Called when you send a prompt in any AI: (provider, prompt text).
    var onPrompt: ((ProviderID, String) -> Void)?
    /// Called when a file you download from an AI finishes saving: (filename).
    var onDownload: ((String) -> Void)?
    private var lastDownloadName = "file"
    private var lastDownloadURL: URL?
    /// Called when Gemini finishes loading while signed in (for profile import).
    var onGeminiReady: (() -> Void)?

    let index: ConversationIndex
    let media: MediaLibrary

    private var webViews: [ProviderID: WKWebView] = [:]
    private var observers: [NSKeyValueObservation] = []
    private var popups: [NSWindow] = []
    private var indexTimer: Timer?
    /// Media URLs already saved, so reloads don't duplicate them.
    private var capturedURLs: Set<String>
    /// Content hashes of saved media, so the same image saved under a new URL
    /// each visit (as Gemini does) isn't duplicated.
    private var savedHashes: Set<String>
    private static let hashesKey = "media.hashes"
    /// Text zoom per AI (1.0 = 100%), set with ⌘+ / ⌘- / ⌘0.
    private var zoomLevels: [ProviderID: Double]
    private static let zoomKey = "webview.zoom"
    private static let capturedKey = "media.capturedURLs"

    var autoCapture: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.autoCaptureMedia) as? Bool ?? true
    }

    init(index: ConversationIndex, media: MediaLibrary) {
        self.index = index
        self.media = media
        capturedURLs = Set(UserDefaults.standard.stringArray(forKey: Self.capturedKey) ?? [])
        savedHashes = Set(UserDefaults.standard.stringArray(forKey: Self.hashesKey) ?? [])
        let savedZoom = UserDefaults.standard.dictionary(forKey: Self.zoomKey) as? [String: Double] ?? [:]
        zoomLevels = Dictionary(uniqueKeysWithValues: savedZoom.map { (ProviderID(rawValue: $0.key), $0.value) })
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
        config.userContentController.addUserScript(WKUserScript(
            source: Self.mediaCaptureScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        // Capture prompts you send in any AI, for the right bar's Recent list.
        config.userContentController.addUserScript(WKUserScript(
            source: Self.captureSendsScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        // Turn off autocorrect suggestions in the AIs' own text boxes, keeping
        // spellcheck (the red underline) on. Runs in every frame.
        config.userContentController.addUserScript(WKUserScript(
            source: Self.noAutocorrectScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        config.userContentController.add(ScriptMessageProxy(target: self), name: "uai")

        let webView = WKWebView(frame: .zero, configuration: config)
        // Allow Safari's Web Inspector to attach (Develop menu) so the reply
        // detector's console logs can be seen when debugging notifications.
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        webView.customUserAgent = Self.userAgent
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        // Never flash white: the under-page color shows until the page paints.
        webView.underPageBackgroundColor = Theme.windowBackgroundNS
        webView.wantsLayer = true
        webView.layer?.backgroundColor = Theme.windowBackgroundNS.cgColor
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

    struct GoogleIdentity { let name: String; let imageURL: String? }

    /// Reads the signed-in Google account's name and avatar from the Gemini
    /// web view, so the profile can use them. Nil if Gemini isn't signed in.
    /// `wait` false does a single quick check (for silent auto-import).
    func googleIdentity(wait: Bool = true) async -> GoogleIdentity? {
        let webView = self.webView(for: .gemini)
        let script = """
        (() => {
          let name = '', img = '';
          // The account button carries a label like "Google Account: Vadim (vadim54@gmail.com)".
          const labels = [...document.querySelectorAll('[aria-label*="Google Account" i], [aria-label*="Account:" i]')];
          for (const el of labels) {
            const m = (el.getAttribute('aria-label') || '').match(/Account:?\\s*([^(\\n]+?)\\s*[\\(\\n]/);
            if (m && m[1].trim()) { name = m[1].trim(); break; }
          }
          // Profile photo: Google serves it from googleusercontent.com.
          const photo = [...document.querySelectorAll('img')].find(i =>
            /googleusercontent\\.com|lh3\\.google/.test(i.currentSrc || i.src || ''));
          if (photo) img = photo.currentSrc || photo.src;
          // Fallbacks for the name from alt text.
          if (!name && photo) {
            const alt = (photo.getAttribute('alt') || '').replace(/profile photo|avatar/ig, '').trim();
            if (alt && alt.length < 40) name = alt;
          }
          return JSON.stringify({ name, img });
        })()
        """
        for _ in 0..<(wait ? 6 : 1) {
            if let json = await evaluate(script, in: webView), let data = json.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
               !(obj["name"]?.isEmpty ?? true) || !(obj["img"]?.isEmpty ?? true) {
                return GoogleIdentity(name: obj["name"] ?? "", imageURL: obj["img"]?.isEmpty == false ? obj["img"] : nil)
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
        return nil
    }

    /// Reads a site's profile avatar (e.g. Muse's Boobie) and uses it as the
    /// rail icon, so the icon matches the avatar you set on that service.
    func captureSiteAvatar(for id: ProviderID) {
        let webView = self.webView(for: id)
        // Prefer a round (border-radius) image — that's the profile avatar,
        // not a square logo — then the largest square one.
        let script = """
        (() => {
          const cand = [...document.querySelectorAll('img')].map(i => {
            const s = i.currentSrc || i.src || '';
            const w = i.naturalWidth || i.width, h = i.naturalHeight || i.height;
            const r = i.getBoundingClientRect();
            const rad = parseFloat(getComputedStyle(i).borderRadius) || 0;
            const round = rad >= Math.min(r.width, r.height) * 0.35 && r.width > 24;
            return { s, w, h, round };
          }).filter(o => o.s && !/favicon|logo|sprite|emoji|icon|\\.svg/i.test(o.s)
                         && o.w >= 64 && o.h >= 64 && o.w / o.h > 0.8 && o.w / o.h < 1.25);
          cand.sort((a, b) => (b.round - a.round) || (b.w * b.h - a.w * a.h));
          return cand.length ? cand[0].s : '';
        })()
        """
        Task { @MainActor in
            for delay in [1.5, 3.5, 6.0, 9.0] {
                try? await Task.sleep(for: .seconds(delay))
                // Keep refreshing an auto-set icon, but never override one you set yourself.
                let autoSet = Set(UserDefaults.standard.stringArray(forKey: "icon.auto") ?? [])
                guard ProviderRegistry.shared.customIconURL(id) == nil || autoSet.contains(id.rawValue) else { return }
                guard let urlString = await evaluate(script, in: webView), !urlString.isEmpty,
                      let url = URL(string: urlString),
                      let (data, _) = try? await URLSession.shared.data(from: url),
                      let image = NSImage(data: data) else { continue }
                ProviderRegistry.shared.setCustomIcon(id, image: image)
                UserDefaults.standard.set(Array(autoSet.union([id.rawValue])), forKey: "icon.auto")
                return
            }
        }
    }


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
        firstLoaded.remove(id)
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
    /// pressing send when `autoSend` is on. Any `attachments` are dropped into
    /// the AI's composer (as if you'd dragged the files in). Works by scripting
    /// the provider's own page, so the chat is created under your account and
    /// syncs everywhere.
    func deliver(_ prompt: String, to id: ProviderID, autoSend: Bool,
                 attachments: [Attachment] = [], newChat: Bool = true) async -> DeliveryResult {
        let webView = webView(for: id)
        if newChat {
            webView.load(URLRequest(url: Provider.get(id).homeURL))
            // Wait for the new-chat page to load before looking for the composer.
            try? await Task.sleep(for: .milliseconds(600))
        }
        for _ in 0..<40 where webView.isLoading {
            try? await Task.sleep(for: .milliseconds(250))
        }

        // Images are forwarded by pasting them from the system pasteboard (every
        // major AI accepts a pasted image — the file-input/drop trick doesn't
        // work on sites like Gemini). Other files still go via the composer.
        let images = attachments.filter(\.isImage)
        let others = attachments.filter { !$0.isImage }

        // Never auto-send while anything is attached — the AI needs a moment to
        // read the files before the message goes out.
        let effectiveAutoSend = autoSend && attachments.isEmpty
        let script = Self.deliverScript(prompt: prompt, autoSend: effectiveAutoSend,
                                        replace: newChat, attachments: others)
        var delivered: DeliveryResult = .failed
        for _ in 0..<(newChat ? 30 : 4) {
            let result = await evaluate(script, in: webView)
            if result == "sent" { delivered = .sent; break }
            if result == "inserted" { delivered = .inserted; break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        if delivered != .failed, !images.isEmpty {
            await pasteImages(images, into: webView)
        }
        return delivered
    }

    /// Writes each image to the pasteboard and pastes it into the AI's composer.
    private func pasteImages(_ images: [Attachment], into webView: WKWebView) async {
        let focusScript = """
        (() => {
          const v = el => { const r = el.getBoundingClientRect(); return r.width > 80 && r.height > 12 && el.offsetParent !== null; };
          const b = [...document.querySelectorAll('textarea, [contenteditable="true"], div[role="textbox"]')].filter(v);
          if (!b.length) return false;
          b.sort((x, y) => y.getBoundingClientRect().bottom - x.getBoundingClientRect().bottom);
          b[0].focus();
          return true;
        })()
        """
        for att in images {
            guard let comma = att.dataURL.firstIndex(of: ","),
                  let data = Data(base64Encoded: String(att.dataURL[att.dataURL.index(after: comma)...])),
                  let image = NSImage(data: data) else { continue }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
            _ = await evaluate(focusScript, in: webView)
            try? await Task.sleep(for: .milliseconds(200))
            webView.window?.makeFirstResponder(webView)
            // Route a paste: down the responder chain to the web view, which
            // inserts the pasteboard image into the focused composer.
            NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
            try? await Task.sleep(for: .milliseconds(1000))   // let the upload register
        }
    }

    private struct FilePayload: Encodable { let name: String; let mime: String; let dataURL: String }

    private static func deliverScript(prompt: String, autoSend: Bool, replace: Bool,
                                      attachments: [Attachment]) -> String {
        let literal = (try? String(data: JSONEncoder().encode(prompt), encoding: .utf8)) ?? "\"\""
        let payload = attachments.map { FilePayload(name: $0.name, mime: $0.mime, dataURL: $0.dataURL) }
        let filesLiteral = (try? String(data: JSONEncoder().encode(payload), encoding: .utf8)) ?? "[]"
        return """
        (() => {
          const text = \(literal);
          const files = \(filesLiteral);
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
          // Drop any attached files into the composer, as if dragged in. Most
          // AIs (ChatGPT, Gemini, Claude, Grok) accept a drop with a DataTransfer.
          if (files.length) {
            try {
              const toFile = (d, name, type) => {
                const a = d.split(','); const b = atob(a[1]); let n = b.length;
                const u = new Uint8Array(n); while (n--) u[n] = b.charCodeAt(n);
                return new File([u], name, { type });
              };
              const dt = new DataTransfer();
              for (const f of files) dt.items.add(toFile(f.dataURL, f.name, f.mime));
              // Prefer a real file <input> if the composer has one — most reliable.
              const inputs = [...document.querySelectorAll('input[type="file"]')];
              let usedInput = false;
              for (const inp of inputs) {
                try { inp.files = dt.files; inp.dispatchEvent(new Event('change', { bubbles: true })); usedInput = true; break; } catch (e) {}
              }
              if (!usedInput) {
                const r = box.getBoundingClientRect();
                const opt = { bubbles: true, cancelable: true, dataTransfer: dt, clientX: r.left + 20, clientY: r.top + 20 };
                box.dispatchEvent(new DragEvent('dragenter', opt));
                box.dispatchEvent(new DragEvent('dragover', opt));
                box.dispatchEvent(new DragEvent('drop', opt));
              }
            } catch (e) {}
          }
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

    /// Finds images and videos an AI generates in its replies and sends them
    /// to the app to save into Media, so you don't have to download each one.
    static let mediaCaptureScript = """
    (() => {
      if (window.__uaiMedia) return;
      window.__uaiMedia = true;
      const seen = new Set();
      const skip = /avatar|favicon|logo|icon|emoji|profile|sprite|thumb_small|spinner|badge/i;
      const send = (url, name, dataURL, role) =>
        window.webkit.messageHandlers.uai.postMessage({ type: 'media', url, name, dataURL, role });

      // Is this image in one of YOUR messages (a screenshot/upload) or in the
      // AI's reply (generated)? Best-effort across sites; defaults to generated.
      const roleOf = (el) => {
        for (let n = el, i = 0; n && i < 14; n = n.parentElement, i++) {
          const r = (n.getAttribute && (n.getAttribute('data-message-author-role') || '')).toLowerCase();
          if (r === 'user') return 'user';
          if (r === 'assistant' || r === 'model') return 'assistant';
          const cls = (n.className && typeof n.className === 'string') ? n.className.toLowerCase() : '';
          if (/user-query|from-user|human-turn|user-message|query-content|request-/.test(cls)) return 'user';
          if (/assistant|model-response|agent-|response-|markdown/.test(cls)) return 'assistant';
        }
        return 'assistant';
      };

      // Draw a loaded <img> onto a canvas and read its PNG bytes. Works for
      // cross-origin images only when the server allows it; otherwise throws.
      const viaCanvas = (img) => {
        try {
          const c = document.createElement('canvas');
          c.width = img.naturalWidth; c.height = img.naturalHeight;
          c.getContext('2d').drawImage(img, 0, 0);
          return c.toDataURL('image/png');
        } catch (e) { return null; }
      };

      const grab = async (img, src, name, role) => {
        // 1) A fresh CORS-anonymous image usually lets us read Google/OpenAI CDN pixels.
        const clone = new Image();
        clone.crossOrigin = 'anonymous';
        const done = new Promise((res) => {
          clone.onload = () => res(viaCanvas(clone));
          clone.onerror = () => res(null);
          setTimeout(() => res(null), 6000);
        });
        clone.src = src;
        let dataURL = await done;
        // 2) Same-origin / blob: images can be fetched directly.
        if (!dataURL) {
          for (const opts of [{}, { credentials: 'include' }]) {
            try {
              const r = await fetch(src, opts);
              if (!r.ok) continue;
              const blob = await r.blob();
              if (blob.size < 12000) return;
              dataURL = await new Promise((res, rej) => {
                const fr = new FileReader();
                fr.onloadend = () => res(fr.result); fr.onerror = rej;
                fr.readAsDataURL(blob);
              });
              break;
            } catch (e) { /* try next */ }
          }
        }
        // 3) Last resort: hand the app the URL to download with your cookies.
        send(src, name, dataURL || undefined, role);
      };

      // Only capture media that appears AFTER the page settles — i.e. things
      // an AI generates in reply to you — never the images already on the page
      // (feeds, galleries, UI). That's what pulled in unrelated images before.
      let armed = false;
      const tryImg = (img) => {
        const src = img.currentSrc || img.src;
        if (!src || seen.has(src) || skip.test(src)) return;
        if (/^data:image\\/(gif|svg)/.test(src)) return;
        const w = img.naturalWidth || img.width, h = img.naturalHeight || img.height;
        if (w < 256 || h < 256) return;
        seen.add(src);
        if (!armed) return;           // pre-existing content: remember, don't save
        const name = (img.getAttribute('alt') || '').slice(0, 60);
        const role = roleOf(img);
        if (src.startsWith('data:image')) { send(src, name, src, role); return; }  // already have the bytes
        grab(img, src, name, role);
      };
      const tryVideo = (v) => {
        const src = v.currentSrc || v.src || (v.querySelector('source') || {}).src;
        if (!src || seen.has(src) || src.startsWith('blob:')) return;
        seen.add(src);
        if (armed) send(src, '', undefined);
      };
      const watchImg = (i) => {
        const s = i.currentSrc || i.src || '';
        if (s.startsWith('data:image')) { tryImg(i); return; }   // inline base64 image
        i.complete && i.naturalWidth ? tryImg(i) : i.addEventListener('load', () => tryImg(i));
      };
      const watch = (node) => {
        if (node.tagName === 'IMG') watchImg(node);
        else if (node.tagName === 'VIDEO') tryVideo(node);
        if (node.querySelectorAll) {
          node.querySelectorAll('img').forEach(watchImg);
          node.querySelectorAll('video').forEach(tryVideo);
        }
      };
      window.__uaiScanMedia = () => { armed = true; watch(document); };

      // Screenshots / images YOU attach are captured the moment you add them —
      // from paste, drag-and-drop, or the file picker — at full resolution and
      // with the real bytes, so they reliably land in the Screenshots tab even
      // when the site only renders a tiny CORS-locked thumbnail.
      const sawFile = (file) => {
        if (!file || !/^image\\//.test(file.type || '')) return;
        const key = 'upload:' + (file.name || 'screenshot') + ':' + file.size;
        if (seen.has(key)) return;
        seen.add(key);
        const fr = new FileReader();
        fr.onload = () => send(key, file.name || 'screenshot', fr.result, 'user');
        fr.readAsDataURL(file);
      };
      document.addEventListener('paste', (e) => {
        const items = (e.clipboardData || {}).items || [];
        for (const it of items) if (it.kind === 'file') sawFile(it.getAsFile());
      }, true);
      document.addEventListener('drop', (e) => {
        const files = ((e.dataTransfer || {}).files) || [];
        for (const f of files) sawFile(f);
      }, true);
      document.addEventListener('change', (e) => {
        const t = e.target;
        if (t && t.tagName === 'INPUT' && (t.type || '').toLowerCase() === 'file' && t.files) {
          for (const f of t.files) sawFile(f);
        }
      }, true);
      const start = () => {
        watch(document);            // mark everything currently on the page as seen
        // Watch for new media, but coalesce bursts of DOM changes into one
        // scan every ~800ms so heavy apps (e.g. Claude) aren't bogged down.
        let pending = false;
        new MutationObserver(() => {
          if (pending) return;
          pending = true;
          setTimeout(() => { pending = false; watch(document); }, 800);
        }).observe(document.documentElement, { childList: true, subtree: true });
        setTimeout(() => { armed = true; }, 3500);
      };
      if (document.body) start(); else document.addEventListener('DOMContentLoaded', start);
    })();
    """

    /// Reports the prompt you send in any AI (Enter in the composer, or a click
    /// on a Send/Submit button) so the right bar can list recent prompts.
    static let captureSendsScript = """
    (() => {
      if (window.__uaiCaptureSends) return;
      window.__uaiCaptureSends = true;
      const textOf = (el) => (el ? (el.value || el.innerText || '').trim() : '');
      const isBox = (el) => el && (el.tagName === 'TEXTAREA' || el.isContentEditable || (el.getAttribute && el.getAttribute('role') === 'textbox'));
      const report = (text) => { if (text && text.length <= 20000) window.webkit.messageHandlers.uai.postMessage({ type: 'prompt', text }); };
      document.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' && !e.shiftKey && isBox(document.activeElement)) report(textOf(document.activeElement));
      }, true);
      document.addEventListener('click', (e) => {
        const btn = e.target.closest && e.target.closest('button,[role="button"]');
        if (!btn) return;
        const label = ((btn.getAttribute('aria-label') || '') + ' ' + (btn.title || '') + ' ' + (btn.textContent || '')).toLowerCase();
        if (/\\bsend\\b|submit/.test(label)) {
          const box = [...document.querySelectorAll('textarea,[contenteditable="true"],div[role="textbox"]')].find((b) => textOf(b));
          report(textOf(box));
        }
      }, true);
    })();
    """

    /// Sets autocorrect="off" (WebKit honors it) on every editable field so
    /// the OS stops popping word suggestions, while leaving spellcheck on.
    static let noAutocorrectScript = """
    (() => {
      if (window.__uaiNoAutocorrect) return;
      window.__uaiNoAutocorrect = true;
      const fix = (el) => {
        if (!el || !el.setAttribute) return;
        const tag = el.tagName, editable = el.isContentEditable;
        if (tag === 'TEXTAREA' || editable || (tag === 'INPUT' &&
            /^(text|search|email|url|)$/i.test(el.getAttribute('type') || ''))) {
          el.setAttribute('autocorrect', 'off');
          el.setAttribute('autocapitalize', 'off');
          if (!el.hasAttribute('spellcheck')) el.setAttribute('spellcheck', 'true');
        }
      };
      const scan = (root) => {
        try { root.querySelectorAll('textarea, input, [contenteditable]').forEach(fix); } catch (e) {}
      };
      // Re-scan at most a few times a second instead of on every mutation,
      // so heavy apps (e.g. Claude) aren't bogged down.
      const start = () => {
        scan(document);
        let pending = false;
        new MutationObserver(() => {
          if (pending) return;
          pending = true;
          setTimeout(() => { pending = false; scan(document); }, 600);
        }).observe(document.documentElement, { childList: true, subtree: true });
      };
      if (document.documentElement) start();
      else document.addEventListener('DOMContentLoaded', start);
    })();
    """

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

    /// Detects when an AI finishes replying. Rather than relying only on each
    /// site's "Stop" button (sites keep changing it), it also watches the reply
    /// text itself: a reply that was streaming and then stops growing for ~2.5s
    /// is done. Guards against false positives when you merely open an existing
    /// chat (one big jump, not sustained streaming) and dedupes repeats.
    static let replyWatcherScript = """
    (() => {
      if (window.__uaiReplyWatch) return;
      window.__uaiReplyWatch = true;
      const stopSelector = [
        'button[aria-label*="Stop" i]', 'button[data-testid*="stop" i]',
        '[role="button"][aria-label*="Stop" i]', 'button[title*="Stop" i]',
        'button[aria-label*="generating" i]', '[data-testid="stop-button"]'
      ].join(',');
      // Known containers first, then broad class-name conventions so sites we
      // don't special-case (e.g. Muse) are still covered.
      const replySelector = [
        '[data-message-author-role="assistant"]', '.font-claude-response', '.font-claude-message',
        'model-response', '.model-response-text', '.ds-markdown', '[data-testid="assistant-message"]',
        '[data-testid="markdown"]', '.message-bubble', '.markdown', '.prose',
        '[class*="assistant" i]', '[class*="message" i]', '[class*="response" i]', '[class*="bubble" i]'
      ].join(',');
      const measure = () => {
        const els = document.querySelectorAll(replySelector);
        let total = 0;                       // textContent: cheap, no reflow
        for (const e of els) total += (e.textContent || '').length;
        // Preview source = the LAST matched element that actually has text, so
        // trailing UI chrome (empty buttons/containers) doesn't blank the
        // preview and suppress the event.
        let lastEl = null;
        for (let i = els.length - 1; i >= 0; i--) {
          if (((els[i].innerText || '').trim().length) > 20) { lastEl = els[i]; break; }
        }
        if (!lastEl && els.length) lastEl = els[els.length - 1];
        return { total, count: els.length, lastEl };
      };
      // Strip private-use-area glyphs (icon fonts render as tofu boxes outside
      // their font) and control chars, so previews are readable; keep emoji.
      const clean = (s) => (s || '')
        .replace(/[\\uE000-\\uF8FF]/g, '')
        .replace(/[\\uDB80-\\uDBFF][\\uDC00-\\uDFFF]/g, '')
        .replace(/[\\u0000-\\u0008\\u000B\\u000C\\u000E-\\u001F\\uFFFD]/g, '')
        .replace(/\\s+/g, ' ').trim();
      // Claude Code is an agentic tool: it works for a long time and keeps a
      // stable status string ("Thinking running") while still going, so no
      // text/stop heuristic can tell "working" from "done" — detecting replies
      // there only produces false notifications. Skip reply detection for it.
      // Checked live (not once) so SPA navigation within the tab is honored.
      const isAgentPage = () => (location.host === 'claude.ai' && /^\\/code(\\/|$)/.test(location.pathname));
      let lastFired = '';
      // What you've already looked at: the largest reply length that was on
      // screen while this tab was visible AND focused. Lets us drop a late
      // "reply done" ping for something you already read in UAI — even when the
      // page's timer was throttled in the background and only detected "done" a
      // minute late (macOS throttles timers in occluded/background web views).
      let seenTotal = 0;
      const present = () => (document.visibilityState === 'visible' && document.hasFocus());
      const markSeen = () => { if (present()) { try { seenTotal = Math.max(seenTotal, measure().total); } catch (e) {} } };
      document.addEventListener('visibilitychange', markSeen, true);
      window.addEventListener('focus', markSeen, true);
      const fire = (m) => {
        if (isAgentPage()) return;
        // You're looking at it right now, or you've already seen a reply at
        // least this long on screen → no notification. Otherwise it finished
        // while you were away, so it's worth a ping.
        if (present() || m.total <= seenTotal) { seenTotal = Math.max(seenTotal, m.total); return; }
        const preview = clean((m.lastEl && m.lastEl.innerText) || '').slice(0, 220);
        if (preview && preview !== lastFired) {
          lastFired = preview;
          try { window.webkit.messageHandlers.uai.postMessage({ type: 'replyDone', title: clean(document.title), preview }); }
          catch (e) {}
        }
        try { window.__uaiScanMedia && window.__uaiScanMedia(); } catch (e) {}
        setTimeout(() => { try { window.__uaiScanMedia && window.__uaiScanMedia(); } catch (e) {} }, 2500);
      };
      // Two independent signals: (1) the Stop button is definitive — when it
      // goes away the reply is done, fire ~1.5s later regardless of other page
      // churn; (2) text growth is only a fallback for sites with no recognizable
      // stop button, and never runs during a stop cycle, so busy pages can't
      // block the reliable path.
      let stopBusy = false, stopGone = 0;
      let lastTotal = -1, lastCount = -1, sawGrowth = false, lastChange = 0;
      setInterval(() => {
        const now = Date.now();
        const stop = [...document.querySelectorAll(stopSelector)].find(b => {
          const label = (b.getAttribute('aria-label') || b.title || '').toLowerCase();
          return b.offsetParent !== null && !label.includes('record') && !label.includes('dictat');
        });
        const m = measure();

        // Keep the "already seen" watermark current while you're looking. A
        // total much shorter than we've marked means a different/cleared chat,
        // so reset it (to the current length if you're here, else 0 so the next
        // reply there can still notify).
        if (m.total + 50 < seenTotal) seenTotal = present() ? m.total : 0;
        else if (present()) seenTotal = Math.max(seenTotal, m.total);

        if (stop) { stopBusy = true; stopGone = 0; }
        else if (stopBusy) {
          if (!stopGone) stopGone = now;
          if (now - stopGone > 1500) {
            stopBusy = false; stopGone = 0; sawGrowth = false;
            lastTotal = m.total; lastCount = m.count;
            fire(m);
            return;
          }
        }

        if (lastTotal < 0) { lastTotal = m.total; lastCount = m.count; lastChange = now; return; }
        // Fire when the reply has GROWN and then the page goes fully STABLE — no
        // text change up OR down — for the settle window. This is the key to not
        // false-firing on agent UIs (e.g. Claude Code "thinking/running"), which
        // churn constantly and so never reach a stable window; they only notify
        // once everything truly settles. Requiring prior growth keeps idle pages
        // from firing. The stop-gone path above is a faster trigger when a real
        // transient Stop button exists; this covers persistent/absent ones.
        const delta = m.total - lastTotal;
        if (delta > 12) sawGrowth = true;
        if (Math.abs(delta) > 12 || m.count !== lastCount) lastChange = now;
        if (sawGrowth && now - lastChange > 2500) { sawGrowth = false; fire(m); }
        lastTotal = m.total; lastCount = m.count;
      }, 700);
    })();
    """
}

extension WebViewStore: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String,
              let id = provider(of: message.webView) else { return }
        switch type {
        case "replyDone":
            onReply?(id, body["title"] as? String ?? "", body["preview"] as? String ?? "")
        case "media":
            captureMedia(provider: id, body: body)
        case "prompt":
            if let text = body["text"] as? String { onPrompt?(id, text) }
        default:
            break
        }
    }

    /// Saves an image or video that an AI generated in the page into the
    /// Media folder, so it shows up in Media without a manual download.
    private func captureMedia(provider id: ProviderID, body: [String: Any]) {
        guard autoCapture, let url = body["url"] as? String, !capturedURLs.contains(url) else { return }
        capturedURLs.insert(url)
        // Keep the set bounded so it doesn't grow forever.
        if capturedURLs.count > 4000 { capturedURLs = Set(capturedURLs.suffix(2000)) }
        UserDefaults.standard.set(Array(capturedURLs), forKey: Self.capturedKey)

        // Images that appear in YOUR messages (uploaded screenshots, pastes)
        // go to a separate Screenshots folder, not mixed with generated media.
        let isScreenshot = body["role"] as? String == "user"
        let folder = isScreenshot ? Paths.screenshots : Paths.mediaFolder(for: id)
        let suggested = body["name"] as? String ?? ""

        if let dataURL = body["dataURL"] as? String,
           let comma = dataURL.firstIndex(of: ","),
           let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])), !data.isEmpty {
            guard rememberHash(of: data) else { return }   // already have this exact image
            let ext = Self.fileExtension(fromDataURL: dataURL, fallbackName: suggested)
            let name = Self.filename(suggested: suggested, url: url, ext: ext)
            let dest = Paths.uniqueFile(named: name, in: folder)
            try? data.write(to: dest)
            media.reload()
            lastDownload = dest
            return
        }

        // No bytes from the page (cross-origin blocked fetch): try downloading
        // the URL ourselves with the site's cookies.
        guard let remote = URL(string: url) else { return }
        Task { @MainActor in
            let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
            var request = URLRequest(url: remote)
            request.allHTTPHeaderFields = HTTPCookie.requestHeaderFields(
                with: cookies.filter { remote.host?.hasSuffix($0.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))) == true })
            if let referer = existingWebView(for: id)?.url?.absoluteString { request.setValue(referer, forHTTPHeaderField: "Referer") }
            guard let (data, response) = try? await URLSession.shared.data(for: request), !data.isEmpty else { return }
            guard rememberHash(of: data) else { return }
            let ext = Self.fileExtension(fromResponse: response, url: remote, fallbackName: suggested)
            let name = Self.filename(suggested: suggested, url: url, ext: ext)
            let dest = Paths.uniqueFile(named: name, in: folder)
            try? data.write(to: dest)
            media.reload()
            lastDownload = dest
        }
    }

    /// Records the content hash of `data`. Returns false if we've already saved
    /// an image with this exact content (so the caller skips writing a dup).
    private func rememberHash(of data: Data) -> Bool {
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard !savedHashes.contains(hash) else { return false }
        savedHashes.insert(hash)
        if savedHashes.count > 4000 { savedHashes = Set(savedHashes.suffix(2000)) }
        UserDefaults.standard.set(Array(savedHashes), forKey: Self.hashesKey)
        return true
    }

    private static func filename(suggested: String, url: String, ext: String) -> String {
        let fromName = suggested.trimmingCharacters(in: .whitespaces)
        if !fromName.isEmpty, fromName.count <= 80 {
            return fromName.contains(".") ? fromName : "\(fromName).\(ext)"
        }
        let stem = URL(string: url)?.deletingPathExtension().lastPathComponent
        let base = (stem?.isEmpty == false ? stem! : "generated")
            .replacingOccurrences(of: "/", with: "-")
        let stamp = Int(Date().timeIntervalSince1970)
        return "\(base.prefix(40))-\(stamp).\(ext)"
    }

    private static func fileExtension(fromDataURL dataURL: String, fallbackName: String) -> String {
        if let slash = dataURL.range(of: "/"), let semi = dataURL.range(of: ";") ?? dataURL.range(of: ",") {
            let sub = String(dataURL[slash.upperBound..<semi.lowerBound])
            if !sub.isEmpty, sub.count <= 5 { return sub == "jpeg" ? "jpg" : sub }
        }
        return (fallbackName as NSString).pathExtension.isEmpty ? "png" : (fallbackName as NSString).pathExtension
    }

    private static func fileExtension(fromResponse response: URLResponse, url: URL, fallbackName: String) -> String {
        if !url.pathExtension.isEmpty, url.pathExtension.count <= 5 { return url.pathExtension }
        switch response.mimeType {
        case "image/png": return "png"
        case "image/jpeg": return "jpg"
        case "image/webp": return "webp"
        case "image/gif": return "gif"
        case "video/mp4": return "mp4"
        case "video/webm": return "webm"
        default: return "png"
        }
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
        // A link you click in a reply that points OUTSIDE the AI's own site
        // opens in your default browser (a new tab there) — never inside UAI.
        // The AI's own pages and any sign-in flow stay in-app.
        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url,
           url.scheme?.hasPrefix("http") == true,
           navigationAction.targetFrame?.isMainFrame ?? true,
           let id = provider(of: webView),
           !isInternalHost(url.host, for: id),
           !Self.isSignInURL(url), !isIdentityHost(url) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    /// True when `host` belongs to the AI's own site (so navigation stays in-app).
    private func isInternalHost(_ host: String?, for id: ProviderID) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return Provider.get(id).hosts.contains { host == $0 || host.hasSuffix("." + $0) }
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
            firstLoaded.insert(id)
            applyZoom(id)
            if id == .gemini, !Self.isSignInURL(webView.url) { onGeminiReady?() }
            // (Muse icon auto-capture removed — it grabbed random page images.
            //  Muse uses its normal site icon by default; set your own via
            //  right-click → Set Icon… if you want.)
        }
        focusComposer(in: webView)
        if let id = provider(of: webView) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak webView] in
                guard let self, let webView else { return }
                self.indexChats(in: webView, provider: id)
            }
        }
    }

    /// Puts the cursor in the AI's message box after its page loads, so you
    /// can type right away — like the composer in Universal AI.
    private func focusComposer(in webView: WKWebView) {
        guard !Self.isSignInURL(webView.url) else { return }
        let script = """
        (() => {
          const visible = el => {
            const r = el.getBoundingClientRect();
            return r.width > 80 && r.height > 12 && el.offsetParent !== null && !el.disabled && !el.readOnly;
          };
          const boxes = [...document.querySelectorAll('textarea, [contenteditable="true"], div[role="textbox"]')].filter(visible);
          if (!boxes.length) return false;
          boxes.sort((a, b) => b.getBoundingClientRect().bottom - a.getBoundingClientRect().bottom);
          boxes[0].focus();
          return true;
        })()
        """
        for delay in [0.4, 1.0, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak webView] in
                webView?.evaluateJavaScript(script)
            }
        }
    }

    // MARK: - Text zoom (⌘+/⌘-/⌘0)

    func adjustZoom(_ id: ProviderID, by delta: Double) {
        let level = max(0.5, min(3.0, (zoomLevels[id] ?? 1.0) + delta))
        zoomLevels[id] = level
        saveZoom()
        applyZoom(id)
    }

    func resetZoom(_ id: ProviderID) {
        zoomLevels[id] = 1.0
        saveZoom()
        applyZoom(id)
    }

    private func applyZoom(_ id: ProviderID) {
        let level = zoomLevels[id] ?? 1.0
        webViews[id]?.evaluateJavaScript("document.documentElement.style.zoom='\(level)';")
    }

    private func saveZoom() {
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: zoomLevels.map { ($0.key.rawValue, $0.value) }),
                                  forKey: Self.zoomKey)
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        // Let you choose where on your computer to save it (like a browser),
        // defaulting to Downloads — not hidden away in the app's Media folder.
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename.isEmpty ? "download" : suggestedFilename
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { completionHandler(nil); return }
            self?.lastDownloadURL = url
            self?.lastDownloadName = url.lastPathComponent
            completionHandler(url)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        if let url = lastDownloadURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])   // reveal in Finder
        }
        onDownload?(lastDownloadName)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        NSSound.beep()
    }
}

// MARK: - Popups (sign-in windows), file pickers, alerts, mic/camera

extension WebViewStore: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Every link an AI opens in a new tab/window goes to the default
        // browser — EXCEPT sign-in flows, which must stay inside UAI or the
        // login never reaches it. A popup with no URL yet (about:blank that a
        // script then points at a login page) is treated as sign-in too.
        let url = navigationAction.request.url
        // Stay in-app only for: a script-driven popup with no URL yet
        // (about:blank that then loads a login page), a known sign-in URL, an
        // identity provider (Google, Apple, X…), or the AI's OWN pages (so a
        // same-site "open in new tab" doesn't force a re-login in the browser).
        // Everything else an AI opens in a new tab goes to your default browser
        // — even when UAI thinks this AI still needs a sign-in.
        let isOwnHost = provider(of: webView).map { isInternalHost(url?.host, for: $0) } ?? false
        let keepInApp = url == nil || Self.isSignInURL(url) || isIdentityHost(url) || isOwnHost
        if let url, url.scheme?.hasPrefix("http") == true, !keepInApp {
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
        window.backgroundColor = Theme.windowBackgroundNS
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

    private func isIdentityHost(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return Self.identityHosts.contains { host == $0 || host.hasSuffix("." + $0) }
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
