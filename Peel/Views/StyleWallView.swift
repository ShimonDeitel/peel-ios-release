import SwiftUI

/// THE HEADLINE FEATURE. After the on-device cutout, the screen fills with a live grid of ~24 finished
/// looks rendered on the user's OWN subject via `StickerRenderer.render(cutout:edit:)`. Tap a tile to
/// take that look straight into the editor (already a finished sticker); swipe the filmstrip, hit
/// "Surprise me" to shuffle, or favorite the ones you love. Locked premium tiles still render LIVE on the
/// user's subject with a quiet PRO chip — the preview sells the pack.
///
/// PERFORMANCE (the whole point of P4): ~24 Core Image composites at grid-load would stall first paint on
/// older devices, so every tile renders at a SMALL size (~160px) on a background actor, is CACHED by
/// (templateID × cutout identity), and arrives PROGRESSIVELY — the grid shows skeletons and fills in as
/// renders land, never blocking the main thread.
struct StyleWallView: View {
    let cutout: UIImage
    /// User picked a look — hand the applied `StickerEdit` to the editor (already finished).
    var onPick: (StyleTemplate) -> Void
    /// User wants the full editor without committing to a template (uses the plain cutout look).
    var onOpenEditor: () -> Void

    @EnvironmentObject private var store: Store
    @StateObject private var favorites = FavoritesStore()
    @StateObject private var renderer = StyleRenderCache()

