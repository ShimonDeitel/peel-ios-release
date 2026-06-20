import UIKit
import SwiftUI
import UniformTypeIdentifiers

/// Peel's system-wide keyboard. It surfaces the user's stickers (shared via the App Group) in EVERY app;
/// tapping one copies the transparent PNG to the clipboard so it can be pasted anywhere. Now adopts the
/// shared design language: system appearance (Light/Dark), the SHARED checkerboard, a designed empty
/// state, thumbnail caching, and a "Remix in Peel" deep link.
final class KeyboardViewController: UIInputViewController {
    private var host: UIHostingController<KeyboardRoot>!

    override func viewDidLoad() {
        super.viewDidLoad()
        let root = KeyboardRoot(
            hasFullAccess: hasFullAccess,
            onNextKeyboard: { [weak self] in self?.advanceToNextInputMode() },
            onRemix: { [weak self] in self?.openRemix() }
        )
        host = UIHostingController(rootView: root)
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        host.didMove(toParent: self)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        let h = view.heightAnchor.constraint(equalToConstant: 290)
        h.priority = UILayoutPriority(999)
        h.isActive = true
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        host.rootView.reloadToken = UUID()
        host.rootView.hasFullAccess = hasFullAccess
    }

    /// Bounce into the Peel app to remix on a fresh photo, carrying the most recent sticker's look.
    /// Keyboards open URLs via the responder chain's `openURL:` selector.
    private func openRemix() {
        let templateID = AppGroup.stickerRecords().first?.templateID ?? "classic_white"
        guard let url = AppGroup.remixURL(templateID: templateID) else { return }
        var responder: UIResponder? = self
        let sel = NSSelectorFromString("openURL:")
        while let r = responder {
            if r.responds(to: sel) {
                _ = r.perform(sel, with: url)
                return
            }
            responder = r.next
        }
    }
}

struct KeyboardRoot: View {
    var hasFullAccess: Bool
    var onNextKeyboard: () -> Void
    var onRemix: () -> Void
    var reloadToken = UUID()

    @State private var urls: [URL] = []
    @State private var toast: String?
    @State private var thumbCache: [URL: UIImage] = [:]

    private let accent = Color(.sRGB, red: 0, green: 0.478, blue: 1, opacity: 1)
    private let columns = [GridItem(.adaptive(minimum: 72), spacing: 10)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !hasFullAccess {
                fullAccessHint
            } else if urls.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(urls, id: \.self) { url in
                            Button { copy(url) } label: { tile(url) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .background(Color(.systemBackground))
        .tint(accent)
        .overlay(alignment: .bottom) { toastView }
        .onAppear(perform: load)
        .id(reloadToken)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: onNextKeyboard) {
                Image(systemName: "globe").font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary).frame(width: 38, height: 32)
            }
            Text("Peel").font(.headline)
            Spacer()
            if hasFullAccess, !urls.isEmpty {
                Button(action: onRemix) {
                    Label("Remix", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(accent)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func tile(_ url: URL) -> some View {
        ZStack {
            CheckerboardView(square: 9)
            if let img = thumbCache[url] {
                Image(uiImage: img).resizable().scaledToFit().padding(6)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "wand.and.stars").font(.system(size: 30, weight: .semibold)).foregroundStyle(.tint)
            Text("No stickers yet").font(.subheadline.weight(.semibold))
            Text("Make some in the Peel app — they'll show up here.").font(.caption)
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(24).frame(maxHeight: .infinity)
    }

    private var fullAccessHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.shield").font(.system(size: 30, weight: .semibold)).foregroundStyle(.secondary)
            Text("Turn on \u{201C}Allow Full Access\u{201D}").font(.subheadline.weight(.semibold))
            Text("Settings \u{203A} General \u{203A} Keyboard \u{203A} Keyboards \u{203A} Peel — required to copy stickers into other apps. Peel still never uploads anything.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(22).frame(maxHeight: .infinity)
    }

    @ViewBuilder private var toastView: some View {
        if let toast {
            Text(toast).font(.footnote.weight(.semibold))
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.thinMaterial, in: Capsule())
                .foregroundStyle(.primary).padding(.bottom, 14)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func load() {
        urls = AppGroup.stickerFileURLs()
        // Cache decoded thumbnails so re-layout doesn't re-read every PNG off disk each pass.
        for url in urls where thumbCache[url] == nil {
            if let img = UIImage(contentsOfFile: url.path) { thumbCache[url] = img }
        }
    }

    private func copy(_ url: URL) {
        guard hasFullAccess, let data = try? Data(contentsOf: url) else { return }
        UIPasteboard.general.setData(data, forPasteboardType: UTType.png.identifier)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation { toast = "Copied — long-press & paste" }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { withAnimation { toast = nil } }
    }
}
