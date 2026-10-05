import SwiftUI

/// Full-window Google sign-in gate shown until the user signs in. Signing in
/// unlocks the app and syncs UAI data under the account.
struct SignInGate: View {
    @EnvironmentObject private var auth: AuthStore

    var body: some View {
        ZStack {
            Theme.windowBackground.ignoresSafeArea()
            RadialGradient(colors: [Theme.violet.opacity(0.22), .clear],
                           center: .top, startRadius: 0, endRadius: 600)
                .ignoresSafeArea()
            VStack(spacing: 16) {
                GalaxyIcon(size: 104)
                Text("UAI").font(.system(size: 34, weight: .semibold))
                Text("Sign in with Google to sync your AIs, memory and settings across the Mac, Windows and web apps.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)

                Button(action: { Task { await auth.signIn() } }) {
                    HStack(spacing: 8) {
                        if auth.busy { ProgressView().controlSize(.small) }
                        Text(auth.busy ? "Opening browser…" : "Sign in with Google")
                            .fontWeight(.semibold)
                    }
                    .padding(.horizontal, 22).padding(.vertical, 12)
                    .background(
                        LinearGradient(colors: [Theme.pink, Theme.violet],
                                       startPoint: .leading, endPoint: .trailing),
                        in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(auth.busy)

                Text("A browser window opens to finish sign-in, then come back here.")
                    .font(.caption).foregroundStyle(.tertiary)

                if let err = auth.lastError {
                    Text(err).font(.caption).foregroundStyle(.red)
                        .multilineTextAlignment(.center).frame(maxWidth: 360)
                }
            }
            .padding(40)
        }
    }
}
