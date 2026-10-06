import Foundation

/// Local secret store for the optional Anthropic API key.
///
/// NOT the login Keychain: an ad-hoc-signed app's code signature changes every
/// build, so the Keychain pops a password prompt on every launch/read. These
/// values live in 0600 files in the app's own Application Support folder, which
/// is already protected by the user's account — no prompts.
enum Keychain {
    static let anthropicKey = "anthropic-api-key"

    private static var dir: URL {
        Paths.ensure(Paths.appSupport.appendingPathComponent("secrets", isDirectory: true))
    }
    private static func file(_ account: String) -> URL {
        dir.appendingPathComponent(account.replacingOccurrences(of: "/", with: "_"))
    }

    static func read(_ account: String) -> String? {
        guard let data = try? Data(contentsOf: file(account)),
              let s = String(data: data, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }

    static func write(_ value: String, for account: String) {
        if value.isEmpty { delete(account); return }
        let url = file(account)
        try? value.data(using: .utf8)?.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func delete(_ account: String) {
        try? FileManager.default.removeItem(at: file(account))
    }
}
