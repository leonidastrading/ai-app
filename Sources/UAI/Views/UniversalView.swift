import SwiftUI

/// Universal AI: type once, and UAI sends the prompt to whichever AI suits
/// the task best, as a new chat in that AI under your own account.
struct UniversalView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var universal: UniversalStore
    @EnvironmentObject private var webViews: WebViewStore
    @AppStorage(SettingsKey.autoSend) private var autoSend = true

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
            header
            Divider()
            history
            composer
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { composerFocused = true }
    }

    private var header: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6).fill(Theme.universalGradient)
                .overlay(Image(systemName: "sparkles").font(.system(size: 11, weight: .bold)).foregroundStyle(.white))
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text("Universal AI").font(.headline)
                Text("Ask anything. UAI picks the best AI and starts the chat there.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
    }

    private var history: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if universal.history.isEmpty {
                    emptyState
                }
                ForEach(universal.history.reversed()) { entry in
                    RoutedMessage(entry: entry)
                }
            }
            .padding(20)
        }
        .defaultScrollAnchor(.bottom)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Where prompts go").font(.title3.bold())
            ForEach(Provider.all) { provider in
                HStack(alignment: .top, spacing: 10) {
                    ProviderIcon(provider: provider, size: 22)
                    Text("**\(provider.name)**: \(provider.strengths)")
                        .foregroundStyle(.secondary)
                }
            }
            Text("First time? Open each AI from the left rail once and sign in with your account.")
                .font(.callout).foregroundStyle(.secondary).padding(.top, 6)
        }
        .frame(maxWidth: 640, alignment: .leading)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
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

                if let preview {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.right")
                        ProviderIcon(provider: Provider.get(preview.provider), size: 16)
                        Text("\(Provider.get(preview.provider).name) · \(preview.reason)")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Send automatically", isOn: $autoSend)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message Universal AI", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...10)
                    .focused($composerFocused)
                    .onSubmit(send)
                    .padding(.vertical, 6)
                Button(action: send) {
                    Image(systemName: sending ? "hourglass" : "paperplane.fill")
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 28)
                        .background(draft.isEmpty ? Color.gray.opacity(0.4) : Color(red: 0.0, green: 0.48, blue: 0.35),
                                    in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.35)))
        .padding(16)
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
            switch await webViews.deliver(prompt, to: decision.provider, autoSend: autoSend) {
            case .sent: app.show(toast: "Sent to \(name) · \(decision.reason)")
            case .inserted: app.show(toast: "Prompt is ready in \(name). Press Return to send.")
            case .failed:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(prompt, forType: .string)
                app.show(toast: "Couldn't find \(name)'s message box (signed in?). Prompt copied; paste with ⌘V.")
            }
        }
    }
}

private struct RoutedMessage: View {
    @EnvironmentObject private var app: AppState
    let entry: RoutedPrompt

    var body: some View {
        let provider = Provider.get(entry.provider)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "person.crop.square.fill")
                    .font(.system(size: 30)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("You").font(.headline)
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
