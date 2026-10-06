import Foundation
import Combine
import AppKit

/// Keeps this account's UAI data (custom AIs, memory, recents, profile, rail
/// order, hidden AIs) in sync with Firestore through AuthStore, using the single
/// JSON blob the Windows and web apps share.
@MainActor
final class CloudSync: ObservableObject {
    let auth: AuthStore

    private let registry = ProviderRegistry.shared
    private let memory: MemoryStore
    private let universal: UniversalStore
    private let profile: Profile

    private var cancellables = Set<AnyCancellable>()
    private var suppressUntil = Date.distantPast   // ignore pushes right after applying a pull
    private var started = false
    private var pollTimer: Timer?

    init(auth: AuthStore, memory: MemoryStore, universal: UniversalStore, profile: Profile) {
        self.auth = auth
        self.memory = memory
        self.universal = universal
        self.profile = profile
    }

    /// Pull the account's cloud blob into local state, then start watching for changes.
    func startAfterSignIn() async {
        applyBlob(await auth.pull())
        applyRecents(await auth.pullRecents())
        if !started { watchForChanges(); startPolling(); started = true }
        // Seed the profile name/photo from Google on first sign-in if we have nothing.
        if profile.name.isEmpty, let acct = auth.account, !acct.name.isEmpty {
            profile.setName(acct.name.split(separator: " ").first.map(String.init) ?? acct.name)
            if profile.avatar == nil, let url = URL(string: acct.photo),
               let (data, _) = try? await URLSession.shared.data(from: url),
               let image = NSImage(data: data) {
                profile.setAvatar(image)
            }
        }
        // Make sure the cloud has our current state (first run / merge).
        schedulePush()
        pushRecentsMerged()
    }

    /// Manually pull and apply the latest cloud data (e.g. the Reload button).
    func refresh() async {
        guard auth.isSignedIn else { return }
        applyBlob(await auth.pull())
        applyRecents(await auth.pullRecents())
    }

    func signOut() {
        pollTimer?.invalidate(); pollTimer = nil
        auth.signOut()
    }

    // MARK: - change watching

    private func watchForChanges() {
        Publishers.MergeMany([
            registry.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            memory.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            universal.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            profile.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
        ])
        .debounce(for: .seconds(1.2), scheduler: RunLoop.main)
        .sink { [weak self] in self?.schedulePush(); self?.pushRecentsMerged() }
        .store(in: &cancellables)
    }

