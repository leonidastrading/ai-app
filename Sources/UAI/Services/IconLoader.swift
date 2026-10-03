import AppKit
import SwiftUI

/// Loads AI favicons and works out each one's background color, so a logo
/// that sits on a solid tile (Claude's orange, xAI's and X's black) fills
/// its whole circle in that color instead of floating on white.
@MainActor
final class IconLoader: ObservableObject {
    static let shared = IconLoader()

    struct Icon {
        let image: NSImage
        /// The logo's own tile color, or nil if the logo has a transparent background.
        let fill: Color?
    }

    @Published private(set) var icons: [URL: Icon] = [:]
    private var inFlight: Set<URL> = []

    func icon(for url: URL) -> Icon? {
        if let icon = icons[url] { return icon }
        load(url)
        return nil
    }

    private func load(_ url: URL) {
        guard !inFlight.contains(url) else { return }
        inFlight.insert(url)
        Task {
            defer { inFlight.remove(url) }
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let original = NSImage(data: data) else { return }
            let image = Self.trimmed(original)
            icons[url] = Icon(image: image, fill: Self.tileColor(of: image))
        }
    }

    /// Crops away transparent or white margins around the logo.
    static func trimmed(_ image: NSImage) -> NSImage {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        let bitmap = NSBitmapImageRep(cgImage: cg)
        let w = bitmap.pixelsWide, h = bitmap.pixelsHigh
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let blank = c.alphaComponent < 0.1
                    || (c.redComponent > 0.94 && c.greenComponent > 0.94 && c.blueComponent > 0.94)
                if !blank {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX, maxY >= minY,
              maxX - minX < w - 2 || maxY - minY < h - 2,   // nothing to trim
              let cropped = cg.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
        else { return image }
        return NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
    }

    /// Samples points along the edges of the logo. If they are opaque and
    /// roughly the same color, the logo is drawn on a tile of that color.
    static func tileColor(of image: NSImage) -> Color? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: cg)
        let w = bitmap.pixelsWide, h = bitmap.pixelsHigh
        guard w > 4, h > 4 else { return nil }
        let inset = max(1, w / 16)
        let points = [(w / 2, inset), (w / 2, h - 1 - inset), (inset, h / 2), (w - 1 - inset, h / 2)]
        let colors = points.compactMap { bitmap.colorAt(x: $0.0, y: $0.1)?.usingColorSpace(.sRGB) }
        guard colors.count == points.count, colors.allSatisfy({ $0.alphaComponent > 0.9 }) else { return nil }
        let first = colors[0]
        let similar = colors.allSatisfy {
            abs($0.redComponent - first.redComponent) + abs($0.greenComponent - first.greenComponent)
                + abs($0.blueComponent - first.blueComponent) < 0.25
        }
        guard similar else { return nil }
        // A white tile looks the same as the default badge.
        if first.redComponent > 0.95 && first.greenComponent > 0.95 && first.blueComponent > 0.95 { return nil }
        return Color(nsColor: first)
    }
}
