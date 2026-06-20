import SwiftUI
import PhotosUI

/// The canvas-first layers rail: a compact horizontal strip of the stacked layers (top of the stack on
/// the LEFT), each a tappable thumbnail showing its cutout on a checkerboard. Tapping selects; the
/// selected layer gets the accent ring. A trailing "+" adds another subject. Per-layer hide/lock/delete
/// live in the selected layer's quick actions row so the rail stays glanceable.
///
/// The rail edits the layer stack directly through closures the editor supplies, so every mutation flows
/// through the editor's history (one undo step per action).
struct LayersRailView: View {
    let layers: [StickerLayer]
    @Binding var selectedLayerID: UUID?
    let canAddLayer: Bool
    let isAddingLayer: Bool

    var onSelect: (UUID) -> Void
    var onToggleHidden: (UUID) -> Void
    var onToggleLocked: (UUID) -> Void
    var onDelete: (UUID) -> Void
    @Binding var addPick: PhotosPickerItem?
    var onAddLocked: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    // Top of the stack reads left-to-right, so show the array reversed.
                    ForEach(Array(layers.enumerated().reversed()), id: \.element.id) { _, layer in
                        thumb(layer)
                    }
                    addTile
                }
                .padding(.horizontal, 16)
            }
            if let sel = selectedLayer { quickActions(sel) }
        }
        .padding(.vertical, 8)
    }

    private var selectedLayer: StickerLayer? {
        layers.first { $0.id == selectedLayerID }
    }

    private func thumb(_ layer: StickerLayer) -> some View {
        let selected = layer.id == selectedLayerID
        return Button {
            onSelect(layer.id)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
                CheckerboardView(square: 7)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .opacity(0.5)
                Image(uiImage: layer.cutout)
                    .resizable().scaledToFit().padding(6)
                    .opacity(layer.isHidden ? 0.25 : 1)
                if layer.isHidden {
                    Image(systemName: "eye.slash.fill")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if layer.isLocked {
                    VStack { HStack { Spacer()
                        Image(systemName: "lock.fill").font(.system(size: 9))
                            .foregroundStyle(.secondary).padding(4)
                    }; Spacer() }
                }
                if layer.type == .text {
                    VStack { Spacer(); HStack {
                        Image(systemName: "textformat").font(.system(size: 9))
                            .foregroundStyle(.secondary).padding(4)
                        Spacer() } }
                }
            }
            .frame(width: 54, height: 54)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08),
                                  lineWidth: selected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var addTile: some View {
        if isAddingLayer {
            // Skeleton placeholder (no spinner) for the layer thumb that's lifting.
            SkeletonTile(side: 54, cornerRadius: 12)
        } else if canAddLayer {
            PhotosPicker(selection: $addPick, matching: .images, photoLibrary: .shared()) {
                addLabel
            }
        } else {
            // Locked state retained for API compatibility; layers are free, so this path isn't reached.
            Button { onAddLocked() } label: { addLabel }
                .buttonStyle(.plain)
        }
    }

    private var addLabel: some View {
        Image(systemName: "plus")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .frame(width: 54, height: 54)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }

    private func quickActions(_ layer: StickerLayer) -> some View {
        HStack(spacing: 18) {
            actionButton(layer.isHidden ? "eye.slash" : "eye",
                         active: layer.isHidden) { onToggleHidden(layer.id) }
                .accessibilityLabel(layer.isHidden ? "Show layer" : "Hide layer")
            actionButton(layer.isLocked ? "lock.fill" : "lock.open",
                         active: layer.isLocked) { onToggleLocked(layer.id) }
                .accessibilityLabel(layer.isLocked ? "Unlock layer" : "Lock layer")
            Spacer()
            if layers.count > 1 {
                Button(role: .destructive) { onDelete(layer.id) } label: {
                    Image(systemName: "trash").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.red)
                }
                .accessibilityLabel("Delete layer")
            }
        }
        .padding(.horizontal, 20)
    }

    private func actionButton(_ icon: String, active: Bool, _ act: @escaping () -> Void) -> some View {
        Button { Haptics.tap(); act() } label: {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(active ? Color.accentColor : Color.secondary)
        }
    }
}
