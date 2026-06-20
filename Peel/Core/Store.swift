import StoreKit
import Combine

/// StoreKit 2 manager for Peel's three honest SKUs (no subscription):
///   • CONSUMABLE credits — `peel_credits_50` ($2.99/50), `peel_credits_200` ($7.99/200). Pay-to-create-
///     more. Consumables do NOT appear in `currentEntitlements`, so they are granted on a dedicated
///     `Transaction.updates` path and accumulated into an App-Group balance that never expires.
///   • NONCONSUMABLE ceiling — `peel_unlimited` ($9.99): unlimited creates forever + 2048px export. The
///     legacy `peel_pro_unlock` ($0.99) owner is GRANDFATHERED into unlimited free.
///   • NONCONSUMABLE Style Packs — `peel_pack_*` ($1.99 each): cosmetic template bundles.
///
/// Source of truth for the unlimited ceiling: the signed StoreKit `currentEntitlements` (reflects a
/// purchase on any of the user's devices, readable offline). On a confirmed unlimited purchase we WRITE
/// the user's CloudKit paid record so the owner can see who's paying (best-effort, never gates).
@MainActor
final class Store: ObservableObject {
    // Legacy + ceiling
    static let legacyProID = "peel_pro_unlock"
    static let unlimitedID = "peel_unlimited"
    /// Back-compat alias for call sites that referenced the old single product id.
    static let productID = unlimitedID

    // Consumable credits
    static let credits50ID = "peel_credits_50"
    static let credits200ID = "peel_credits_200"
    static let creditGrant: [String: Int] = [credits50ID: 50, credits200ID: 200]

    // Cosmetic Style Packs
    static let stylePackIDs = ["peel_pack_neon", "peel_pack_comic", "peel_pack_y2k"]

    /// Peel sells a SINGLE one-time Pro unlock. Only the unlimited ceiling (and its grandfathered legacy
    /// id) are offered for sale and loaded from StoreKit; credits and Style Packs are retired SKUs kept
    /// in code only for back-compat decoding of any already-owned entitlement.
    static var allProductIDs: [String] {
        [unlimitedID, legacyProID]
    }

    @Published private(set) var products: [String: Product] = [:]
    @Published private(set) var isPro: Bool = AppGroup.isPro              // has the unlimited ceiling
    @Published private(set) var credits: Int = AppGroup.creditBalance     // remaining consumable credits
    @Published private(set) var ownedPacks: Set<String> = AppGroup.ownedStylePacks
    @Published var purchaseInFlight = false

    /// Product-catalog load lifecycle, so the paywall can show skeletons while loading, a clear retry on a
    /// load failure, and never silently leave the buy buttons inert. `.failed` carries the reason.
    enum LoadState: Equatable { case idle, loading, loaded, failed(String) }
    @Published private(set) var loadState: LoadState = .idle

    /// The last user-facing purchase/restore error, surfaced as an alert by the paywall. Set whenever a
    /// purchase fails, a product is missing, or the catalog couldn't load — NEVER a silent no-op.
    @Published var lastError: String?

    /// True the moment products have been requested at least once and none came back — used to show the
    /// "store unavailable" retry affordance instead of a dead, dimmed button.
    var catalogUnavailable: Bool {
        if case .failed = loadState { return true }
        return loadState == .loaded && products.isEmpty
    }

    /// Convenience for the legacy single-product UI (the $9.99 unlimited tier).
    var product: Product? { products[Self.unlimitedID] }

    /// The product id the paywall should SELL for the one-time Pro unlock. Prefers the unlimited ceiling,
    /// but falls back to the grandfathered legacy unlock — whichever StoreKit actually returned — so the
    /// buy button always targets a product that loaded (both grant the same unlimited entitlement).
    var proSaleID: String {
        if products[Self.unlimitedID] != nil { return Self.unlimitedID }
        if products[Self.legacyProID] != nil { return Self.legacyProID }
        return Self.unlimitedID
    }
    /// The loaded Product backing `proSaleID`, or nil while the catalog is still loading.
    var proProduct: Product? { products[proSaleID] }

