import SwiftUI
import PhotosUI

/// Runs the on-device subject lift, then lands on the headline Style Wall (instant-chain default).
///
/// INSTANT CHAIN: on photo pick we auto-run SubjectLift → AutoEdit → a default white outline so the very
/// first tile the user sees is already a finished sticker — no tap required. Tapping a tile (or "Open in
/// editor") routes into the editor seeded with that look.
///
/// REMIX: when opened from a "Remix in Peel" deep link, `remixTemplateID` is set; after the cutout we skip
/// the wall and drop straight into the editor with that exact look applied (the spec's remix behavior).
///
/// DEAD-ENDS → RETRY: the old noSubject/failed terminal screens are replaced with a retry path — "Pick a
/// different photo" (re-open the picker in place) or "Use the whole photo" (skip the lift and edit the
/// full image), so the user is never stranded.
struct MakeStickerFlow: View {
    let original: UIImage
    /// When set (a Remix deep link), skip the Style Wall and open the editor with this template's look.
    var remixTemplateID: String? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var current: UIImage
    @State private var phase: Phase = .processing
    @State private var editorEdit: EditorRoute?
    @State private var retryPick: PhotosPickerItem?

    init(original: UIImage, remixTemplateID: String? = nil) {
        self.original = original
        self.remixTemplateID = remixTemplateID
        _current = State(initialValue: original)
    }

    /// Identifiable + Hashable wrapper so a `StickerEdit` (Equatable, not Hashable) can drive
    /// `navigationDestination(item:)`. Identity/hash key off the UUID; the edit rides along untouched.
    private struct EditorRoute: Identifiable, Hashable {
        let id = UUID()
        let edit: StickerEdit
        var templateID: String? = nil
        static func == (a: EditorRoute, b: EditorRoute) -> Bool { a.id == b.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    enum Phase: Equatable {
        case processing
        case ready(UIImage)
        case noSubject
        case failed
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                switch phase {
                case .processing: processing
                case .ready(let cutout): styleWall(cutout)
                case .noSubject: retry(
                    icon: "person.crop.circle.badge.questionmark",
                    title: "No clear subject",
                    message: "Peel couldn't find a subject in that photo. Try one with a clearer object, person, or pet — or use the whole photo as-is.")
                case .failed: retry(
                    icon: "exclamationmark.triangle",
                    title: "Something went wrong",
                    message: "Couldn't process that image. Pick another one, or use the whole photo.")
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { await process(current) }
        .onChange(of: retryPick) { _, item in Task { await loadRetry(item) } }
    }

    // MARK: - Style Wall (instant-chain landing)

    @ViewBuilder
    private func styleWall(_ cutout: UIImage) -> some View {
        StyleWallView(
            cutout: cutout,
            onPick: { template in
                editorEdit = EditorRoute(edit: template.applied(to: cutout), templateID: template.id)
            },
            onOpenEditor: {
                // Instant chain: auto SubjectLift (done) → AutoEdit → default white outline, so the raw
                // editor opens on an already-finished sticker rather than a flat cutout.
                let capped = cutout.cappedToLongestSide(1400)
                var e = StickerEdit()
                e.layers = [StickerLayer(cutout: capped)]
                AutoEdit.enhance(&e, primary: capped)
                editorEdit = EditorRoute(edit: e)
            })
        .navigationDestination(item: $editorEdit) { route in
            StickerEditorView(edit: route.edit, original: original, templateID: route.templateID)
        }
    }

    // MARK: - Processing

    private var processing: some View {
        VStack(spacing: Spacing.xl) {
            // Skeleton of the sticker area (no spinner) while the on-device cutout runs — a shimmering
            // SQUARE placeholder the size of the sticker that's about to appear, with the user's own photo
            // showing softly behind it so the screen reads as "your photo, working" not "empty box".
            ZStack {
                SkeletonView(cornerRadius: Radius.hero)
                Image(uiImage: original)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: Radius.hero, style: .continuous))
                    .opacity(0.22)
                    .allowsHitTesting(false)
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 320)
            Text(remixTemplateID == nil ? "Lifting the subject…" : "Remixing your photo…")
                .font(AppFont.headline)
            Text("Running on your device. Nothing is uploaded.")
                .font(AppFont.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(Spacing.xl)
    }

    // MARK: - Retry (replaces the dead-end screens)

    private func retry(icon: String, title: String, message: String) -> some View {
        VStack(spacing: Spacing.lg) {
            Image(systemName: icon)
                .font(.system(size: 50, weight: .semibold))
                .foregroundStyle(Brand.accent)
            Text(title).font(AppFont.title)
            Text(message)
                .font(AppFont.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            VStack(spacing: Spacing.md) {
                PhotosPicker(selection: $retryPick, matching: .images, photoLibrary: .shared()) {
                    Label("Pick a different photo", systemImage: "photo.on.rectangle.angled")
                }
                .buttonStyle(AppButtonStyle(role: .primary))

                Button {
                    Haptics.tap()
                    // Use the whole photo as the cutout (skip the lift) so the user is never stranded.
                    withAnimation(.spring) { phase = .ready(current) }
                } label: {
                    Label("Use the whole photo", systemImage: "rectangle.dashed")
                }
                .buttonStyle(AppButtonStyle(role: .secondary))
            }
            .padding(.top, Spacing.sm)
        }
        .padding(Spacing.xl)
    }

    private func loadRetry(_ item: PhotosPickerItem?) async {
        guard let item,
              let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { return }
        retryPick = nil
        current = image
        withAnimation { phase = .processing }
        await process(image)
    }

    // MARK: - The instant chain

    private func process(_ image: UIImage) async {
        do {
            let cutout = try await SubjectLift.cutout(from: image)
            if let remixID = remixTemplateID, let template = StyleCatalog.template(id: remixID) {
                // Remix: skip the wall, open the editor on the fresh photo with that exact look applied.
                let applied = template.applied(to: cutout)
                await MainActor.run {
                    Haptics.pop()
                    editorEdit = EditorRoute(edit: applied, templateID: template.id)
                    withAnimation(.spring) { phase = .ready(cutout) }
                }
            } else {
                await MainActor.run {
                    Haptics.pop()
                    withAnimation(.spring) { phase = .ready(cutout) }
                }
            }
        } catch SubjectLiftError.noSubject {
            await MainActor.run { Haptics.warn(); withAnimation { phase = .noSubject } }
        } catch {
            await MainActor.run { Haptics.warn(); withAnimation { phase = .failed } }
        }
    }
}
