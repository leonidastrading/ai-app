import Foundation
import UniformTypeIdentifiers

/// Every file the AIs generate and you download (images, videos, reports…)
/// is saved under ~/Documents/UAI Media/<Provider>/ and listed here.
struct MediaItem: Identifiable, Hashable {
    enum Kind: String, CaseIterable, Identifiable {
        case image = "Images", video = "Videos", document = "Documents", other = "Other"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .image: "photo"
            case .video: "film"
            case .document: "doc.text"
            case .other: "doc"
            }
        }
    }

    var id: URL { url }
    let url: URL
    let provider: ProviderID?
    let kind: Kind
    let created: Date
    let size: Int64

    var name: String { url.lastPathComponent }
}

@MainActor
final class MediaLibrary: ObservableObject {
    @Published private(set) var items: [MediaItem] = []

    init() { reload() }

    func reload() {
        let fm = FileManager.default
        let root = Paths.media
        let keys: [URLResourceKey] = [.creationDateKey, .fileSizeKey, .isRegularFileKey, .contentTypeKey]
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
        var found: [MediaItem] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            let folder = url.deletingLastPathComponent().lastPathComponent
            let provider = Provider.all.first { $0.name == folder }?.id
            found.append(MediaItem(
                url: url,
                provider: provider,
                kind: Self.kind(of: values.contentType ?? UTType(filenameExtension: url.pathExtension)),
                created: values.creationDate ?? .distantPast,
                size: Int64(values.fileSize ?? 0)))
        }
        items = found.sorted { $0.created > $1.created }
    }

    func search(_ query: String) -> [MediaItem] {
        let q = query.lowercased()
        return items.filter { $0.name.lowercased().contains(q) }
    }

    static func kind(of type: UTType?) -> MediaItem.Kind {
        guard let type else { return .other }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .pdf) || type.conforms(to: .text) || type.conforms(to: .presentation)
            || type.conforms(to: .spreadsheet) || type.conforms(to: .rtf)
            || type.identifier.contains("word") || type.identifier.contains("document") {
            return .document
        }
        return .other
    }
}