    @State private var showFavoritesOnly = false

    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 12)]

    private var templates: [StyleTemplate] {
        let all = StyleCatalog.allTemplates
        return showFavoritesOnly ? all.filter { favorites.contains($0.id) } : all
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            filmstrip
            grid
        }
        .background(Color(.systemBackground))
        .task(id: cutout) { renderer.prime(cutout: cutout) }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Pick a look")
                    .font(.title2.bold())
                Text("Every style, on your subject")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showFavoritesOnly.toggle()
                Haptics.tap()
            } label: {
                Image(systemName: showFavoritesOnly ? "heart.fill" : "heart")
                    .font(.title3)
                    .foregroundStyle(showFavoritesOnly ? Brand.accent : Color.secondary)
            }
            .accessibilityLabel(showFavoritesOnly ? "Show all looks" : "Show favorites only")

            Button {
                surpriseMe()
            } label: {
                Image(systemName: "shuffle")
                    .font(.title3)
                    .foregroundStyle(Brand.accent)
            }
            .accessibilityLabel("Surprise me")
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    // MARK: - Filmstrip (quick horizontal swipe through the top looks)

    private var filmstrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(Array(StyleCatalog.starter.prefix(10))) { template in
                    Button { pick(template) } label: {
                        tile(for: template, side: 96, showTitle: false)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
    }

    // MARK: - Grid

    private var grid: some View {
        ScrollView {
            if templates.isEmpty {
                emptyFavorites
            } else {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(templates) { template in
                        Button { pick(template) } label: {
                            tile(for: template, side: 108, showTitle: true)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
            }

            Button {
                onOpenEditor()
            } label: {
                Label("Open in editor", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(GlassActionButtonStyle(tint: Color(.secondaryLabel)))
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
    }

    private var emptyFavorites: some View {
        VStack(spacing: 10) {
            Image(systemName: "heart")
                .font(.system(size: 38))
                .foregroundStyle(.tertiary)
            Text("No favorites yet")
                .font(.headline)
            Text("Tap the heart on a look to save it here.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - Tile

    @ViewBuilder
    private func tile(for template: StyleTemplate, side: CGFloat, showTitle: Bool) -> some View {
        let locked = template.isLocked(ownedPacks: store.ownedPacks)
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
                CheckerboardView(square: 10)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .opacity(0.6)

                if let image = renderer.image(for: template, cutout: cutout) {
                    // The finished styled render on the user's subject.
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(8)
                        .transition(.opacity)
                } else if renderer.isPriming {
                    // Still rendering this look — show the user's OWN cutout (real content, their photo)
                    // softly, with a skeleton behind it, so the tile never reads as an empty/broken box.
                    ZStack {
                        SkeletonView(cornerRadius: 16)
                            .padding(6)
                        Image(uiImage: cutout)
                            .resizable()
                            .scaledToFit()
                            .padding(10)
                            .opacity(0.35)
                    }
                    .transition(.opacity)
                } else {
                    // Priming finished but this tile has no render (should not happen — the cache always
                    // stores a result). Fall back to the plain cutout rather than a perpetual skeleton.
                    Image(uiImage: cutout)
                        .resizable()
                        .scaledToFit()
                        .padding(8)
                        .transition(.opacity)
                }

                // Favorite heart (top-left)
                VStack {
                    HStack {
                        Button {
                            favorites.toggle(template.id)
                            Haptics.tap()
                        } label: {
                            Image(systemName: favorites.contains(template.id) ? "heart.fill" : "heart")
                                .font(.caption)
                                .foregroundStyle(favorites.contains(template.id) ? Brand.accent : Color.white)
                                .padding(5)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }
                    Spacer()
                }
                .padding(6)

                // Quiet PRO chip for locked premium tiles (no glow, no gold — a tinted material chip).
                if locked {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            ProChip()
                        }
                    }
                    .padding(6)
                }
            }
            .frame(width: side, height: side)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
            .animation(.easeOut(duration: 0.2), value: renderer.image(for: template, cutout: cutout) != nil)

            if showTitle {
                Text(template.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Actions

    private func pick(_ template: StyleTemplate) {
        Haptics.pop()
        onPick(template)
    }

    private func surpriseMe() {
        Haptics.pop()
        // Prefer an unlocked, ideally favorited look so the shuffle always lands on something usable.
        let pool = StyleCatalog.allTemplates.filter { !$0.isLocked(ownedPacks: store.ownedPacks) }
        guard let choice = pool.randomElement() else { return }
        onPick(choice)
    }
}

// MARK: - Favorites (persisted in the App Group so the wall remembers across launches)

/// Stores the set of favorited template ids. Backed by the App Group defaults so it's shared and durable.
@MainActor
final class FavoritesStore: ObservableObject {
    @Published private(set) var ids: Set<String>

    private static let key = "styleWallFavorites"
    private var defaults: UserDefaults { AppGroup.defaults ?? .standard }

    init() {
        let stored = AppGroup.defaults?.stringArray(forKey: Self.key) ?? []
        ids = Set(stored)
    }

    func contains(_ id: String) -> Bool { ids.contains(id) }

    func toggle(_ id: String) {
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        defaults.set(Array(ids).sorted(), forKey: Self.key)
    }
}

// MARK: - Progressive, cached, off-main render cache

/// Renders every Style-Wall tile on the user's cutout at a SMALL size, OFF the main thread, CACHED, and
/// publishes each result as it lands so the grid fills PROGRESSIVELY. Keyed by (templateID × cutout
/// identity) so re-priming with the same cutout is instant and a new photo invalidates cleanly.
@MainActor
final class StyleRenderCache: ObservableObject {
    /// Rendered tile images keyed by `"<cutoutToken>|<templateID>"`.
    @Published private var images: [String: UIImage] = [:]
    /// True while a render pass is actively producing tiles. Tiles read this to decide whether a missing
    /// render means "still loading" (show skeleton) or "pass finished" (show plain-cutout fallback), so a
    /// tile NEVER shimmers forever once the pass is done.
    @Published private(set) var isPriming = false

    /// ~160px target keeps 24 composites cheap; tiles display smaller so it's crisp.
    private let targetSide: CGFloat = 160

    private var currentToken: ObjectIdentifier?
    private var inFlight = false
    /// A cutout whose render was requested while an older pass was still draining. The draining pass picks
    /// this up when it ends and restarts, so a fast photo swap can never strand the wall mid-load.
    private var pendingCutout: UIImage?

    /// Stable token for a cutout instance (UIImage is a class — identity is the natural cache key).
    private func token(_ cutout: UIImage) -> ObjectIdentifier { ObjectIdentifier(cutout) }
    private func key(_ template: StyleTemplate, _ cutout: UIImage) -> String {
        "\(token(cutout).hashValue)|\(template.id)"
    }

    /// Cached tile image, or nil while it's still rendering.
    func image(for template: StyleTemplate, cutout: UIImage) -> UIImage? {
        images[key(template, cutout)]
    }

    /// Kick off (or resume) rendering all tiles for this cutout. Idempotent: re-calling with the same
    /// cutout while a pass is in flight is a no-op; a new cutout invalidates and restarts.
    func prime(cutout: UIImage) {
        let tok = token(cutout)
        // Same cutout, pass already running or done — nothing to do.
        if currentToken == tok, (inFlight || !images.isEmpty) { return }
        if currentToken != tok {
            currentToken = tok
            // A new photo arrived while the previous pass is still draining: don't start a second pass on
            // top of it (that would race). Mark it pending and keep `isPriming` true; the draining pass
            // restarts on this cutout when it ends.
            if inFlight {
                pendingCutout = cutout
                isPriming = true
                return
            }
        }
        renderAll(cutout: cutout)
    }

    private func renderAll(cutout: UIImage) {
        guard !inFlight else { return }
        inFlight = true
        isPriming = true
        images.removeAll()
        // PRIORITIZE what's on screen: the filmstrip's 10 starters and the first grid rows render FIRST so
        // the wall fills top-down, then the rest (premium packs) trail in. De-dupes by id, preserving order.
        let ordered = prioritizedTemplates()
        let side = targetSide
        let tok = token(cutout)

        // Downscale the cutout ONCE so each composite works on small pixels (fast); identity preserved
        // for the cache key via the original `cutout`.
        Task.detached(priority: .userInitiated) { [weak self] in
            let small = cutout.cappedToLongestSide(side * 1.4)
            for template in ordered {
                // Bail if the user moved on to a different photo.
                if await self?.isCurrent(tok) != true { break }
                let edit = template.applied(to: small)
                let rendered = StickerRenderer.renderForExport(
                    edit: edit,
                    canvasLongSide: max(small.size.width, small.size.height) * 1.5,
                    original: small)
                let display = rendered.cappedToLongestSide(side)
                await self?.store(display, template: template, cutout: cutout, token: tok)
            }
            // ALWAYS finish — completed normally or bailed mid-pass — so `isPriming`/`inFlight` can never
            // wedge and leave tiles shimmering forever.
            await self?.finish(tok)
        }
    }

    /// Render order tuned to the on-screen layout: the filmstrip's first 10 starters, then the rest of the
    /// starter grid, then premium packs. De-duplicated, every template included exactly once.
    private func prioritizedTemplates() -> [StyleTemplate] {
        let filmstrip = Array(StyleCatalog.starter.prefix(10))
        var seen = Set<String>()
        var ordered: [StyleTemplate] = []
        for t in filmstrip + StyleCatalog.allTemplates where seen.insert(t.id).inserted {
            ordered.append(t)
        }
        return ordered
    }

    private func isCurrent(_ tok: ObjectIdentifier) -> Bool { currentToken == tok }

    private func store(_ image: UIImage, template: StyleTemplate, cutout: UIImage, token tok: ObjectIdentifier) {
        guard currentToken == tok else { return }
        images[key(template, cutout)] = image
    }

    private func finish(_ tok: ObjectIdentifier) {
        inFlight = false
        // A newer photo was requested mid-pass — start its render now that the old one has drained.
        if let pending = pendingCutout {
            pendingCutout = nil
            // `currentToken` already points at the pending cutout (set in `prime`), so render it directly.
            renderAll(cutout: pending)
            return
        }
        // Only the CURRENT pass clears `isPriming`; a stale (superseded) pass must not flip a fresh
        // pass's flag off.
        if currentToken == tok { isPriming = false }
    }
}
