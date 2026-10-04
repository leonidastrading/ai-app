import SwiftUI

/// Universal AI: type once, and UAI sends the prompt to whichever AI suits
/// the task best, as a new chat in that AI under your own account.
struct UniversalView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var universal: UniversalStore
    @EnvironmentObject private var webViews: WebViewStore
    @EnvironmentObject private var memory: MemoryStore
    @EnvironmentObject private var profile: Profile
    @AppStorage(SettingsKey.autoSend) private var autoSend = true
    @AppStorage(SettingsKey.shareMemory) private var shareMemory = true

    @State private var draft = ""
    @State private var override: ProviderID?
    @State private var sending = false
    @FocusState private var composerFocused: Bool

    private var enabled: [ProviderID] { Provider.all.filter(\.isEnabled).map(\.id) }
    private var preview: RouteDecision? {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let override { return RouteDecision(provider: override, reason: "Chosen by you", routedBy: "You") }
        return Router.rules(text, among: enabled)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 22) {
                    Spacer(minLength: 40)
                    hero
                    composer
                    if let preview { routePreview(preview) }
                    recents
                    Spacer(minLength: 40)
                }
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
        }
        .background(Theme.contentBackground)
        .onAppear { focusSoon() }
        // Coming back to Universal AI from an AI should re-focus the box.
        .onChange(of: app.destination) { if app.destination == .universal { focusSoon() } }
    }

    private func focusSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { composerFocused = true }
    }

    private var hero: some View {
        VStack(spacing: 12) {
            GalaxyIcon(size: 72)
            Text("Universal AI").font(.system(size: 30, weight: .bold))
            Text("Ask anything. UAI picks the best AI and starts the chat there.")
                .font(.title3).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var composer: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                TextField("Message Universal AI…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20))
                    .lineLimit(1...8)
                    .focused($composerFocused)
                    .onSubmit(send)
                    .padding(.vertical, 4)
                Button(action: send) {
                    Image(systemName: sending ? "hourglass" : "arrow.up")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(draft.trimmingCharacters(in: .whitespaces).isEmpty ? Color.gray.opacity(0.4) : Theme.pink,
                                    in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.pink.opacity(composerFocused ? 0.6 : 0.2), lineWidth: 1.5))

            HStack(spacing: 14) {
                Menu {
                    Button("Automatic") { override = nil }
                    Divider()
                    ForEach(enabled, id: \.self) { id in
                        Button(Provider.get(id).name) { override = id }
                    }
                } label: {
                    Label(override.map { "Send to \(Provider.get($0).name)" } ?? "Automatic routing",
                          systemImage: "arrow.triangle.branch")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .fixedSize()
                Spacer()
                Toggle(isOn: $shareMemory) {
                    Label("Memory", systemImage: "brain.head.profile")
                }
                .toggleStyle(.checkbox).font(.caption)
                .help("Add what UAI remembers about you, plus related chats from your other AIs")
                Toggle("Auto-send", isOn: $autoSend)
                    .toggleStyle(.checkbox).font(.caption)
            }
            .padding(.horizontal, 4)
        }
    }

    private func routePreview(_ preview: RouteDecision) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary)
            Text("Goes to").foregroundStyle(.secondary)
            ProviderIcon(provider: Provider.get(preview.provider), size: 18)
            Text(Provider.get(preview.provider).name).fontWeight(.semibold)
            Text("· \(preview.reason)").foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    @ViewBuilder
    private var recents: some View {
        if universal.history.isEmpty {
            VStack(spacing: 6) {
                Text("Tip: type what you want. Images go to Gemini, code to Claude, news to xAI, and so on.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Text("First time? Open each AI from the left rail once and sign in.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.top, 8)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("RECENT").font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(universal.history.prefix(8)) { entry in
                    RoutedMessage(entry: entry)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 10)
        }
    }

    private func send() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !sending else { return }
        sending = true
        let chosen = override
        Task {
            let decision: RouteDecision
            if let chosen {
                decision = RouteDecision(provider: chosen, reason: "Chosen by you", routedBy: "You")
            } else {
                decision = await Router.route(prompt, among: enabled)
            }
            universal.add(RoutedPrompt(date: Date(), prompt: prompt, provider: decision.provider,
                                       reason: decision.reason, routedBy: decision.routedBy))
            draft = ""
            override = nil
            sending = false
            app.go(.provider(decision.provider))

            let name = Provider.get(decision.provider).name
            let message = memory.prompt(prompt, for: decision.provider)
            switch await webViews.deliver(message, to: decision.provider, autoSend: autoSend) {
            case .sent: app.show(toast: "Sent to \(name) · \(decision.reason)")
            case .inserted: app.show(toast: "Prompt is ready in \(name). Press Return to send.")
            case .failed:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message, forType: .string)
                app.show(toast: "Couldn't find \(name)'s message box (signed in?). Prompt copied; paste with ⌘V.")
            }
        }
    }
}

private struct RoutedMessage: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var profile: Profile
    let entry: RoutedPrompt

    var body: some View {
        let provider = Provider.get(entry.provider)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                AvatarView(image: profile.avatar, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(profile.displayName).font(.headline)
                        Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(entry.prompt).textSelection(.enabled)
                }
            }
            Button {
                app.go(.provider(entry.provider))
            } label: {
                HStack(spacing: 6) {
                    ProviderIcon(provider: provider, size: 16)
                    Text("Routed to **\(provider.name)** · \(entry.reason)")
                    Text("by \(entry.routedBy)").foregroundStyle(.tertiary)
                    Image(systemName: "arrow.up.right")
                }
                .font(.caption)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.secondary.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.leading, 40)
        }
    }
}
