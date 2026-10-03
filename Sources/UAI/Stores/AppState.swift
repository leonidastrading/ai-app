import SwiftUI

enum Destination: Hashable {
    case universal
    case provider(ProviderID)
    case media
}

/// Top-level navigation: which workspace is showing, back/forward history,
/// the global search query, and transient toasts.
@MainActor
final class AppState: ObservableObject {
    @Published private(set) var destination: Destination = .universal
    @Published var searchText = ""
    @Published var focusSearchTick = 0
    @Published var toast: String?

    private var backStack: [Destination] = []
    private var forwardStack: [Destination] = []

    func go(_ destination: Destination) {
        guard destination != self.destination else { return }
        backStack.append(self.destination)
        forwardStack.removeAll()
        self.destination = destination
    }

    /// The Media button toggles: pressing it again returns to where you were.
    func toggleMedia() {
        if destination == .media, !backStack.isEmpty {
            back(webViews: nil)
        } else {
            go(.media)
        }
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
    }

    func forward(webViews: WebViewStore?) {
        if case .provider(let id) = destination, let web = webViews?.existingWebView(for: id), web.canGoForward {
            web.goForward()
            return
        }
        guard let next = forwardStack.popLast() else { return }
        backStack.append(destination)
        destination = next
    }

    func show(toast message: String) {
        toast = message
        let current = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.toast == current { self?.toast = nil }
        }
    }
}
