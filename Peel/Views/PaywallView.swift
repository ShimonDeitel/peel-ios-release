import SwiftUI

/// The honest, three-SKU store (no subscription). Credits are the primary lever; $9.99 unlimited is the
/// ceiling; $1.99 Style Packs are the cosmetic catalog. The whole editor is FREE — this sheet only sells
/// MORE creates and cosmetic looks. The Pro treatment is a quiet tinted chip; there is no blue-on-blue
/// glow, gold ring, or crown anywhere.
///
/// LOADING + ERRORS: while the StoreKit catalog loads, every price slot shows a SKELETON (no spinner). If
/// the catalog fails to load, a clear "Store unavailable / Try again" banner appears instead of dead,
/// dimmed buttons. Every failed purchase or restore surfaces an ALERT — the buy buttons are never a silent
/// no-op.
struct PaywallView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.xl) {
                    header
                    if store.catalogUnavailable {
                        storeUnavailable
                    } else if store.isPro {
                        unlimitedOwnedBanner
                    } else {
                        unlimitedTier
                    }
                    fairnessCopy
                    restoreButton
                }
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.lg)
            }
            .background(AppBackground())
            .navigationTitle("Unlock Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                }
                ToolbarItem(placement: .topBarLeading) {
                    if !store.isPro, store.credits > 0 { CreditChip(count: store.credits) }
                }
            }
        }
        .onChange(of: store.isPro) { _, isPro in if isPro { Haptics.success() } }
        // Surface every purchase / restore / load failure — never a silent no-op.
        .alert("Store", isPresented: errorPresented) {
            Button("OK", role: .cancel) { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
        .task {
            // If the initial app-launch load failed (or never ran), try again when the sheet opens.
            if store.catalogUnavailable || store.loadState == .idle {
                await store.reload()
            }
        }
    }

    /// Bridges the optional `store.lastError` to a Bool the `.alert` modifier can drive.
    private var errorPresented: Binding<Bool> {
        Binding(get: { store.lastError != nil },
                set: { if !$0 { store.lastError = nil } })
    }

    private var isLoading: Bool { store.loadState == .loading || store.loadState == .idle }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "sparkles")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(Brand.accent)
                .frame(width: 84, height: 84)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Radius.hero, style: .continuous))
            Text("The whole studio is free")
                .font(AppFont.title)
                .multilineTextAlignment(.center)
            Text("Every filter, outline, background, text, layer and Style Wall look is free, plus 3 new stickers a day. Unlock Pro once for unlimited stickers forever and 2048px export.")
                .font(AppFont.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, Spacing.xs)
    }

    private var unlimitedOwnedBanner: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "infinity")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Brand.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Unlimited unlocked").font(AppFont.headline)
                Text("Make as many as you want, every day — plus 2048px export.")
                    .font(AppFont.footnote).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .glassCard(cornerRadius: Radius.card)
    }

    // MARK: - Store unavailable (load failure → clear retry, not a dead button)

    private var storeUnavailable: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Brand.accent)
            Text("Store unavailable")
                .font(AppFont.headline)
            Text(loadFailureReason)
                .font(AppFont.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await store.reload() }
            } label: {
                Label("Try again", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
            }
            .buttonStyle(AppButtonStyle(role: .primary))
            .disabled(isLoading)
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }

    private var loadFailureReason: String {
        if case .failed(let reason) = store.loadState { return reason }
        return "Couldn’t load the store. Check your connection and try again."
    }

    // MARK: - Credit packs (primary lever)

    private var creditPacks: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionTitle("Sticker Credits", subtitle: "One credit = one new sticker beyond your free 3. Credits never expire.")
            HStack(spacing: Spacing.md) {
                creditCard(id: Store.credits50ID, count: 50, badge: nil)
                creditCard(id: Store.credits200ID, count: 200, badge: "Best value")
            }
        }
    }

    private func creditCard(id: String, count: Int, badge: String?) -> some View {
        Button {
            Haptics.tap()
            Task { _ = await store.purchase(id) }
        } label: {
            VStack(spacing: Spacing.sm) {
                if let badge {
                    Text(badge)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Brand.accent)
                } else {
                    Text(" ").font(.caption2)
                }
                Image(systemName: "sparkles")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Brand.accent)
                Text("\(count)").font(.title.bold())
                Text("credits").font(AppFont.footnote).foregroundStyle(.secondary)
                priceLabel(id)
                    .padding(.top, Spacing.xs)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.lg)
            .background(Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(badge != nil ? Brand.accent.opacity(0.4) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        // Tappable as soon as the product is loaded; while loading the skeleton price shows and the button
        // is inert by design. A missing product still surfaces an alert (handled in `purchase`).
        .disabled(store.purchaseInFlight || store.product(id) == nil)
        .opacity(store.product(id) == nil && !isLoading ? 0.5 : 1)
    }

    // MARK: - Unlimited ceiling

    private var unlimitedTier: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionTitle("Peel Pro", subtitle: "Make as many stickers as you want, forever — plus 2048px export.")
            Button {
                Haptics.tap()
                Task { let ok = await store.purchase(store.proSaleID); if ok { dismiss() } }
            } label: {
                HStack {
                    Image(systemName: "infinity").font(.headline)
                    Text("Unlock Peel Pro")
                    Spacer()
                    if store.purchaseInFlight || isLoading {
                        // Skeleton placeholder while the price loads or the purchase is in flight (no spinner).
                        SkeletonView(cornerRadius: 6).frame(width: 56, height: 16)
                    } else {
                        Text(store.displayPrice(store.proSaleID))
                    }
                }
            }
            .buttonStyle(AppButtonStyle(role: .primary))
            .disabled(store.purchaseInFlight || store.proProduct == nil)
            .opacity(store.proProduct == nil && !isLoading ? 0.55 : 1)
            Text("One-time purchase. No subscription, no recurring charges.")
                .font(AppFont.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Style packs (cosmetic catalog)

    private var stylePacks: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionTitle("Style Packs", subtitle: "Cosmetic look bundles for the Style Wall — $1.99 each, yours forever.")
            VStack(spacing: Spacing.md) {
                ForEach(StyleCatalog.packs) { pack in
                    packRow(pack)
                }
            }
        }
    }

    private func packRow(_ pack: StylePack) -> some View {
        let owned = store.ownedPacks.contains(pack.id)
        return HStack(spacing: Spacing.md) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Brand.accent)
                .frame(width: 40, height: 40)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(pack.title).font(AppFont.headline)
                Text(pack.subtitle).font(AppFont.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            if owned {
                Label("Owned", systemImage: "checkmark.circle.fill")
                    .font(AppFont.footnote)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(Brand.accent)
            } else if isLoading {
                SkeletonView(cornerRadius: Radius.control).frame(width: 64, height: 30)
            } else {
                Button {
                    Haptics.tap()
                    Task { _ = await store.purchase(pack.id) }
                } label: {
                    Text(store.displayPrice(pack.id).isEmpty ? "$1.99" : store.displayPrice(pack.id))
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, Spacing.sm)
                        .background(Color(.secondarySystemFill), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(store.purchaseInFlight || store.product(pack.id) == nil)
            }
        }
        .padding(Spacing.md)
        .background(Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }

    /// Price text, or a skeleton placeholder while the catalog is still loading.
    @ViewBuilder private func priceLabel(_ id: String) -> some View {
        if isLoading {
            SkeletonView(cornerRadius: 6).frame(width: 48, height: 16)
        } else {
            Text(store.displayPrice(id).isEmpty ? "—" : store.displayPrice(id))
                .font(AppFont.headline)
        }
    }

    // MARK: - Fairness + restore

    private var fairnessCopy: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            fairnessLine("Every editing tool — filters, outline, text, background, adjust, layers — is free.")
            fairnessLine("Every Style Wall look is free — nothing cosmetic is locked.")
            fairnessLine("A sticker you've already finished always saves and sends — never held hostage.")
            fairnessLine("One-time unlock. No subscription, no watermark, ever.")
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }

    private func fairnessLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: "checkmark.seal.fill")
                .font(.footnote)
                .foregroundStyle(Brand.accent)
            Text(text).font(AppFont.footnote).foregroundStyle(.secondary)
        }
    }

    private var restoreButton: some View {
        Button("Restore purchases") {
            Task { await store.restore() }
        }
        .font(AppFont.footnote)
        .foregroundStyle(Brand.accent)
        .disabled(store.purchaseInFlight)
        .padding(.top, Spacing.xs)
    }

    private func sectionTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(AppFont.headline)
            Text(subtitle).font(AppFont.footnote).foregroundStyle(.secondary)
        }
    }
}
