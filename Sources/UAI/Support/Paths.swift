import Foundation

enum Paths {
    /// ~/Library/Application Support/UAI
    static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ensure(base.appendingPathComponent("UAI", isDirectory: true))
    }

    /// ~/Documents/UAI Media — everything the AIs generate and you download lands here.
    static var media: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return ensure(base.appendingPathComponent("UAI Media", isDirectory: true))
    }

    /// Screenshots and other images you shared into a chat, kept apart from
    /// the AIs' own generated media.
    static var screenshots: URL {
        ensure(media.appendingPathComponent("Screenshots", isDirectory: true))
    }

    static func mediaFolder(for provider: ProviderID) -> URL {
        ensure(media.appendingPathComponent(Provider.get(provider).name, isDirectory: true))
    }

    @discardableResult
    static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Returns a URL in `directory` named `filename` that doesn't exist yet,
    /// adding " 2", " 3", … before the extension when needed.
    static func uniqueFile(named filename: String, in directory: URL) -> URL {
        let safe = filename.isEmpty ? "download" : filename.replacingOccurrences(of: "/", with: "-")
        var candidate = directory.appendingPathComponent(safe)
        let ext = candidate.pathExtension
        let stem = candidate.deletingPathExtension().lastPathComponent
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            candidate = directory.appendingPathComponent(name)
            n += 1
        }
        return candidate
    }
}

/// Small JSON persistence helper for app state files in Application Support.
enum JSONFile {
    static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        let url = Paths.appSupport.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, to name: String) {
        let url = Paths.appSupport.appendingPathComponent(name)
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
