import SwiftUI
import PhotosUI

struct RootView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var stickers: StickerStore
    @EnvironmentObject var account: AccountManager
    @EnvironmentObject var quota: DailyQuota
    @ObservedObject private var remix = RemixLink.shared
    @Environment(\.scenePhase) private var scenePhase

    @State private var pickerItem: PhotosPickerItem?
    @State private var loadedImage: UIImage?
    @State private var pendingRemixID: String?
    @State private var showEditor = false
    @State private var showPaywall = false
    @State private var showSettings = false
    @State private var loadingPick = false
    @State private var selectedRecord: StickerRecord?

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: Spacing.lg)]

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                ScrollView {
                    VStack(spacing: Spacing.xl) {
                        hero
                        if stickers.records.isEmpty {
                            emptyState
                        } else {
                            libraryGrid
                        }
                    }
                    .padding(.horizontal, Spacing.lg)
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle("Peel")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .topBarLeading) {
                    // Quiet Pro / credits treatment — a tinted-material chip, never a gold ring or glow.
                    if store.isPro {
                        ProChip(text: "PRO", systemImage: "infinity")
                    } else if store.credits > 0 {
                        Button { showPaywall = true } label: { CreditChip(count: store.credits) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
        .onChange(of: pickerItem) { _, item in Task { await load(item) } }
        // A Remix deep link arrived: open the photo picker, then run the flow with that template's look.
        .onChange(of: remix.pendingTemplateID) { _, id in if id != nil { startRemix(id) } }
        .onAppear {
            // Re-sync the quota OFF the body (day may have rolled over while backgrounded). This is the
            // only place the published count is refreshed for the root — `body` itself reads pure values.
            quota.refresh()
            if remix.pendingTemplateID != nil { startRemix(remix.pendingTemplateID) }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { quota.refresh() } }
        .fullScreenCover(isPresented: $showEditor, onDismiss: { pendingRemixID = nil }) {
            if let img = loadedImage {
                MakeStickerFlow(original: img, remixTemplateID: pendingRemixID)
                    .environmentObject(store)
                    .environmentObject(stickers)
                    .environmentObject(quota)
            }
        }
        .photosPicker(isPresented: $remixPickerShown, selection: $pickerItem, matching: .images, photoLibrary: .shared())
        .sheet(isPresented: $showPaywall) { PaywallView().environmentObject(store) }
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(store).environmentObject(account).environmentObject(stickers) }
        .sheet(item: $selectedRecord) { record in
            StickerDetailView(record: record)
                .environmentObject(store).environmentObject(stickers).environmentObject(quota)
        }
        #if DEBUG
        .fullScreenCover(isPresented: $showDebugEditor) {
            if let cut = debugEditorCutout {
                NavigationStack { StickerEditorView(cutout: cut, original: cut) }
                    .environmentObject(store).environmentObject(stickers).environmentObject(quota)
            }
        }
        .onAppear(perform: handleDebugLaunch)
        #endif
    }

    @State private var remixPickerShown = false

    /// Begin a Remix: stash the template id, clear the pending link, and pop the photo picker so the user
    /// chooses a fresh photo. After pick, `load` routes into `MakeStickerFlow` with `pendingRemixID` set.
    private func startRemix(_ id: String?) {
        guard let id else { return }
        pendingRemixID = id
        remix.clear()
        remixPickerShown = true
    }

    #if DEBUG
    @State private var debugEditorCutout: UIImage?
    @State private var showDebugEditor = false
    private func handleDebugLaunch() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-PeelOpen"), i + 1 < args.count else { return }
        switch args[i + 1] {
        case "settings": showSettings = true
        case "paywall": showPaywall = true
        case "detail": selectedRecord = stickers.records.first
        case "editor":
            if let dir = AppGroup.stickersDirectory,
               let img = UIImage(contentsOfFile: dir.appendingPathComponent("s3.png").path) {
                debugEditorCutout = img
                showDebugEditor = true
            }
        default: break
        }
    }
    #endif

    // MARK: - Pieces

    private var hero: some View {
        VStack(spacing: Spacing.lg) {
            Text("Turn any photo into a sticker")
                .font(AppFont.title)
                .multilineTextAlignment(.center)
            Text("One tap. The subject pops out — right on your phone, instantly and private.")
                .font(AppFont.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "wand.and.stars")
                    Text(loadingPick ? "Opening…" : "Make a sticker")
                }
            }
            .buttonStyle(AppButtonStyle(role: .primary))
            .disabled(loadingPick)
            .padding(.top, Spacing.xs)

            if !store.isPro, let left = quota.remaining(isPro: store.isPro) {
                Text(quotaLine(freeLeft: left))
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .glassCard()
        .padding(.top, Spacing.xs)
    }

    private func quotaLine(freeLeft: Int) -> String {
        if freeLeft > 0 { return "\(freeLeft) free today" }
        if store.credits > 0 { return "\(store.credits) credits available" }
        return "Daily limit reached — get more in Settings"
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.md) {
            ZStack {
                CheckerboardView()
                    .frame(height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 46, weight: .regular))
                    .foregroundStyle(Brand.accent)
            }
            Text("Your stickers will live here")
                .font(AppFont.headline)
            Text("Make one, then find it in your iMessage keyboard and save it to Photos.")
                .font(AppFont.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .glassCard()
    }

    private var libraryGrid: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack {
                Text("My Stickers").font(AppFont.headline)
                Spacer()
                if !store.isPro, let left = quota.remaining(isPro: store.isPro) {
                    Text(left > 0 ? "\(left) free today" : "Daily limit reached")
                        .font(AppFont.caption).foregroundStyle(.secondary)
                }
            }
            LazyVGrid(columns: columns, spacing: Spacing.lg) {
                ForEach(stickers.records) { record in
                    Button {
                        Haptics.tap()
                        selectedRecord = record
                    } label: {
                        StickerThumb(record: record)
                            .environmentObject(stickers)
                    }
                }
            }
        }
    }

    // MARK: - Photo loading

    private func load(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        loadingPick = true
        defer { loadingPick = false; pickerItem = nil }
        if let data = try? await item.loadTransferable(type: Data.self),
           let image = UIImage(data: data) {
            loadedImage = image
            showEditor = true
        }
    }
}

