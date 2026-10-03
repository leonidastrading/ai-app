import SwiftUI

@main
struct UAIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var app: AppState
    @StateObject private var index: ConversationIndex
    @StateObject private var media: MediaLibrary
    @StateObject private var universal: UniversalStore
    @StateObject private var webViews: WebViewStore

    init() {
        let index = ConversationIndex()
        let media = MediaLibrary()
        _app = StateObject(wrappedValue: AppState())
        _index = StateObject(wrappedValue: index)
        _media = StateObject(wrappedValue: media)
        _universal = StateObject(wrappedValue: UniversalStore())
        _webViews = StateObject(wrappedValue: WebViewStore(index: index, media: media))
    }

    var body: some Scene {
        WindowGroup("UAI") {
            MainView()
                .environmentObject(app)
                .environmentObject(index)
                .environmentObject(media)
                .environmentObject(universal)
                .environmentObject(webViews)
                .frame(minWidth: 960, minHeight: 600)
        }
        .defaultSize(width: 1440, height: 900)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {}
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
                Divider()
                Button("Universal AI") { app.go(.universal) }
                    .keyboardShortcut("1", modifiers: .command)
                ForEach(Array(Provider.all.enumerated()), id: \.element.id) { offset, provider in
                    Button(provider.name) { app.go(.provider(provider.id)) }
                        .keyboardShortcut(KeyEquivalent(Character(String(offset + 2))), modifiers: .command)
                }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(universal)
                .environmentObject(webViews)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launched from a bare executable (swift run) we'd otherwise be a background app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
