import SwiftUI

/// The far-left column of AI icons, like Slack's workspace switcher.
struct ModelRail: View {
    @EnvironmentObject private var app: AppState

    static let iconSize: CGFloat = 48  // 20% larger than the original 40pt tiles

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    RailButton(name: "Universal", help: "Universal AI: routes to the best AI (⌘1)",
                               isSelected: app.destination == .universal) {
                        app.go(.universal)
                    } icon: {
                        GalaxyIcon(size: Self.iconSize)
                    }

                    Rectangle().fill(.white.opacity(0.3)).frame(width: 36, height: 1)

                    ForEach(Array(Provider.all.enumerated()), id: \.element.id) { offset, provider in
                        RailProviderSlot(provider: provider, shortcut: offset + 2)
                    }
                }
                .padding(.top, 12)
                .padding(.bottom, 8)
            }

            SettingsLink {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")
            .padding(.bottom, 12)
        }
        .frame(width: 84)
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
            RailButton(name: provider.name, help: "\(provider.name) by \(provider.maker) (⌘\(shortcut))",
                       isSelected: app.destination == .provider(provider.id)) {
                app.go(.provider(provider.id))
            } icon: {
                ProviderIcon(provider: provider, size: ModelRail.iconSize)
            }
        }
    }
}

private struct RailButton<Icon: View>: View {
    let name: String
    let help: String
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let icon: () -> Icon
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                icon()
                    .frame(width: ModelRail.iconSize, height: ModelRail.iconSize)
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                    .padding(3)
                    .overlay(
                        Circle().stroke(Theme.selectionRing.opacity(isSelected ? 1 : (hovering ? 0.45 : 0)),
                                        lineWidth: 2.5)
                    )
                Text(name)
                    .font(.system(size: 10, weight: isSelected ? .bold : .medium))
                    .foregroundStyle(.white.opacity(isSelected ? 1 : 0.85))
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
            }
            .frame(width: 76)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// The provider's favicon on a round white badge, or a colored letter badge while it loads.
struct ProviderIcon: View {
    let provider: Provider
    var size: CGFloat = 40

    var body: some View {
        AsyncImage(url: provider.iconURL) { phase in
            if let image = phase.image {
                ZStack {
                    Color.white
                    image.resizable().interpolation(.high).scaledToFit().padding(size * 0.2)
                }
            } else {
                letterBadge
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var letterBadge: some View {
        ZStack {
            provider.tint
            Text(String(provider.name.prefix(1)))
                .font(.system(size: size * 0.45, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
    }
}