    /// The signed-in Apple user id, used to key the CloudKit paid record. Set by the app on launch and
    /// whenever sign-in changes. Empty for a guest (state stays device-local until sign-in).
    private var userID: String = ""

    private var updates: Task<Void, Never>?

    init() {
        // Listen for transactions that arrive outside an explicit purchase (restore, Ask-to-Buy, and —
        // crucially — every consumable credit purchase, which only surfaces here).
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                await self?.handle(verification: result)
            }
        }
        Task {
            await loadProducts()
            await refreshEntitlements()
        }
    }

    deinit { updates?.cancel() }

    /// Called by the app once the user is signed in (and on launch if already signed in). Re-checks
    /// entitlements against both StoreKit and the user's CloudKit record.
    func setUser(_ id: String) {
        guard id != userID else { return }
        userID = id
        Task { await refreshEntitlements() }
    }

    /// Fetch the ENTIRE catalog (unlimited, legacy, both credit packs, all three Style Packs). Publishes a
    /// load lifecycle so the UI can show skeletons, then either the priced buttons or a clear retry — and
    /// flags any product ids App Store Connect didn't return so a missing SKU is visible, not silent.
    func loadProducts() async {
        loadState = .loading
        do {
            let loaded = try await Product.products(for: Self.allProductIDs)
            products = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
            if products.isEmpty {
                loadState = .failed("Couldn’t reach the App Store. Check your connection and try again.")
            } else {
                let missing = Self.allProductIDs.filter { products[$0] == nil }
                if !missing.isEmpty {
                    // Some products aren't configured/approved yet — load what we got, but make it visible.
                    lastError = "Some items aren’t available right now (\(missing.count) missing). The rest are ready."
                }
                loadState = .loaded
            }
        } catch {
            products = [:]
            loadState = .failed(error.localizedDescription)
        }
    }

    /// Re-attempt the catalog load (and re-check entitlements). Wired to the paywall's retry button.
    func reload() async {
        await loadProducts()
        await refreshEntitlements()
    }

    func product(_ id: String) -> Product? { products[id] }
    func displayPrice(_ id: String) -> String { products[id]?.displayPrice ?? "" }

    /// The unlimited tier's price (legacy single-price UI).
    var displayPrice: String { products[Self.unlimitedID]?.displayPrice ?? "$9.99" }

    /// StoreKit `currentEntitlements` is the SIGNED source of truth for NON-consumables (unlimited +
    /// style packs). It reflects purchases on any of the user's devices and is readable offline. We
    /// grant from it ONLY (a world-writable CloudKit flag could be forged, and an offline lookup must
    /// never revoke a real purchase). Consumable CREDITS are NOT here — they accumulate via `handle`.
    func refreshEntitlements() async {
        var unlimited = false
        var grantedTxn: Transaction?
        var packs: Set<String> = []
        for await result in Transaction.currentEntitlements {
            guard case .verified(let txn) = result, txn.revocationDate == nil else { continue }
            switch txn.productID {
            case Self.unlimitedID, Self.legacyProID:   // legacy owners grandfathered into unlimited
                unlimited = true
                grantedTxn = txn
            case let pid where Self.stylePackIDs.contains(pid):
                packs.insert(pid)
            default:
                break
            }
        }
        setPro(unlimited)
        setOwnedPacks(packs)
        if unlimited, !userID.isEmpty {
            let uid = userID, txn = grantedTxn?.id
            Task.detached { await CloudKitPro.shared.setPro(userID: uid, transactionID: txn) }
        }
    }

    /// Purchase any product by id. Credits/packs/unlimited all route through `handle`. Every non-success
    /// outcome sets `lastError` so the paywall can SHOW it — the buttons are never a silent no-op. A user
    /// cancel is intentionally NOT an error (no alert), but a missing product, a pending/ask-to-buy hold, a
    /// failed verification, or a thrown StoreKit error all surface a message.
    @discardableResult
    func purchase(_ id: String) async -> Bool {
        guard let product = products[id] else {
            // The product never loaded — tell the user instead of doing nothing.
            lastError = "That item isn’t available yet. Pull to retry, or check back shortly."
            return false
        }
        guard !purchaseInFlight else { return false }
        purchaseInFlight = true
        defer { purchaseInFlight = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let granted = await handle(verification: verification)
                if !granted {
                    // Verified path that didn't grant (e.g. unverified signature) — don't fail silently.
                    lastError = "We couldn’t verify that purchase. If you were charged, tap Restore."
                }
                return granted
            case .userCancelled:
                return false   // user backed out on purpose — no alert
            case .pending:
                lastError = "Your purchase is pending approval (Ask to Buy). It’ll unlock once approved."
                return false
            @unknown default:
                lastError = "Something went wrong with that purchase. Please try again."
                return false
            }
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Back-compat: purchase the unlimited ceiling.
    @discardableResult
    func purchase() async -> Bool { await purchase(Self.unlimitedID) }

    func restore() async {
        guard !purchaseInFlight else { return }
        purchaseInFlight = true
        defer { purchaseInFlight = false }
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            if !isPro && ownedPacks.isEmpty {
                lastError = "No purchases found to restore on this Apple ID."
            }
        } catch {
            lastError = "Couldn’t restore purchases: \(error.localizedDescription)"
        }
    }

    /// Spend one credit toward a creation beyond the free daily limit. Returns false if none remain.
    @discardableResult
    func spendCredit() -> Bool {
        guard credits > 0 else { return false }
        setCredits(credits - 1)
        return true
    }

    /// Decode result -> grant. Consumables (credits) accumulate the balance and are FINISHED so they
    /// don't replay; non-consumables flip the unlimited flag / add a pack. Never grants on `.unverified`.
    @discardableResult
    private func handle(verification: VerificationResult<Transaction>) async -> Bool {
        guard case .verified(let transaction) = verification else { return false }
        var didGrant = false

        switch transaction.productID {
        case Self.unlimitedID, Self.legacyProID:
            let granted = transaction.revocationDate == nil
            setPro(granted)
            didGrant = granted
            if granted, !userID.isEmpty {
                let uid = userID, txn = transaction.id
                Task.detached { await CloudKitPro.shared.setPro(userID: uid, transactionID: txn) }
            }

        case let pid where Self.creditGrant[pid] != nil:
            // Only grant a consumable the first time we see THIS transaction id. Finishing it below
            // means a finished credit purchase never re-enters `Transaction.updates` to double-grant.
            if transaction.revocationDate == nil, !hasGrantedCredit(transaction.id) {
                setCredits(credits + (Self.creditGrant[pid] ?? 0))
                markCreditGranted(transaction.id)
                didGrant = true
            }

        case let pid where Self.stylePackIDs.contains(pid):
            if transaction.revocationDate == nil {
                setOwnedPacks(ownedPacks.union([pid]))
                didGrant = true
            }

        default:
            break
        }

        await transaction.finish()
        return didGrant
    }

    // MARK: - Persisted mirrors

    private func setPro(_ value: Bool) {
        if isPro != value { isPro = value }
        AppGroup.isPro = value // shared with the iMessage extension + keyboard
    }
    private func setCredits(_ value: Int) {
        let v = max(0, value)
        if credits != v { credits = v }
        AppGroup.creditBalance = v
    }
    private func setOwnedPacks(_ value: Set<String>) {
        if ownedPacks != value { ownedPacks = value }
        AppGroup.ownedStylePacks = value
    }

    // MARK: - Consumable double-grant guard

    /// Ids of consumable credit transactions already applied to the balance (so a replay through
    /// `Transaction.updates` after `finish()` can never grant twice within an install).
    private static let grantedCreditsKey = "grantedCreditTxns"
    private func hasGrantedCredit(_ id: UInt64) -> Bool {
        let seen = AppGroup.defaults?.array(forKey: Self.grantedCreditsKey) as? [String] ?? []
        return seen.contains(String(id))
    }
    private func markCreditGranted(_ id: UInt64) {
        var seen = AppGroup.defaults?.array(forKey: Self.grantedCreditsKey) as? [String] ?? []
        guard !seen.contains(String(id)) else { return }
        seen.append(String(id))
        if seen.count > 200 { seen.removeFirst(seen.count - 200) }   // bound the ledger
        AppGroup.defaults?.set(seen, forKey: Self.grantedCreditsKey)
    }
}
