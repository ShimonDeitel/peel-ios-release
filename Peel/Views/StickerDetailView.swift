import SwiftUI

struct StickerDetailView: View {
    let record: StickerRecord
    @EnvironmentObject var store: Store
    @EnvironmentObject var stickers: StickerStore
    @EnvironmentObject var quota: DailyQuota
    @Environment(\.dismiss) private var dismiss

    @State private var showShare = false
    @State private var editRoute: EditRoute?

    private var image: UIImage? { stickers.image(for: record) }

    /// Whether this sticker carries a re-openable `.peelproj` sidecar (full editable project). Legacy PNGs
    /// have none — they still re-open, just as a fresh edit built from the flat image.
    private var hasProject: Bool { ProjectStore.hasProject(forPNGFile: record.file) }

    var body: some View {
        NavigationStack {
            ZStack {
                AuroraBackground()
                VStack(spacing: 22) {
                    ZStack {
                        CheckerboardView()
                        if let image {
                            Image(uiImage: image).resizable().scaledToFit().padding(28)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .padding(.horizontal, 18)

                    VStack(spacing: 12) {
                        Button { openEditor() } label: {
                            Label("Edit sticker", systemImage: "slider.horizontal.3")
                        }
                        .buttonStyle(GlassActionButtonStyle())

                        Button { showShare = true } label: {
                            Label("Share sticker", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(GlassActionButtonStyle(tint: Color(.secondarySystemBackground)))
                    }
                    .padding(.horizontal, 18)
                }
                .padding(.vertical, 16)
            }
            .navigationTitle("Sticker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        stickers.delete(record); Haptics.pop(); dismiss()
                    } label: { Image(systemName: "trash") }
                }
            }
            .sheet(isPresented: $showShare) {
                if let image {
                    // Share the transparent PNG as a FILE so WhatsApp / Instagram / Telegram / Messages
                    // accept it with its die-cut alpha intact (a bare UIImage can be re-encoded opaque).
                    ShareSheet(items: SharePNG.write(image).map { [$0] } ?? [image])
                }
            }
            .fullScreenCover(item: $editRoute) { route in
                NavigationStack {
                    StickerEditorView(edit: route.edit, original: route.original,
                                      templateID: record.templateID, isReedit: true)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button { editRoute = nil } label: { Image(systemName: "chevron.left") }
                                    .accessibilityLabel("Back")
                            }
                        }
                }
                .environmentObject(store)
                .environmentObject(stickers)
                .environmentObject(quota)
            }
        }
    }

    // MARK: - Re-open

    /// Re-open the sticker for non-destructive editing. With a sidecar we restore the EXACT editable
    /// project (layers, per-layer looks, text, background). Without one (legacy PNG) we open the flat image
    /// as a brand-new single-layer edit so the user can still keep working on it.
    private func openEditor() {
        Haptics.tap()
        if let project = stickers.project(for: record), let primary = project.primary {
            editRoute = EditRoute(edit: project, original: primary.cutout)
        } else if let flat = image {
            // Legacy / sidecar-less: treat the saved sticker PNG as a fresh cutout to edit.
            let capped = flat.cappedToLongestSide(1400)
            var e = StickerEdit()
            e.layers = [StickerLayer(cutout: capped)]
            editRoute = EditRoute(edit: e, original: capped)
        }
    }

    /// Identifiable wrapper so a restored `StickerEdit` can drive `fullScreenCover(item:)`.
    private struct EditRoute: Identifiable {
        let id = UUID()
        let edit: StickerEdit
        let original: UIImage
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    var onComplete: ((Bool) -> Void)? = nil
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        vc.completionWithItemsHandler = { _, completed, _, _ in onComplete?(completed) }
        return vc
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
