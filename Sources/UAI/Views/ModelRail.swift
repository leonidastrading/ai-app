import SwiftUI

/// The far-left column of AI icons, like Slack's workspace switcher.
struct ModelRail: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject private var registry = ProviderRegistry.shared

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

                    ForEach(Array(registry.all.enumerated()), id: \.element.id) { offset, provider in
                        RailProviderSlot(provider: provider, shortcut: offset + 2)
                    }

                    RailButton(name: "Add AI", help: "Add another AI by its web address",
                               isSelected: false) {
                        app.showAddAI = true
                    } icon: {
                        Circle()
                            .fill(.white.opacity(0.14))
                            .overlay(Circle().strokeBorder(.white.opacity(0.7),
                                                           style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                            .overlay(Image(systemName: "plus").font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(.white))
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
    @EnvironmentObject private var webViews: WebViewStore
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
            RailButton(name: provider.name, help: helpText,
                       isSelected: app.destination == .provider(provider.id),
                       badge: badge) {
                app.go(.provider(provider.id))
            } icon: {
                ProviderIcon(provider: provider, size: ModelRail.iconSize)
            }
            .contextMenu {
                Button("New Chat") {
                    app.go(.provider(provider.id))
                    webViews.goHome(provider.id)
                }
                Button("Reload") { webViews.reload(provider.id) }
                Divider()
                if provider.isCustom {
                    Button("Remove \(provider.name)", role: .destructive) {
                        app.forget(provider.id)
                        webViews.close(provider.id)
                        ProviderRegistry.shared.remove(provider.id)
                    }
                } else {
                    Button("Hide \(provider.name)") {
                        app.forget(provider.id)
                        enabled = false
                    }
                }
            }
        }
    }

    private var helpText: String {
        var text = "\(provider.name) by \(provider.maker)"
        if shortcut <= 9 { text += " (⌘\(shortcut))" }
        if webViews.needsSignIn.contains(provider.id) { text += ". Sign in needed" }
        return text
    }

    private var badge: RailBadge? {
        if let count = app.unread[provider.id], count > 0 { return .count(count) }
        if webViews.needsSignIn.contains(provider.id) { return .signIn }
        return nil
    }
}

enum RailBadge: Equatable {
    case count(Int)
    case signIn
}

private struct RailButton<Icon: View>: View {
    let name: String
    let help: String
    let isSelected: Bool
    var badge: RailBadge? = nil
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
                    .overlay(alignment: .topTrailing) { badgeView }
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

    @ViewBuilder
    private var badgeView: some View {
        switch badge {
        case .count(let n):
            Text(n > 9 ? "9+" : "\(n)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .frame(minWidth: 18, minHeight: 18)
                .background(Capsule().fill(Theme.pink))
                .overlay(Capsule().stroke(.white, lineWidth: 1.5))
        case .signIn:
            Image(systemName: "key.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Theme.indigo)
                .frame(width: 17, height: 17)
                .background(Circle().fill(.white))
                .overlay(Circle().stroke(Theme.indigo, lineWidth: 1))
        case nil:
            EmptyView()
        }
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
