import QuickLookThumbnailing
import SwiftUI

/// Every file your AIs generated: pictures, videos, reports…
struct MediaView: View {
    @EnvironmentObject private var media: MediaLibrary
    @State private var kind: MediaItem.Kind?
    @State private var provider: ProviderID?
    @State private var confirmClear = false

    private var filtered: [MediaItem] {
        media.items.filter { (kind == nil || $0.kind == kind) && (provider == nil || $0.provider == provider) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if filtered.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 16)], alignment: .leading, spacing: 16) {
                        ForEach(filtered) { MediaTile(item: $0) }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .clipped()
            }
        }
        .background(Theme.contentBackground)
        .onAppear { media.reload() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled").font(.title3)
            VStack(alignment: .leading, spacing: 0) {
                Text("Media").font(.headline)
                Text("\(media.items.count) files saved from your AIs").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Type", selection: $kind) {
                Text("All").tag(MediaItem.Kind?.none)
                ForEach(MediaItem.Kind.allCases) { Label($0.rawValue, systemImage: $0.symbol).tag(Optional($0)) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Picker("AI", selection: $provider) {
                Text("All AIs").tag(ProviderID?.none)
                ForEach(Provider.all) { Text($0.name).tag(Optional($0.id)) }
            }
            .labelsHidden()
            .fixedSize()
            Button { media.reload() } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh")
            Button { NSWorkspace.shared.open(Paths.media) } label: { Label("Open Folder", systemImage: "folder") }
            if !media.items.isEmpty {
                Button(role: .destructive) { confirmClear = true } label: { Label("Clear", systemImage: "trash") }
                    .confirmationDialog("Move all \(media.items.count) files in your UAI Media folder to the Trash?",
                                        isPresented: $confirmClear) {
                        Button("Move \(media.items.count) Files to Trash", role: .destructive) { media.clearAll() }
                    } message: {
                        Text("This only affects the UAI Media folder. Your chats and the AIs' own copies are untouched.")
                    }
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .frame(height: 48)
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.stack").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Nothing here yet").font(.title3.bold())
            Text("Images and videos your AIs generate are saved here automatically.\nAnything you download in UAI lands here too — in Documents › UAI Media.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MediaTile: View {
    @EnvironmentObject private var media: MediaLibrary
    let item: MediaItem
    @State private var thumbnail: NSImage?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Color.secondary.opacity(0.08)
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().scaledToFill()
                } else {
                    Image(systemName: item.kind.symbol).font(.system(size: 34)).foregroundStyle(.secondary)
                }
                if item.kind == .video {
                    Image(systemName: "play.circle.fill").font(.system(size: 36)).foregroundStyle(.white).shadow(radius: 4)
                }
            }
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor.opacity(hovering ? 0.8 : 0), lineWidth: 2))

            Text(item.name).font(.callout).lineLimit(1).truncationMode(.middle)
            HStack(spacing: 4) {
                if let id = item.provider {
                    ProviderIcon(provider: Provider.get(id), size: 12)
                    Text(Provider.get(id).name)
                }
                Text(item.created.formatted(date: .abbreviated, time: .omitted))
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(item.url) }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(item.url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([item.url as NSURL])
            }
            Divider()
            Button("Move to Trash", role: .destructive) {
                try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
                media.reload()
            }
        }
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .task(id: item.url) {
            let request = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: 380, height: 300),
                                                       scale: 2, representationTypes: .thumbnail)
            thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
        }
    }
}
