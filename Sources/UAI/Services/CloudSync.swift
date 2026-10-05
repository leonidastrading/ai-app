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
    private let recents: GlobalRecents
    private let profile: Profile

    private var cancellables = Set<AnyCancellable>()
    private var suppressUntil = Date.distantPast   // ignore pushes right after applying a pull
    private var started = false

    init(auth: AuthStore, memory: MemoryStore, recents: GlobalRecents, profile: Profile) {
        self.auth = auth
        self.memory = memory
        self.recents = recents
        self.profile = profile
    }

    /// Pull the account's cloud blob into local state, then start watching for changes.
    func startAfterSignIn() async {
        let blob = await auth.pull()
        applyBlob(blob)
        if !started { watchForChanges(); started = true }
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
    }

    func signOut() {
        auth.signOut()
    }

    // MARK: - change watching

    private func watchForChanges() {
        Publishers.MergeMany([
            registry.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            memory.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            recents.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            profile.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
        ])
        .debounce(for: .seconds(1.2), scheduler: RunLoop.main)
        .sink { [weak self] in self?.schedulePush() }
        .store(in: &cancellables)
    }

    private func schedulePush() {
        guard auth.isSignedIn, Date() > suppressUntil else { return }
        let blob = buildBlob()
        Task { await auth.push(blob) }
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
        blob["recents"] = recents.items.prefix(60).map {
            ["text": $0.text, "providerId": $0.provider.rawValue, "at": Int($0.date.timeIntervalSince1970 * 1000)]
        }
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

        if let recentsArr = blob["recents"] as? [[String: Any]] {
            let items = recentsArr.compactMap { item -> RecentPrompt? in
                guard let text = item["text"] as? String, let pid = item["providerId"] as? String else { return nil }
                let ms = (item["at"] as? Double) ?? Double(item["at"] as? Int ?? 0)
                let date = ms > 0 ? Date(timeIntervalSince1970: ms / 1000) : Date()
                return RecentPrompt(provider: ProviderID(rawValue: pid), text: text, date: date)
            }
            recents.replaceAll(items)
        }

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
