import SwiftUI

@main
struct UAIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var app: AppState
    @StateObject private var index: ConversationIndex
    @StateObject private var media: MediaLibrary
    @StateObject private var universal: UniversalStore
    @StateObject private var webViews: WebViewStore
    @StateObject private var memory: MemoryStore
    @StateObject private var profile = Profile()
    @StateObject private var notifHistory = NotificationHistory()
    @StateObject private var updater = Updater()
    @StateObject private var recents = GlobalRecents()
    @ObservedObject private var registry = ProviderRegistry.shared

    init() {
        let index = ConversationIndex()
        let media = MediaLibrary()
        _app = StateObject(wrappedValue: AppState())
        _index = StateObject(wrappedValue: index)
        _media = StateObject(wrappedValue: media)
        _universal = StateObject(wrappedValue: UniversalStore())
        _webViews = StateObject(wrappedValue: WebViewStore(index: index, media: media))
        _memory = StateObject(wrappedValue: MemoryStore(index: index))
    }

    var body: some Scene {
        WindowGroup("UAI") {
            MainView()
                .environmentObject(app)
                .environmentObject(index)
                .environmentObject(media)
                .environmentObject(universal)
                .environmentObject(webViews)
                .environmentObject(memory)
                .environmentObject(profile)
                .environmentObject(notifHistory)
                .environmentObject(recents)
                .frame(minWidth: 960, minHeight: 640)
        }
        .defaultSize(width: 1440, height: 900)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            CommandGroup(after: .toolbar) {
                Button("Zoom In") { zoomCurrent(by: 0.1) }
                    .keyboardShortcut("=", modifiers: .command)
                Button("Zoom Out") { zoomCurrent(by: -0.1) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Actual Size") {
                    if case .provider(let id) = app.destination { webViews.resetZoom(id) } else { app.resetUIZoom() }
                }
                .keyboardShortcut("0", modifiers: .command)
                Divider()
            }
            CommandMenu("Go") {
                Button("Back") { app.back(webViews: webViews) }
                    .keyboardShortcut("[", modifiers: .command)
                Button("Forward") { app.forward(webViews: webViews) }
                    .keyboardShortcut("]", modifiers: .command)
                Divider()
                Button("Search All AIs") { app.focusSearchTick += 1 }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Media") { app.toggleMedia() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                Button("Memory") { app.toggleMemory() }
                    .keyboardShortcut("y", modifiers: [.command, .shift])
                Button("Open Copied Link in UAI") { app.openCopiedLink(webViews: webViews) }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("Universal AI") { app.go(.universal) }
                    .keyboardShortcut("1", modifiers: .command)
                ForEach(Array(registry.all.prefix(8).enumerated()), id: \.element.id) { offset, provider in
                    Button(provider.name) { app.go(.provider(provider.id)) }
                        .keyboardShortcut(KeyEquivalent(Character(String(offset + 2))), modifiers: .command)
                }
                Divider()
                Button("Add AI…") { app.showAddAI = true }
                Button("Send My Working Rules to Claude") {
                    app.go(.provider(.claude))
                    Task { _ = await webViews.deliver(ClaudeRules.message, to: .claude, autoSend: true) }
                }
            }
        }

        Settings {
            SettingsView()
                .preferredColorScheme(.dark)
                .environmentObject(universal)
                .environmentObject(webViews)
                .environmentObject(memory)
                .environmentObject(profile)
                .environmentObject(updater)
        }
    }
}

extension UAIApp {
    func zoomCurrent(by delta: Double) {
        if case .provider(let id) = app.destination { webViews.adjustZoom(id, by: delta) }
        else { app.adjustUIZoom(by: delta) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Keeps App Nap from suspending background web views (and their reply
    /// detectors) when UAI isn't frontmost, so notifications still fire.
    private var backgroundActivity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launched from a bare executable (swift run) we'd otherwise be a background app.
        NSApp.setActivationPolicy(.regular)
        backgroundActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated], reason: "Watch open AIs for finished replies")
        // Dark everywhere, including the AIs' own pages (they follow the app's appearance).
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.activate(ignoringOtherApps: true)
        // Asks once for permission to notify you when an AI replies.
        Notifier.shared.start()

        // Paint every window near-black once so nothing ever flashes white —
        // the main window, Settings, and any sign-in popup, now and as they
        // open. Each window is painted a single time (tracked in `painted`) and
        // we listen only on becomeKey, never didUpdate, to avoid a redraw loop.
        paintWindows()
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
            if let window = note.object as? NSWindow { self?.paint(window) }
        }
    }

    private var painted = Set<ObjectIdentifier>()

    private func paintWindows() { NSApp.windows.forEach(paint) }

    private func paint(_ window: NSWindow) {
        let key = ObjectIdentifier(window)
        guard !painted.contains(key) else { return }
        painted.insert(key)
        window.backgroundColor = Theme.windowBackgroundNS
        window.appearance = NSAppearance(named: .darkAqua)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