    /// Poll the cloud so changes from other devices appear without a restart.
    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.auth.isSignedIn else { return }
                self.applyBlob(await self.auth.pull())
                self.applyRecents(await self.auth.pullRecents())
            }
        }
    }

    private func schedulePush() {
        guard auth.isSignedIn, Date() > suppressUntil else { return }
        Task { await auth.push(buildBlob()) }   // data blob only — never recents
    }

    /// Push recents into their own field, merged with the current remote so a
    /// concurrent write from another device is never lost.
    private func pushRecentsMerged() {
        guard auth.isSignedIn else { return }
        Task {
            let local = universal.history.prefix(60).map { Self.recentDict($0) }
            let remote = await auth.pullRecents()
            await auth.pushRecents(Self.mergeRawRecents(local + remote))
        }
    }

    private static func recentDict(_ r: RoutedPrompt) -> [String: Any] {
        var d: [String: Any] = ["text": r.prompt, "providerId": r.provider.rawValue,
                                "at": Int(r.date.timeIntervalSince1970 * 1000),
                                "reason": r.reason, "routedBy": r.routedBy]
        if let atts = r.attachments, !atts.isEmpty {
            d["attachments"] = atts.map { a -> [String: Any] in
                var ad: [String: Any] = ["name": a.name]
                if let t = a.type { ad["type"] = t }
                if let u = a.dataURL { ad["dataURL"] = u }
                if let u = a.url { ad["url"] = u }
                return ad
            }
        }
        return d
    }

    /// Apply a remote recents array into the Universal history (merged with local).
    private func applyRecents(_ remote: [[String: Any]]) {
        guard !remote.isEmpty || !universal.history.isEmpty else { return }
        suppressUntil = Date().addingTimeInterval(3)
        let incoming = remote.compactMap { Self.routedPrompt(from: $0) }
        var seen = Set<String>(); var merged: [RoutedPrompt] = []
        for r in incoming + universal.history {
            let key = Self.recentKey(providerId: r.provider.rawValue, at: Int(r.date.timeIntervalSince1970 * 1000), text: r.prompt)
            if seen.contains(key) { continue }
            seen.insert(key); merged.append(r)
        }
        merged.sort { $0.date > $1.date }
        universal.replaceAll(Array(merged.prefix(200)))
    }

    private static func routedPrompt(from item: [String: Any]) -> RoutedPrompt? {
        guard let text = item["text"] as? String else { return nil }
        let pid = item["providerId"] as? String ?? ""
        let ms = (item["at"] as? Double) ?? Double(item["at"] as? Int ?? 0)
        let date = ms > 0 ? Date(timeIntervalSince1970: ms / 1000) : Date()
        let atts = (item["attachments"] as? [[String: Any]])?.compactMap { a -> RecentAttachment? in
            guard let name = a["name"] as? String else { return nil }
            return RecentAttachment(name: name, type: a["type"] as? String, dataURL: a["dataURL"] as? String, url: a["url"] as? String)
        }
        return RoutedPrompt(date: date, prompt: text, provider: ProviderID(rawValue: pid),
                            reason: item["reason"] as? String ?? "",
                            routedBy: item["routedBy"] as? String ?? "UAI", attachments: atts)
    }

    private static func recentKey(providerId: String, at: Any?, text: String) -> String {
        let ms = (at as? Int) ?? Int((at as? Double) ?? 0)
        return providerId + "|" + String(ms) + "|" + String(text.prefix(60))
    }
    /// Merge raw recent dictionaries: dedupe by content, newest-first, bounded.
    private static func mergeRawRecents(_ list: [[String: Any]]) -> [[String: Any]] {
        var seen = Set<String>(); var out: [[String: Any]] = []
        for r in list {
            let key = recentKey(providerId: r["providerId"] as? String ?? "", at: r["at"], text: r["text"] as? String ?? "")
            if seen.contains(key) { continue }
            seen.insert(key); out.append(r)
        }
        out.sort { (($0["at"] as? Int) ?? Int(($0["at"] as? Double) ?? 0)) > (($1["at"] as? Int) ?? Int(($1["at"] as? Double) ?? 0)) }
        return Array(out.prefix(80))
    }

    // MARK: - blob <-> local state

    private func enabledKey(_ id: String) -> String { "provider.\(id).enabled" }
    private func isHidden(_ id: String) -> Bool {
        UserDefaults.standard.object(forKey: enabledKey(id)) as? Bool == false
    }

    private func buildBlob() -> [String: Any] {
        var blob: [String: Any] = [:]
        blob["custom"] = registry.custom.map {
            ["id": $0.id, "name": $0.name, "url": $0.url, "strengths": $0.strengths]
        }
        blob["memory"] = memory.allTexts
        // recents are synced in their own field (see pushRecentsMerged), not here.
        blob["railOrder"] = registry.order
        blob["hidden"] = registry.all.map(\.id.rawValue).filter { isHidden($0) }
        var profileDict: [String: Any] = ["name": profile.name]
        if let avatar = profile.avatarDataURL() { profileDict["avatar"] = avatar }
        blob["profile"] = profileDict
        return blob
    }

    private func applyBlob(_ blob: [String: Any]) {
        guard !blob.isEmpty else { return }
        suppressUntil = Date().addingTimeInterval(3)

        if let custom = blob["custom"] as? [[String: Any]] {
            let list = custom.compactMap { item -> CustomProvider? in
                guard let id = item["id"] as? String, let name = item["name"] as? String,
                      let url = item["url"] as? String else { return nil }
                return CustomProvider(id: id, name: name, url: url, strengths: item["strengths"] as? String ?? "")
            }
            registry.replaceCustom(list)
        }

        if let memoryTexts = blob["memory"] as? [String] {
            memory.replaceAllTexts(memoryTexts)
        }

        // recents are applied by applyRecents from their own field, not here.

        if let order = blob["railOrder"] as? [String] {
            registry.setOrder(order)
        }

        if let hidden = blob["hidden"] as? [String] {
            let hiddenSet = Set(hidden)
            for id in registry.all.map(\.id.rawValue) {
                UserDefaults.standard.set(!hiddenSet.contains(id), forKey: enabledKey(id))
            }
        }

        if let profileDict = blob["profile"] as? [String: Any] {
            if let name = profileDict["name"] as? String { profile.setName(name) }
            profile.setAvatar(fromDataURL: profileDict["avatar"] as? String)
        }
    }
}
