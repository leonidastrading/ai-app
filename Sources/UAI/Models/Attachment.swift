import AppKit
import UniformTypeIdentifiers

/// An image or file you attach to a Universal AI prompt. UAI forwards it to the
/// chosen AI by dropping it into that AI's own composer, so the upload happens
/// under your account exactly as if you'd dragged the file in yourself.
struct Attachment: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let mime: String
    /// "data:<mime>;base64,…" — the bytes, ready to rebuild a File() in the page.
    let dataURL: String

    var isImage: Bool { mime.hasPrefix("image/") }

    /// A small preview image for the composer chip (nil for non-images).
    var thumbnail: NSImage? {
        guard isImage, let comma = dataURL.firstIndex(of: ","),
              let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) else { return nil }
        return NSImage(data: data)
    }

    /// Reads a file off disk into an Attachment. Skips anything too large to
    /// paste into a web composer (most AIs cap uploads around 20–30 MB).
    static func load(from url: URL) -> Attachment? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty, data.count <= 25_000_000 else { return nil }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let dataURL = "data:\(mime);base64," + data.base64EncodedString()
        return Attachment(name: url.lastPathComponent, mime: mime, dataURL: dataURL)
    }
}
