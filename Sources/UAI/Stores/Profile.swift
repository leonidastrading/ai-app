import AppKit
import SwiftUI

/// Your local profile in UAI — a name and picture shown as "You" in Universal
/// AI. It lives only on this Mac; there's no account to sign up for. You can
/// type it in, or pull your first name and photo from the Google account
/// you're signed into in Gemini.
@MainActor
final class Profile: ObservableObject {
    @Published var name: String {
        didSet { UserDefaults.standard.set(name, forKey: "profile.name") }
    }
    @Published var avatar: NSImage?

    private static let avatarURL = Paths.appSupport.appendingPathComponent("avatar.png")

    init() {
        name = UserDefaults.standard.string(forKey: "profile.name") ?? ""
        avatar = NSImage(contentsOf: Self.avatarURL)
    }

    var displayName: String { name.isEmpty ? "You" : name }

    func setAvatar(_ image: NSImage?) {
        avatar = image
        if let tiff = image?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            try? png.write(to: Self.avatarURL)
        } else {
            try? FileManager.default.removeItem(at: Self.avatarURL)
        }
    }

    // MARK: - Cloud sync
    func setName(_ newName: String) { name = newName }

    /// The avatar as a PNG data URL (for syncing), matching the Windows/web shape.
    func avatarDataURL() -> String? {
        guard let tiff = avatar?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }

    /// Set the avatar from a data: URL (from a cloud pull); nil/empty clears it.
    func setAvatar(fromDataURL dataURL: String?) {
        guard let dataURL, let comma = dataURL.range(of: ","),
              let data = Data(base64Encoded: String(dataURL[comma.upperBound...])),
              let image = NSImage(data: data) else { setAvatar(nil); return }
        setAvatar(image)
    }

    func chooseAvatarFromDisk() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) {
            setAvatar(image)
        }
    }

    /// Pulls your name and photo from the Google account signed into Gemini.
    func importFromGoogle(using webViews: WebViewStore) async -> String? {
        guard let identity = await webViews.googleIdentity() else {
            return "Open Gemini and sign in with Google first, then try again."
        }
        if !identity.name.isEmpty {
            // Keep it to a first name, like the Google greeting.
            name = identity.name.split(separator: " ").first.map(String.init) ?? identity.name
        }
        if let urlString = identity.imageURL, let url = URL(string: urlString),
           let (data, _) = try? await URLSession.shared.data(from: url), let image = NSImage(data: data) {
            setAvatar(image)
        }
        return name.isEmpty && avatar == nil ? "Couldn't read your Google profile. Make sure Gemini is open and signed in." : nil
    }
}

/// A round avatar: your photo, or a person placeholder.
struct AvatarView: View {
    let image: NSImage?
    var size: CGFloat = 30

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Theme.card
                    Image(systemName: "person.fill").foregroundStyle(.secondary)
                        .font(.system(size: size * 0.5))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}