/// A tiny in-memory cache of decoded library thumbnails, keyed by sticker file name. Lets a tile that's
/// already been loaded render IMMEDIATELY on re-appear (scrolling the grid, returning from a sheet) with
/// NO skeleton flash — the skeleton is only for the genuine first load from disk.
@MainActor
private enum ThumbCache {
    private static var store = NSCache<NSString, UIImage>()
    static func image(for file: String) -> UIImage? { store.object(forKey: file as NSString) }
    static func set(_ image: UIImage, for file: String) { store.setObject(image, forKey: file as NSString) }
}

/// A library tile that loads its sticker PNG OFF the main thread. If the thumbnail is already cached in
/// memory it renders INSTANTLY (no skeleton); otherwise a skeleton previews the shape while the PNG lands.
/// A load that fails resolves to a calm placeholder, never an endless shimmer.
struct StickerThumb: View {
    let record: StickerRecord

    /// Three concrete states so the view never gets stuck mid-load: `.loading` shows the skeleton,
    /// `.image` shows the sticker, `.failed` shows a calm placeholder. We seed from the in-memory cache
    /// so a re-appear skips `.loading` entirely.
    private enum Phase: Equatable {
        case loading, image(UIImage), failed
    }
    @State private var phase: Phase

    init(record: StickerRecord) {
        self.record = record
        // Seed synchronously from the cache so a previously-loaded thumb shows with no skeleton flash.
        if let cached = ThumbCache.image(for: record.file) {
            _phase = State(initialValue: .image(cached))
        } else {
            _phase = State(initialValue: .loading)
        }
    }

    var body: some View {
        ZStack {
            CheckerboardView(square: 10)
            switch phase {
            case .image(let img):
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .padding(Spacing.sm)
                    .transition(.opacity)
            case .loading:
                // Skeleton placeholder, sized to the tile, while the PNG loads from the App Group.
                SkeletonView(cornerRadius: Radius.card)
                    .padding(Spacing.xs)
                    .transition(.opacity)
            case .failed:
                // Calm, intentional fallback — never an endless shimmer when a file is missing/unreadable.
                Image(systemName: "photo")
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(.tertiary)
                    .transition(.opacity)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .task(id: record.id) { await load() }
    }

    private func load() async {
        // Already resolved (seeded from cache or loaded on a prior appear) — don't re-skeleton or re-read.
        if case .image = phase { return }
        let file = record.file
        // Read the PNG off the main thread (AppGroup is not actor-isolated) so the grid never blocks.
        let img = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let dir = AppGroup.stickersDirectory else { return nil }
            return UIImage(contentsOfFile: dir.appendingPathComponent(file).path)
        }.value
        guard !Task.isCancelled else { return }
        if let img {
            ThumbCache.set(img, for: file)
            withAnimation(.easeOut(duration: 0.2)) { phase = .image(img) }
        } else {
            // The load ALWAYS resolves — a missing/corrupt PNG lands on the calm placeholder, not a skeleton.
            withAnimation(.easeOut(duration: 0.2)) { phase = .failed }
        }
    }
}
