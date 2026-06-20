import SwiftUI
import AuthenticationServices

/// OPTIONAL Sign in with Apple. No longer a hard gate — the first sticker needs no account. This screen
/// is now presented only when the user chooses to sign in (from Settings, or when prompted to save/sync),
/// so their unlimited unlock, credits and stickers follow them across devices via CloudKit. No photos or
/// any other data ever leave the device — only the paid flag + credit balance reconcile on sign-in.
struct SignInGateView: View {
    @EnvironmentObject var account: AccountManager
    @Environment(\.dismiss) private var dismiss

    private let points: [(String, String)] = [
        ("infinity", "Your unlimited unlock & credits follow you to every device"),
        ("lock.fill", "100% on-device. Your photos never leave your phone"),
        ("square.on.square", "Use your stickers in every app")
    ]

    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 0) {
                Spacer(minLength: Spacing.md)

                VStack(spacing: Spacing.lg) {
                    Image(systemName: "scissors")
                        .font(.system(size: 50, weight: .semibold))
                        .foregroundStyle(Brand.accent)
                        .frame(width: 104, height: 104)
                        .background(Color(.secondarySystemBackground),
                                    in: RoundedRectangle(cornerRadius: Radius.hero, style: .continuous))
                    VStack(spacing: Spacing.sm) {
                        Text("Sync your Peel")
                            .font(AppFont.largeTitle)
                        Text("Keep your unlock, credits and stickers with you across devices.")
                            .font(AppFont.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }

                Spacer(minLength: Spacing.xl)

                VStack(alignment: .leading, spacing: Spacing.lg) {
                    ForEach(points, id: \.1) { p in
                        HStack(spacing: Spacing.lg) {
                            Image(systemName: p.0)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Brand.accent)
                                .frame(width: 26)
                            Text(p.1)
                                .font(AppFont.footnote)
                                .foregroundStyle(.primary)
                            Spacer()
                        }
                    }
                }
                .padding(.bottom, Spacing.xxl)

                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.fullName]
                } onCompletion: { result in
                    account.handle(result)
                    if account.isSignedIn { dismiss() }
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 52)
                .clipShape(Capsule())

                if let err = account.lastError {
                    Text(err)
                        .font(AppFont.caption).foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.top, Spacing.md)
                }

                Button("Not now") { dismiss() }
                    .font(AppFont.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, Spacing.md)

                Text("Cutouts run entirely on-device — nothing is uploaded. Only your paid flag and credit balance sync.")
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, Spacing.md)

                Spacer(minLength: Spacing.xs)
            }
            .padding(.horizontal, Spacing.xxl)
            .padding(.vertical, Spacing.xxl)
        }
    }

    @Environment(\.colorScheme) private var colorScheme
}
