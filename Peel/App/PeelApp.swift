import SwiftUI

@main
struct PeelApp: App {
    @StateObject private var store = Store()
    @StateObject private var stickers = StickerStore()
    @StateObject private var account = AccountManager()
    @StateObject private var quota = DailyQuota()

    /// True when the process was launched by XCTest as a unit-test host. In that case we must NOT boot the
    /// full SwiftUI scene: the test bundle is a logic-only suite (`@testable import Peel`) and launching the
    /// real UI floods the runner with view-update churn and hangs it before it can connect. An empty host
    /// scene lets the runner attach instantly and execute the pure-logic tests.
    private static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    init() {
        #if DEBUG
        SelfTest.runIfRequested()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            if Self.isRunningUnitTests {
                // Minimal host for the unit-test bundle — no app UI, so the test runner connects immediately.
                Color.clear
            } else {
                // No full-screen loading gate: the stores hydrate synchronously in their initializers, so the
                // first committed frame is the real studio (the library tiles carry their own skeletons while
                // their PNGs load). Fewer loading screens, per the product direction.
                appScene
            }
        }
    }

    private var appScene: some View {
            // The FIRST sticker needs no account — the app opens straight into the studio. Sign-in is now
            // an opt-in (from Settings, or prompted only to save/sync); credits + unlimited stay device-
            // local for a guest and reconcile to the Apple id on sign-in.
            RootView()
                .environmentObject(store)
                .environmentObject(stickers)
                .environmentObject(account)
                .environmentObject(quota)
                // No forced color scheme — Light Mode, Dark Mode, Increase Contrast, Reduce Transparency
                // and Dynamic Type all work now.
                .tint(Brand.accent)
                .onAppear {
                    account.refreshCredentialState()
                    if account.isSignedIn { store.setUser(account.userID) }
                }
                .onChange(of: account.userID) { _, id in
                    if !id.isEmpty { store.setUser(id) }
                }
                .onOpenURL { url in RemixLink.handle(url) }
    }
}
