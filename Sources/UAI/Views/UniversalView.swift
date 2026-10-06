import SwiftUI
import UniformTypeIdentifiers

/// Universal AI: type once, and UAI sends the prompt to whichever AI suits
/// the task best, as a new chat in that AI under your own account.
struct UniversalView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var universal: UniversalStore
    @EnvironmentObject private var webViews: WebViewStore
    @EnvironmentObject private var memory: MemoryStore
    @EnvironmentObject private var profile: Profile
    @EnvironmentObject private var auth: AuthStore
    @AppStorage(SettingsKey.autoSend) private var autoSend = true
    @AppStorage(SettingsKey.shareMemory) private var shareMemory = true

    @State private var draft = ""
    @State private var override: ProviderID?
    @State private var sending = false
    @State private var attachments: [Attachment] = []
    @FocusState private var composerFocused: Bool

    private var z: CGFloat { CGFloat(app.uiZoom) }
    private var enabled: [ProviderID] { Provider.all.filter(\.isEnabled).map(\.id) }
    private var hasImageAttachment: Bool { attachments.contains(where: \.isImage) }
    private var canSend: Bool {
        !sending && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }
    private var preview: RouteDecision? {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return nil }
        if let override { return RouteDecision(provider: override, reason: "Chosen by you", routedBy: "You") }
        return Router.rules(text, among: enabled, imageAttached: hasImageAttachment)
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
        .onAppear { focusSoon(); takePendingPrompt() }
        // Coming back to Universal AI from an AI should re-focus the box.
        .onChange(of: app.destination) { if app.destination == .universal { focusSoon() } }
        .onChange(of: app.pendingPrompt) { takePendingPrompt() }
    }

    private func focusSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { composerFocused = true }
    }

    private func takePendingPrompt() {
        guard let p = app.pendingPrompt else { return }
        draft = p
        app.pendingPrompt = nil
        focusSoon()
    }

    private var hero: some View {
        VStack(spacing: 12) {
            GalaxyIcon(size: 72 * z)
            Text("Universal AI").font(.system(size: 30 * z, weight: .bold))
            Text("Ask anything. UAI picks the best AI and starts the chat there.")
                .font(.system(size: 17 * z)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var composer: some View {
        VStack(spacing: 10) {
            VStack(spacing: 10) {
                if !attachments.isEmpty { attachmentStrip }
                HStack(alignment: .top, spacing: 10) {
                    Button(action: pickFiles) {
                        Image(systemName: "paperclip")
                            .font(.system(size: 18 * z, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 32 * z, height: 32 * z)
                    }
                    .buttonStyle(.plain)
                    .help("Attach an image or file to send along with your prompt")
                    TextField("Message Universal AI, or attach an image and say what to do…",
                              text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 20 * z))
                        .autocorrectionDisabled(true)
                        .lineLimit(1...8)
                        .focused($composerFocused)
                        .onSubmit(send)
                        .onChange(of: draft) { absorbFilePaths() }
                        .padding(.vertical, 4)
                    Button(action: send) {
                        Image(systemName: sending ? "hourglass" : "arrow.up")
                            .font(.system(size: 18 * z, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 40 * z, height: 40 * z)
                            .background(canSend ? Theme.pink : Color.gray.opacity(0.4), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.pink.opacity(composerFocused ? 0.6 : 0.2), lineWidth: 1.5))
            .onDrop(of: [.fileURL, .image], isTargeted: nil, perform: handleDrop)

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
                Button { sendToUAI() } label: { Label("Send to UAI", systemImage: "sparkles") }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.aqua)
                    .help("Save this to your Recent on every device, without routing to an AI")
                    .disabled(!canSend)
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

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { att in
                    HStack(spacing: 6) {
                        if let thumb = att.thumbnail {
                            Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                                .frame(width: 28, height: 28).clipShape(RoundedRectangle(cornerRadius: 6))
                        } else {
                            Image(systemName: "doc.fill").foregroundStyle(.secondary).frame(width: 28, height: 28)
                        }
                        Text(att.name).font(.caption).lineLimit(1).frame(maxWidth: 140)
                        Button {
                            attachments.removeAll { $0.id == att.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls { addAttachment(from: url) }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            handled = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { addAttachment(from: url) }
            }
        }
        return handled
    }

    private func addAttachment(from url: URL) {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
        guard let att = Attachment.load(from: url) else {
            app.show(toast: "Couldn't attach \(url.lastPathComponent) (too large or unreadable).")
            return
        }
        if attachments.count >= 6 {
            app.show(toast: "You can attach up to 6 files at a time.")
            return
        }
        // Don't double-add the same file (a drag can arrive via two paths).
        guard !attachments.contains(where: { $0.name == att.name && $0.dataURL == att.dataURL }) else { return }
        attachments.append(att)
    }

    /// Dragging a file onto a macOS text box drops its PATH as text rather than
    /// the file itself. Catch that: any line of the draft that is a real file on
    /// disk becomes a proper attachment, so Claude gets the image — not the path.
    private func absorbFilePaths() {
        guard draft.contains("/") else { return }
        var remaining: [String] = []
        var absorbed = false
        for line in draft.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let path = trimmed.hasPrefix("file://") ? (URL(string: trimmed)?.path ?? trimmed) : trimmed
            if !path.isEmpty, FileManager.default.fileExists(atPath: path) {
                addAttachment(from: URL(fileURLWithPath: path))
                absorbed = true
            } else {
                remaining.append(line)
            }
        }
        if absorbed {
            let rest = remaining.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if rest != draft { draft = rest }
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
                HStack {
                    Text("RECENT").font(.caption.bold()).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") { universal.clear() }
                        .buttonStyle(.borderless).font(.caption)
                }
                ForEach(universal.history.prefix(8)) { entry in
                    RoutedMessage(entry: entry)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 10)
        }
    }

    /// Save the prompt + attachments to Recent (synced), without routing to an AI.
    private func sendToUAI() {
        absorbFilePaths()
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = attachments
        guard (!text.isEmpty || !files.isEmpty), !sending else { return }
        sending = true
        draft = ""; attachments = []
        Task {
            var atts: [RecentAttachment] = []
            for f in files {
                var ra = RecentAttachment(name: f.name, type: f.mime, dataURL: Self.thumb(f), url: nil)
                if let comma = f.dataURL.firstIndex(of: ","),
                   let data = Data(base64Encoded: String(f.dataURL[f.dataURL.index(after: comma)...])) {
                    ra.url = await auth.uploadAttachment(data: data, name: f.name, mime: f.mime)
                }
                atts.append(ra)
            }
            let logged = text.isEmpty ? "(attachment)" : text
            universal.add(RoutedPrompt(date: Date(), prompt: logged, provider: ProviderID(rawValue: ""),
                                       reason: "", routedBy: "UAI", attachments: atts.isEmpty ? nil : atts))
            sending = false
            app.show(toast: "Sent to UAI — saved to your Recent on every device")
        }
    }

    /// A small JPEG data-URL thumbnail for an image attachment (nil otherwise).
    private static func thumb(_ a: Attachment) -> String? {
        guard a.isImage, let img = a.thumbnail else { return nil }
        let maxDim: CGFloat = 320
        let s = img.size
        let scale = min(1, maxDim / max(s.width, s.height))
        let w = max(1, s.width * scale), h = max(1, s.height * scale)
        let out = NSImage(size: NSSize(width: w, height: h))
        out.lockFocus()
        img.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        out.unlockFocus()
        guard let tiff = out.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff),
              let jpeg = bmp.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else { return nil }
        return "data:image/jpeg;base64," + jpeg.base64EncodedString()
    }

    private func send() {
        absorbFilePaths()   // in case a just-dropped path hasn't been converted yet
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = attachments
        guard (!prompt.isEmpty || !files.isEmpty), !sending else { return }
        sending = true
        let chosen = override
        let imageAttached = files.contains(where: \.isImage)
        Task {
            let decision: RouteDecision
            if let chosen {
                decision = RouteDecision(provider: chosen, reason: "Chosen by you", routedBy: "You")
            } else {
                decision = await Router.route(prompt, among: enabled, imageAttached: imageAttached)
            }
            let logged = prompt.isEmpty && !files.isEmpty
                ? "\(files.count) attachment\(files.count == 1 ? "" : "s")"
                : prompt
            universal.add(RoutedPrompt(date: Date(), prompt: logged, provider: decision.provider,
                                       reason: decision.reason, routedBy: decision.routedBy))
            draft = ""
            override = nil
            attachments = []
            sending = false
            app.go(.provider(decision.provider))

            let name = Provider.get(decision.provider).name
            let message = prompt.isEmpty ? "" : memory.prompt(prompt, for: decision.provider)
            switch await webViews.deliver(message, to: decision.provider, autoSend: autoSend, attachments: files) {
            case .sent: app.show(toast: "Sent to \(name) · \(decision.reason)")
            case .inserted:
                app.show(toast: files.isEmpty
                    ? "Prompt is ready in \(name). Press Return to send."
                    : "Your \(files.count == 1 ? "file" : "files") and prompt are ready in \(name). Review, then press Return to send.")
            case .failed:
                if !message.isEmpty {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message, forType: .string)
                }
                app.show(toast: "Couldn't find \(name)'s message box (signed in?)."
                    + (message.isEmpty ? "" : " Prompt copied; paste with ⌘V."))
            }
        }
    }
}

private struct RoutedMessage: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var profile: Profile
    let entry: RoutedPrompt

    var body: some View {
        let isUAI = entry.provider.rawValue.isEmpty
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
                    if let atts = entry.attachments, !atts.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(Array(atts.prefix(5).enumerated()), id: \.offset) { _, a in
                                Button { Self.open(a) } label: {
                                    if let s = a.dataURL, let data = Self.decode(s), let img = NSImage(data: data) {
                                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                                            .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 6))
                                    } else {
                                        HStack(spacing: 4) { Image(systemName: "paperclip"); Text(a.name).lineLimit(1) }
                                            .font(.caption2).foregroundStyle(.secondary)
                                            .padding(.horizontal, 6).padding(.vertical, 4)
                                            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                                    }
                                }
                                .buttonStyle(.plain)
                                .help("Open \(a.name)")
                            }
                        }
                        .padding(.top, 2)
                    }
                }
            }
            if isUAI {
                HStack(spacing: 6) {
                    GalaxyIcon(size: 16)
                    Text("Sent to **UAI**")
                }
                .font(.caption)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.secondary.opacity(0.12), in: Capsule())
                .padding(.leading, 40)
            } else {
                Button {
                    app.go(.provider(entry.provider))
                } label: {
                    HStack(spacing: 6) {
                        ProviderIcon(provider: provider, size: 16)
                        Text(entry.reason.isEmpty ? "Routed to **\(provider.name)**" : "Routed to **\(provider.name)** · \(entry.reason)")
                        if entry.routedBy != "UAI" && !entry.routedBy.isEmpty {
                            Text("by \(entry.routedBy)").foregroundStyle(.tertiary)
                        }
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

    private static func decode(_ s: String) -> Data? {
        guard let c = s.range(of: ",") else { return nil }
        return Data(base64Encoded: String(s[c.upperBound...]))
    }

    /// Open an attachment: the Storage URL in the browser (where it can be saved),
    /// or the inline thumbnail written to a temp file and opened in Preview.
    private static func open(_ a: RecentAttachment) {
        if let u = a.url, let url = URL(string: u) { NSWorkspace.shared.open(url); return }
        if let s = a.dataURL, let data = decode(s) {
            let nameNS = a.name as NSString
            let ext = nameNS.pathExtension.isEmpty ? "png" : nameNS.pathExtension
            let stem = nameNS.deletingPathExtension.isEmpty ? "attachment" : nameNS.deletingPathExtension
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(stem).\(ext)")
            try? data.write(to: tmp)
            NSWorkspace.shared.open(tmp)
        }
    }
}
