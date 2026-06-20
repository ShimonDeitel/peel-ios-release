import SwiftUI
import AuthenticationServices

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var account: AccountManager
    @EnvironmentObject var stickers: StickerStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var showPaywall = false
    @State private var showDeleteConfirm = false

    private let privacyURL = URL(string: "https://shimondeitel.github.io/peel-site/privacy.html")!

    var body: some View {
        NavigationStack {
            List {
                if store.isPro {
                    Section {
                        Label("Unlimited unlocked", systemImage: "infinity")
                            .foregroundStyle(Brand.accent)
                    }
                } else {
                    Section {
                        Button { showPaywall = true } label: {
                            HStack {
                                Image(systemName: "sparkles").foregroundStyle(Brand.accent)
                                VStack(alignment: .leading) {
                                    Text("Get more stickers").font(.headline)
                                    Text(store.credits > 0
                                         ? "\(store.credits) credits · buy more, unlimited, or Style Packs"
                                         : "Credit packs, unlimited once, or $1.99 Style Packs")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if store.credits > 0 { CreditChip(count: store.credits) }
                            }
                        }
                    }
                }

                Section {
                    if account.isSignedIn {
                        HStack {
                            Image(systemName: "person.crop.circle.fill.badge.checkmark").foregroundStyle(Brand.accent)
                            VStack(alignment: .leading) {
                                Text(account.displayName.isEmpty ? "Signed in with Apple" : account.displayName).font(.headline)
                                Text("Your unlock and stickers follow you across devices").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Button("Sign out", role: .destructive) { account.signOut() }
                        Button("Delete Account", role: .destructive) { showDeleteConfirm = true }
                    } else {
                        SignInWithAppleButton(.signIn) { request in
                            request.requestedScopes = [.fullName]
                        } onCompletion: { result in
                            account.handle(result)
                        }
                        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                        .frame(height: 46)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        Text("Sign in to carry your Pro unlock and stickers across your devices.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Account")
                }

                Section("How to use your stickers") {
                    instruction(1, "Open Messages and tap the apps row next to the text field.")
                    instruction(2, "Tap the Peel icon to open your sticker keyboard.")
                    instruction(3, "Tap a sticker to drop it into the chat, or peel-and-drag it onto a message.")
                }

                Section {
                    Button("Restore purchase") { Task { await store.restore() } }
                    Link("Privacy Policy", destination: privacyURL)
                }

                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(appVersion).foregroundStyle(.secondary)
                    }
                    Text("Peel processes your photos entirely on your device. Nothing is uploaded.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showPaywall) { PaywallView().environmentObject(store) }
            .alert("Delete Account?", isPresented: $showDeleteConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) { deleteAccount() }
            } message: {
                Text("This permanently deletes your Peel account data (your synced purchase record) and removes the stickers on this device. This can't be undone.")
            }
        }
    }

    private func deleteAccount() {
        let uid = account.userID
        stickers.deleteAll()
        Task { await CloudKitPro.shared.deleteAccount(userID: uid) }
        account.signOut()   // clears local identity -> returns to the Sign in gate
        Haptics.success()
        dismiss()
    }

    private func instruction(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)")
                .font(.caption.bold())
                .frame(width: 22, height: 22)
                .background(Brand.accent, in: Circle())
                .foregroundStyle(.white)
            Text(text)
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return v
    }
}
