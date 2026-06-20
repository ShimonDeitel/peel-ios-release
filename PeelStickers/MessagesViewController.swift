import UIKit
import SwiftUI
import Messages

/// iMessage extension host. Embeds an `MSStickerBrowserViewController` (the proven insertion path) over
/// the SHARED checkerboard motif, with a designed SwiftUI empty state and a "Remix in Peel" affordance.
/// Reads stickers + the credit/unlimited state from the App Group; never networks, never uploads.
final class MessagesViewController: MSMessagesAppViewController {
    private var browser: PeelStickerBrowserViewController?
    private var backgroundHost: UIHostingController<StickerBrowserBackground>?
    private var emptyHost: UIHostingController<StickerBrowserEmptyState>?
    private var remixHost: UIHostingController<RemixBar>?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        // 1) Shared checkerboard backdrop (so transparent stickers read in the drawer).
        let bg = UIHostingController(rootView: StickerBrowserBackground())
        embed(bg, fill: true)
        bg.view.isUserInteractionEnabled = false
        backgroundHost = bg

        // 2) The sticker browser (insertion).
        let b = PeelStickerBrowserViewController(stickerSize: .regular)
        addChild(b)
        b.view.frame = view.bounds
        b.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(b.view)
        b.didMove(toParent: self)
        b.stickerBrowserView.backgroundColor = .clear
        browser = b

        // 3) Designed empty state (hidden when stickers exist).
        let empty = UIHostingController(rootView: StickerBrowserEmptyState())
        empty.view.backgroundColor = .clear
        embed(empty, fill: true)
        emptyHost = empty

        // 4) "Remix in Peel" bar pinned to the bottom — opens the most recent look on a fresh photo.
        let remix = UIHostingController(rootView: RemixBar(onRemix: { [weak self] in self?.openRemix() }))
        remix.view.backgroundColor = .clear
        addChild(remix)
        remix.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(remix.view)
        remix.didMove(toParent: self)
        NSLayoutConstraint.activate([
            remix.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            remix.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            remix.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        remixHost = remix

        refresh()
    }

    private func embed(_ child: UIViewController, fill: Bool) {
        addChild(child)
        child.view.frame = view.bounds
        child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(child.view)
        child.didMove(toParent: self)
    }

    override func willBecomeActive(with conversation: MSConversation) {
        super.willBecomeActive(with: conversation)
        refresh()
    }

    private func refresh() {
        browser?.reload()
        let hasStickers = (browser?.count ?? 0) > 0
        emptyHost?.view.isHidden = hasStickers
        remixHost?.view.isHidden = !hasStickers
    }

    /// Open the Peel app to remix: carry the most-recent sticker's saved look (its `templateID`), falling
    /// back to the default classic white outline so the link always resolves to something usable.
    private func openRemix() {
        let templateID = AppGroup.stickerRecords().first?.templateID ?? "classic_white"
        guard let url = AppGroup.remixURL(templateID: templateID) else { return }
        extensionContext?.open(url, completionHandler: nil)
    }
}

final class PeelStickerBrowserViewController: MSStickerBrowserViewController {
    private var stickers: [MSSticker] = []
    var count: Int { stickers.count }

    func reload() {
        stickers = AppGroup.stickerFileURLs().compactMap { url in
            try? MSSticker(contentsOfFileURL: url, localizedDescription: "Peel sticker")
        }
        stickerBrowserView.reloadData()
    }

    override func numberOfStickers(in stickerBrowserView: MSStickerBrowserView) -> Int {
        stickers.count
    }

    override func stickerBrowserView(_ stickerBrowserView: MSStickerBrowserView,
                                     stickerAt index: Int) -> MSSticker {
        stickers[index]
    }
}

// MARK: - SwiftUI chrome (shared design language, system appearance)

/// The shared checkerboard, dimmed, as the drawer backdrop.
private struct StickerBrowserBackground: View {
    var body: some View {
        CheckerboardView(square: 12)
            .opacity(0.5)
            .ignoresSafeArea()
    }
}

/// Designed empty state — same SF-Symbol + system-color idiom as the app.
private struct StickerBrowserEmptyState: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.tint)
            Text("No stickers yet")
                .font(.headline)
            Text("Make some in the Peel app — they'll show up right here.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tint(Color(.sRGB, red: 0, green: 0.478, blue: 1, opacity: 1))
    }
}

/// Quiet bottom bar to bounce into the Peel app and remix on a fresh photo.
private struct RemixBar: View {
    var onRemix: () -> Void
    private let accent = Color(.sRGB, red: 0, green: 0.478, blue: 1, opacity: 1)
    var body: some View {
        Button(action: onRemix) {
            Label("Remix in Peel", systemImage: "arrow.triangle.2.circlepath")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(accent)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.thinMaterial, in: Capsule())
        }
        .padding(.bottom, 10)
    }
}
