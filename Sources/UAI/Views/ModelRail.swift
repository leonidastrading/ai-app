import SwiftUI

/// The far-left column of AI icons, like Slack's workspace switcher.
struct ModelRail: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        VStack(spacing: 10) {
            RailButton(name: "Universal AI — routes to the best AI (⌘1)",
                       isSelected: app.destination == .universal) {
                app.go(.universal)
            } icon: {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Theme.universalGradient)
                    .overlay(Image(systemName: "sparkles").font(.system(size: 18, weight: .bold)).foregroundStyle(.white))
            }

            Rectangle().fill(.white.opacity(0.15)).frame(width: 28, height: 1)

            ForEach(Array(Provider.all.enumerated()), id: \.element.id) { offset, provider in
                RailProviderSlot(provider: provider, shortcut: offset + 2)
            }

            Spacer()

            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")
            .padding(.bottom, 12)
        }
        .padding(.top, 12)
        .frame(width: 70)
        .frame(maxHeight: .infinity)
        .background(Theme.rail)
    }
}

private struct RailProviderSlot: View {
    @EnvironmentObject private var app: AppState
    let provider: Provider
    let shortcut: Int
    @AppStorage private var enabled: Bool

    init(provider: Provider, shortcut: Int) {
        self.provider = provider
        self.shortcut = shortcut
        _enabled = AppStorage(wrappedValue: true, SettingsKey.enabled(provider.id))
    }

    var body: some View {
        if enabled {
            RailButton(name: "\(provider.name) by \(provider.maker) (⌘\(shortcut))",
                       isSelected: app.destination == .provider(provider.id)) {
                app.go(.provider(provider.id))
            } icon: {
                ProviderIcon(provider: provider, size: 40)
            }
        }
    }
}

private struct RailButton<Icon: View>: View {
    let name: String
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let icon: () -> Icon
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            icon()
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(3)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Theme.selectionRing.opacity(isSelected ? 1 : (hovering ? 0.35 : 0)), lineWidth: 2)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(name)
    }
}

/// The provider's favicon on a white tile, or a colored letter tile while it loads.
struct ProviderIcon: View {
    let provider: Provider
    var size: CGFloat = 40

    var body: some View {
        AsyncImage(url: provider.iconURL) { phase in
            if let image = phase.image {
                ZStack {
                    Color.white
                    image.resizable().interpolation(.high).scaledToFit().padding(size * 0.16)
                }
            } else {
                letterTile
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.25))
    }

    private var letterTile: some View {
        ZStack {
            provider.tint
            Text(String(provider.name.prefix(1)))
                .font(.system(size: size * 0.45, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
    }
}
