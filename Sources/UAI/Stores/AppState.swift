import SwiftUI

enum Destination: Hashable {
    case universal
    case provider(ProviderID)
    case media
    case memory
}

/// Top-level navigation: which workspace is showing, back/forward history,
/// the global search query, and transient toasts.
@MainActor
final class AppState: ObservableObject {
    @Published private(set) var destination: Destination = .universal
    @Published var searchText = ""
    @Published var focusSearchTick = 0
    /// Which search result is highlighted, and a counter the results view
    /// watches to open it when you press Return.
    @Published var searchSelection = 0
    @Published var searchResultCount = 0
    @Published var submitSearchTick = 0
    @Published var toast: String?
    /// Replies you haven't looked at yet, per AI. Mirrored on the Dock icon.
    @Published private(set) var unread: [ProviderID: Int] = [:] {
        didSet {
            let total = unread.values.reduce(0, +)
            NSApp.dockTile.badgeLabel = total > 0 ? "\(total)" : nil
        }
    }
    /// A copied link (e.g. an emailed sign-in link) UAI offers to open in an AI.
    @Published var pendingLink: (provider: ProviderID, url: URL)?
    @Published var showAddAI = false
    private var lastPasteboardChange = NSPasteboard.general.changeCount

    private var backStack: [Destination] = []
    private var forwardStack: [Destination] = []

    func go(_ destination: Destination) {
        guard destination != self.destination else { return }
        backStack.append(self.destination)
        forwardStack.removeAll()
        self.destination = destination
        markRead()
    }

    func markRead() {
        if case .provider(let id) = destination, unread[id] != nil { unread[id] = nil }
    }

    /// An AI finished replying. Count it as unread unless you're looking at it.
    func replyArrived(from id: ProviderID) -> Bool {
        if NSApp.isActive, destination == .provider(id) { return false }
        unread[id, default: 0] += 1
        return true
    }

    /// Called when UAI comes to the front: if you just copied a link that
    /// belongs to one of your AIs (like a sign-in link from an email), offer
    /// to open it inside UAI so the sign-in happens here, not in your browser.
    func checkPasteboardForLink() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastPasteboardChange else { return }
        lastPasteboardChange = pasteboard.changeCount
        guard let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.contains(" "), let url = URL(string: text), url.scheme?.hasPrefix("http") == true,
              let provider = Provider.matching(url) else { return }
        let lower = text.lowercased()
        let looksLikeSignIn = ["login", "signin", "sign-in", "magic", "verify", "auth", "token", "callback", "code=", "email"]
            .contains { lower.contains($0) }
        // Any X link would match Grok, so for X only offer real sign-in links.
        if looksLikeSignIn || provider.id != .grok {
            pendingLink = (provider.id, url)
        }
    }

    /// Opens whatever link is on the clipboard in the matching AI.
    func openCopiedLink(webViews: WebViewStore) {
        guard let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: text), let provider = Provider.matching(url) else {
            show(toast: "Copy a link from one of your AIs first (for example a sign-in link from an email).")
            return
        }
        open(url, in: provider.id, webViews: webViews)
    }

    func open(_ url: URL, in id: ProviderID, webViews: WebViewStore) {
        pendingLink = nil
        go(.provider(id))
        webViews.open(url, in: id)
    }

    /// The Media button toggles: pressing it again returns to where you were.
    func toggleMedia() { toggle(.media) }
    func toggleMemory() { toggle(.memory) }

    /// Media and Memory buttons toggle: pressing again returns to where you were.
    private func toggle(_ panel: Destination) {
        if destination == panel, !backStack.isEmpty {
            back(webViews: nil)
        } else {
            go(panel)
        }
    }

    /// Drops a removed AI from history so back/forward never lands on it.
    func forget(_ id: ProviderID) {
        backStack.removeAll { $0 == .provider(id) }
        forwardStack.removeAll { $0 == .provider(id) }
        unread[id] = nil
        if destination == .provider(id) { destination = .universal }
    }

    // Back/forward work like a browser inside the current AI first, then
    // step through the workspaces you visited (like Slack's history arrows).

    func canGoBack(webViews: WebViewStore) -> Bool {
        _ = webViews.navigationTick
        if case .provider(let id) = destination, webViews.existingWebView(for: id)?.canGoBack == true { return true }
        return !backStack.isEmpty
    }

    func canGoForward(webViews: WebViewStore) -> Bool {
        _ = webViews.navigationTick
        if case .provider(let id) = destination, webViews.existingWebView(for: id)?.canGoForward == true { return true }
        return !forwardStack.isEmpty
    }

    func back(webViews: WebViewStore?) {
        if case .provider(let id) = destination, let web = webViews?.existingWebView(for: id), web.canGoBack {
            web.goBack()
            return
        }
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(destination)
        destination = previous
        markRead()
    }

    func forward(webViews: WebViewStore?) {
        if case .provider(let id) = destination, let web = webViews?.existingWebView(for: id), web.canGoForward {
            web.goForward()
            return
        }
        guard let next = forwardStack.popLast() else { return }
        backStack.append(destination)
        destination = next
        markRead()
    }

    /// Pressing Return in the search field opens the highlighted result.
    func submitSearch() {
        guard searchResultCount > 0 else { return }
        submitSearchTick &+= 1
    }

    /// Up/down arrows move the highlight through the results.
    func moveSearchSelection(_ delta: Int) {
        guard searchResultCount > 0 else { return }
        searchSelection = (searchSelection + delta + searchResultCount) % searchResultCount
    }

    func show(toast message: String) {
        toast = message
        let current = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.toast == current { self?.toast = nil }
        }
    }
}
