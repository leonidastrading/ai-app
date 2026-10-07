import SwiftUI
import WebKit
import AppKit

struct SettingsView: View {
    var body: some View {
        TabView {
            AccountSettings().tabItem { Label("Profile", systemImage: "person.crop.circle") }
            ServicesSettings().tabItem { Label("AI Services", systemImage: "square.grid.2x2") }
            UniversalSettings().tabItem { Label("Universal AI", systemImage: "sparkles") }
            DataSettings().tabItem { Label("Data", systemImage: "externaldrive") }
        }
        .frame(width: 620, height: 470)
    }
}

private struct AccountSettings: View {
    @EnvironmentObject private var profile: Profile
    @EnvironmentObject private var webViews: WebViewStore
    @EnvironmentObject private var auth: AuthStore
    @State private var importing = false
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(auth.account?.name.isEmpty == false ? auth.account!.name : (auth.account?.email ?? "Signed in"))
                            .fontWeight(.medium)
                        if let email = auth.account?.email, !email.isEmpty {
                            Text(email).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Sign Out", role: .destructive) { auth.signOut() }
                }
            } header: {
                Text("UAI account")
            } footer: {
                Text("Signed in with Google. Your custom AIs, memory, recents, profile and layout sync across the Mac, Windows and web apps.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack(spacing: 14) {
                    AvatarView(image: profile.avatar, size: 56)
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("First name", text: $profile.name, prompt: Text("Your name"))
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            Button("Choose Photo…") { profile.chooseAvatarFromDisk() }
                            if profile.avatar != nil {
                                Button("Remove") { profile.setAvatar(nil) }
                            }
                        }
                    }
                }
            } header: {
                Text("Your profile")
            } footer: {
                Text("Shown as “you” in Universal AI. It stays on this Mac — there is no account to sign up for.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Button {
                    importing = true
                    message = nil
                    Task {
                        message = await profile.importFromGoogle(using: webViews) ?? "Imported from your Google account."
                        importing = false
                    }
                } label: {
                    if importing {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Reading Google account…") }
                    } else {
                        Label("Use my Google account", systemImage: "g.circle")
                    }
                }
                .disabled(importing)
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            } footer: {
                Text("Pulls your first name and photo from the Google account you're signed into in Gemini. Open Gemini and sign in first.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ServicesSettings: View {
    @ObservedObject private var registry = ProviderRegistry.shared

    var body: some View {
        Form {
            Section {
                ForEach(registry.all) { ProviderSettingsRow(provider: $0, registry: registry) }
            } header: {
                Text("Use the arrows to reorder the rail, or drag the icons in the sidebar.")
                    .font(.caption).foregroundStyle(.secondary)
            } footer: {
                Text("Each AI runs its own website inside UAI, signed in with your account, so chats stay in sync with its other apps. Change the address if a service moves.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ProviderSettingsRow: View {
    let provider: Provider
    @ObservedObject var registry: ProviderRegistry
    @AppStorage private var enabled: Bool
    @AppStorage private var url: String

    init(provider: Provider, registry: ProviderRegistry) {
        self.provider = provider
        self.registry = registry
        _enabled = AppStorage(wrappedValue: true, SettingsKey.enabled(provider.id))
        _url = AppStorage(wrappedValue: "", SettingsKey.homeURL(provider.id))
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(spacing: 1) {
                Button { registry.move(provider.id, by: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(registry.isFirst(provider.id)).help("Move up")
                Button { registry.move(provider.id, by: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(registry.isLast(provider.id)).help("Move down")
            }
            .buttonStyle(.borderless).font(.caption)

            Toggle("", isOn: $enabled).labelsHidden()
            ProviderIcon(provider: provider, size: 22)
            Text(provider.name).frame(width: 80, alignment: .leading)
            TextField("", text: $url, prompt: Text(provider.defaultHomeURL.absoluteString))
                .textFieldStyle(.roundedBorder)
            Button {
                let u = url.isEmpty ? provider.defaultHomeURL.absoluteString : url
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(u, forType: .string)
            } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help("Copy this AI's URL")
            if provider.isCustom {
                Button(role: .destructive) { ProviderRegistry.shared.remove(provider.id) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove \(provider.name)")
            }
        }
    }
}

private struct UniversalSettings: View {
    @AppStorage(SettingsKey.autoSend) private var autoSend = true
    @AppStorage(SettingsKey.smartRouting) private var smartRouting = true
    @AppStorage(SettingsKey.shareMemory) private var shareMemory = true
    @AppStorage(SettingsKey.notifications) private var notify = true
    @AppStorage(SettingsKey.notificationSound) private var notifySound = true
    @State private var apiKey = Keychain.read(Keychain.anthropicKey) ?? ""
    @State private var saved = false

    var body: some View {
        Form {
            Section("Sending") {
                Toggle("Press send automatically after routing", isOn: $autoSend)
                Toggle("Include shared memory in prompts", isOn: $shareMemory)
            }
            Section {
                Toggle("Notify me when an AI replies", isOn: $notify)
                Toggle("Play a sound when an AI replies", isOn: $notifySound)
                Button("Notification Settings…") { Notifier.shared.openSystemSettings() }
            } header: {
                Text("Notifications")
            } footer: {
                Text("You get a notification when an answer finishes while UAI is in the background or you're looking at a different AI. Unread replies also show as badges on the AI icons and the Dock.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Let Claude choose the best AI", isOn: $smartRouting)
                SecureField("Anthropic API key", text: $apiKey, prompt: Text("sk-ant-…"))
                HStack {
                    Button("Save Key") {
                        Keychain.write(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: Keychain.anthropicKey)
                        saved = true
                    }
                    if saved { Text("Saved to Keychain").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Link("Get a key", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                }
            } header: {
                Text("Smart routing")
            } footer: {
                Text("Optional. Without a key, UAI routes using built-in rules (images and video → Gemini, news → xAI, X posts → Grok, code → Claude, math → DeepSeek…). With a key, Claude reads each prompt and picks, including AIs you added, and Memory can learn from your chats. Each routing costs a fraction of a cent on your Anthropic API account.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct DataSettings: View {
    @EnvironmentObject private var universal: UniversalStore
    @EnvironmentObject private var memory: MemoryStore
    @EnvironmentObject private var updater: Updater
    @AppStorage(SettingsKey.autoCaptureMedia) private var autoCapture = true
    @State private var confirmSignOut = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: "UAI \(Updater.versionString)")
                HStack {
                    Button("Check for Updates…") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                    if !updater.isConfigured {
                        Text("Auto-update isn't set up for this build yet.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Updates")
            } footer: {
                Text("UAI updates itself from GitHub — it checks in the background, verifies each update, and installs it on quit. No manual reinstall.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Automatically save generated images and videos", isOn: $autoCapture)
                LabeledContent("Folder", value: Paths.media.path)
                Button("Show in Finder") { NSWorkspace.shared.open(Paths.media) }
            } header: {
                Text("Media")
            } footer: {
                Text("Off by default. When on, UAI saves images and videos it sees in an AI's replies — but on busy pages it may also grab unrelated images, so turn it on only for AIs where it helps. Files you download in UAI always appear here regardless.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("History") {
                Button("Clear Universal AI history") { universal.clear() }
                Button("Clear memory notes", role: .destructive) { memory.clear() }
            }
            Section("Accounts") {
                Button("Sign out of all AIs…", role: .destructive) { confirmSignOut = true }
                    .confirmationDialog("Sign out of every AI in UAI?", isPresented: $confirmSignOut) {
                        Button("Sign Out of All", role: .destructive) {
                            let store = WKWebsiteDataStore.default()
                            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                             modifiedSince: .distantPast) {}
                        }
                    } message: {
                        Text("This clears cookies and site data for every AI inside UAI. Your chats stay in your accounts.")
                    }
            }
        }
        .formStyle(.grouped)
    }
}
