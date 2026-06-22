import SwiftUI
import PhotosUI

/// The rebuilt editor (Stage 3). Canvas-first: a large checkerboard canvas with a REAL per-layer
/// hit-testing surface (tap a subject to select it, drag/scale/rotate the SELECTED layer with a visible
/// bounding box + handles + snap guides), a layers rail beneath it, and a content-sized contextual
/// inspector presented as a sheet with detents (replacing the fixed 168pt 7-tab drawer).
///
/// PERFORMANCE: each layer is shown as its own lightweight `Image` while a gesture is live, transformed in
/// SwiftUI; the heavy Core Image composite runs ONLY on gesture-END and on export. Between gestures the
/// canvas shows the full composite. This kills the 28ms full-recomposite rubber-banding.
///
/// HISTORY: every change is bracketed through `History` — continuous controls coalesce into one undo step.
/// QUOTA: checked at editor-OPEN (the spec's "creation START"), never at share.
struct StickerEditorView: View {
    let original: UIImage
    /// The Style-Wall template this edit was seeded from, if any. Saved into the sticker's record so a
    /// received sticker can be Remixed with the same look.
    var templateID: String? = nil
    /// True when RE-OPENING an already-saved sticker (vs. creating a new one). Re-editing an existing
    /// sticker never shows the out-of-budget block on OPEN — the user can always tweak what they made; a
    /// fresh create slot is only spent if/when they save the edited result as a new sticker.
    var isReedit: Bool = false
    @EnvironmentObject var store: Store
    @EnvironmentObject var stickers: StickerStore
    @EnvironmentObject var quota: DailyQuota
    @Environment(\.dismiss) private var dismiss

    @State private var edit: StickerEdit
    @State private var rendered: UIImage
    @State private var selectedLayerID: UUID?
    @StateObject private var history = History()

    @State private var activeInspector: InspectorTab?
    @State private var showPaywall = false
    @State private var blockedByQuota = false
    @State private var showShare = false
    @State private var toast: String?
    @State private var savedToLibrary = false
    @State private var consumedQuota = false
    @State private var filterThumbs: [PhotoFilter: UIImage] = [:]
    @State private var effectThumbs: [EffectPreset: UIImage] = [:]
    @State private var renderTask: Task<Void, Never>?
    @State private var secondPick: PhotosPickerItem?
    @State private var liftingSecond = false
    @State private var exporting = false
    @State private var shareImage: UIImage?

    // New-feature surfaces (Stage 3+): add-content menu, emoji entry, photo-layer pick, doodle cover.
    @State private var showAddSheet = false
    @State private var showEmojiSheet = false
    @State private var emojiText: String = ""
    @State private var photoLayerPick: PhotosPickerItem?
    @State private var addingPhotoLayer = false
    @State private var showDraw = false

    /// While a canvas gesture is live the heavy composite is suppressed and the dragged layer is shown
    /// lightweight; this holds the id so the composite can hide that layer until release.
    @State private var liveLayerID: UUID?

    private let previewCanvas: CGFloat = 660
    /// Export resolution is the Pro benefit advertised on the paywall: Pro unlocks full 2048px export,
    /// while the free tier exports at a still-generous 1024px. The editor itself and every tool stay free;
    /// only the export *resolution* (and how many new stickers you create) scales with Pro.
    private var exportCanvas: CGFloat { store.isPro ? 2048 : 1024 }

    /// The contextual inspector panels. Far fewer than the old 7 chips — each panel is content-sized and
    /// only shown when summoned, so the canvas owns the screen.
    enum InspectorTab: String, CaseIterable, Identifiable {
        case effects, adjust, look, filter, layer, background, text
        var id: String { rawValue }
        var title: String {
            switch self {
            case .effects: return "Effects"
            case .adjust: return "Adjust"
            case .look: return "Outline"
            case .filter: return "Filter"
            case .layer: return "Layer"
            case .background: return "Background"
            case .text: return "Text"
            }
        }
        var icon: String {
            switch self {
            case .effects: return "wand.and.stars"
            case .adjust: return "slider.horizontal.3"
            case .look: return "paintbrush.pointed.fill"
            case .filter: return "camera.filters"
            case .layer: return "square.3.layers.3d"
            case .background: return "square.on.square.dashed"
            case .text: return "textformat"
            }
        }
    }

    init(cutout: UIImage, original: UIImage, templateID: String? = nil) {
        self.original = original
        self.templateID = templateID
        let capped = cutout.cappedToLongestSide(1400)
        var e = StickerEdit()
        let layer = StickerLayer(cutout: capped)
        e.layers = [layer]
        _edit = State(initialValue: e)
        _selectedLayerID = State(initialValue: layer.id)
        _rendered = State(initialValue: capped)
    }

    /// Open on a ready-made `StickerEdit` — the Style Wall (a tapped template already applied to the
    /// user's cutout) and re-opening a saved project's sidecar both arrive here. `isReedit` is set when
    /// re-opening a previously SAVED sticker so the open-time quota block is skipped.
    init(edit: StickerEdit, original: UIImage, templateID: String? = nil, isReedit: Bool = false) {
        self.original = original
        self.templateID = templateID
        self.isReedit = isReedit
        _edit = State(initialValue: edit)
        _selectedLayerID = State(initialValue: edit.layers.first?.id)
        _rendered = State(initialValue: edit.primary?.cutout ?? UIImage())
    }

    var body: some View {
        VStack(spacing: 0) {
            canvas
            railAndTools
            actions
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .navigationTitle("Editor")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { historyToolbar }
        .sheet(item: $activeInspector) { tab in inspectorSheet(tab) }
        .fullScreenCover(isPresented: $showDraw) { drawCover }
        .sheet(isPresented: $showPaywall, onDismiss: { reconcileQuotaAfterPurchase() }) {
            PaywallView().environmentObject(store)
        }
        .sheet(isPresented: $showShare) { if let img = shareImage { ShareSheet(items: shareItems(img)) } }
        .sheet(isPresented: $showAddSheet) { addContentSheet }
        .alert("Add emoji", isPresented: $showEmojiSheet) {
            TextField("😀", text: $emojiText)
            Button("Add") { addEmojiLayer() }
            Button("Cancel", role: .cancel) { emojiText = "" }
        } message: { Text("Type or paste an emoji to drop it on your sticker.") }
        .overlay(alignment: .bottom) { toastView }
        .overlay { if blockedByQuota { quotaBlock } }
        .onChange(of: edit) { _, _ in if liveLayerID == nil { scheduleRender() } }
        .onChange(of: secondPick) { _, item in Task { await loadSecond(item) } }
        .onChange(of: photoLayerPick) { _, item in Task { await loadPhotoLayer(item) } }
        .task { ensureQuotaAtOpen(); scheduleRender(); await buildFilterThumbs(); await buildEffectThumbs() }
    }

    // MARK: - History toolbar

    @ToolbarContentBuilder private var historyToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { applyUndo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!history.canUndo)
            Button { applyRedo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!history.canRedo)
        }
    }

    // MARK: - Canvas

    private var canvas: some View {
        ZStack {
            CheckerboardView()
            LiveCanvasView(
                edit: $edit,
                rendered: rendered,
                selectedLayerID: $selectedLayerID,
                liveLayerID: $liveLayerID,
                isDual: edit.isDual,
                onGestureBegin: { history.begin(from: edit) },
                onGestureEnd: { tag in
                    history.commit(edit, tag: tag)
                    liveLayerID = nil
                    scheduleRender()
                })
            .padding(18)
            if liftingSecond {
                // Lifting another subject is the genuinely SLOW op — preview its arrival with a skeleton of
                // the sticker area (no spinner). A quick export does NOT blank the canvas (see below).
                SkeletonView(cornerRadius: 22)
                    .padding(40)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.ultraThinMaterial)
                    .transition(.opacity)
            } else if exporting {
                // Export is near-instant — keep the finished composite fully visible and show only a quiet
                // corner badge, rather than gratuitously skeleton-ing a canvas that's already rendered.
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Label("Preparing…", systemImage: "square.and.arrow.up")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(16)
                    }
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .padding(.horizontal, 16).padding(.top, 8)
    }

    // MARK: - Rail + tool buttons

    private var railAndTools: some View {
        VStack(spacing: 10) {
            LayersRailView(
                layers: edit.layers,
                selectedLayerID: $selectedLayerID,
                // Layers are an EDITING tool — free for everyone. Never gated behind Pro.
                canAddLayer: true,
                isAddingLayer: liftingSecond,
                onSelect: { selectedLayerID = $0; Haptics.tap() },
                onToggleHidden: { id in mutate(tag: nil) { e in toggle(\.isHidden, id, &e) } },
                onToggleLocked: { id in mutate(tag: nil) { e in toggle(\.isLocked, id, &e) } },
                onDelete: { id in deleteLayer(id) },
                addPick: $secondPick,
                onAddLocked: {})

            toolStrip
        }
        .padding(.top, 6)
    }

    private var toolStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                addTool
                ForEach(InspectorTab.allCases) { t in
                    Button { Haptics.tap(); activeInspector = t } label: {
                        VStack(spacing: 5) {
                            Image(systemName: t.icon).font(.system(size: 17, weight: .semibold))
                            Text(t.title).font(.caption2)
                        }
                        .foregroundStyle(.primary)
                        .frame(width: 70, height: 54)
                        .background(Color(.secondarySystemBackground),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                doodleTool
                transformChip
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 4)
    }

    /// Opens the "add content" menu — emoji, photo, shape, or another subject. All free, all on-device.
    private var addTool: some View {
        Button { Haptics.tap(); showAddSheet = true } label: {
            VStack(spacing: 5) {
                Image(systemName: "plus.circle.fill").font(.system(size: 17, weight: .semibold))
                Text("Add").font(.caption2)
            }
            .foregroundStyle(Color.accentColor)
            .frame(width: 70, height: 54)
            .background(Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// Freehand draw/doodle on a brush layer.
    private var doodleTool: some View {
        Button { Haptics.tap(); showDraw = true } label: {
            VStack(spacing: 5) {
                Image(systemName: "scribble.variable").font(.system(size: 17, weight: .semibold))
                Text("Doodle").font(.caption2)
            }
            .foregroundStyle(.primary)
            .frame(width: 70, height: 54)
            .background(Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// Quick rotate / flip / duplicate live inline (they act on the selected layer without opening a panel).
    private var transformChip: some View {
        HStack(spacing: 8) {
            quickTransform("rotate.right") { rotateSelectedQuarter() }
            quickTransform("arrow.left.and.right.righttriangle.left.righttriangle.right") { toggleSelectedFlipH() }
            quickTransform("arrow.up.and.down.righttriangle.up.righttriangle.down") { toggleSelectedFlipV() }
            quickTransform("plus.square.on.square") { duplicateSelected() }
            quickTransform("crop") { cropSelectedToBounds() }
        }
    }
    private func quickTransform(_ icon: String, _ act: @escaping () -> Void) -> some View {
        Button { Haptics.tap(); act() } label: {
            Image(systemName: icon).font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 54, height: 54)
                .background(Color(.secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }.buttonStyle(.plain)
    }

    // MARK: - Inspector sheet (content-sized, detents)

    @ViewBuilder private func inspectorSheet(_ tab: InspectorTab) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch tab {
                    case .effects: effectsInspector
                    case .adjust: adjustInspector
                    case .look: outlineInspector
                    case .filter: filterInspector
                    case .layer: layerInspector
                    case .background: backgroundInspector
                    case .text: textInspector
                    }
                }
                .padding(20)
            }
            .navigationTitle(tab.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { activeInspector = nil }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .tint(Color.accentColor)
    }

    // MARK: Effects inspector (one-tap presets)

    private var effectsInspector: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("One-tap looks. Each restyles the selected layer — tap again to switch.")
                .font(.footnote).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 12)], spacing: 14) {
                ForEach(EffectPreset.allCases) { p in
                    Button { applyEffectPreset(p) } label: {
                        VStack(spacing: 6) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color(.secondarySystemBackground)).frame(height: 72)
                                if let t = effectThumbs[p] {
                                    Image(uiImage: t).resizable().scaledToFit().padding(8)
                                } else {
                                    Image(systemName: p.symbol).font(.system(size: 22, weight: .semibold))
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                            Text(p.title).font(.caption2).foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Layer inspector (per-layer opacity + blend mode)

    private var layerInspector: some View {
        VStack(alignment: .leading, spacing: 16) {
            if hasSel {
                InspectorSection(title: "Opacity", systemImage: "circle.lefthalf.filled") {
                    ValueSlider(
                        title: "Opacity",
                        value: layerOpacityBinding,
                        range: 0...1,
                        defaultValue: 1,
                        format: SliderFormat.percent(of: 1),
                        onEditingChanged: { editing in editingChanged(editing, tag: "layer.opacity") })
                }
                InspectorSection(title: "Blend", systemImage: "square.3.layers.3d") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                        ForEach(LayerBlendMode.allCases) { m in
                            Button { Haptics.tap(); setSelectedBlend(m) } label: {
                                Text(m.title)
                                    .font(.caption.weight(.medium))
                                    .frame(maxWidth: .infinity).padding(.vertical, 9)
                                    .background(Color(.tertiarySystemBackground),
                                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(selectedBlend == m ? Color.accentColor : .clear, lineWidth: 2))
                                    .foregroundStyle(selectedBlend == m ? Color.accentColor : .primary)
                            }.buttonStyle(.plain)
                        }
                    }
                }
            } else {
                Text("Select a layer to adjust its opacity and blend.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Add-content sheet (emoji / photo / shape / subject)

    private var addContentSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    addRow("Emoji", "face.smiling", "Drop an emoji as a layer") {
                        showAddSheet = false; emojiText = ""; showEmojiSheet = true
                    }
                    PhotosPicker(selection: $photoLayerPick, matching: .images, photoLibrary: .shared()) {
                        addRowLabel("Photo", "photo", "Add a photo (no cutout)")
                    }.onChange(of: photoLayerPick) { _, _ in showAddSheet = false }
                    PhotosPicker(selection: $secondPick, matching: .images, photoLibrary: .shared()) {
                        addRowLabel("Cutout subject", "person.crop.rectangle", "Lift another subject")
                    }.onChange(of: secondPick) { _, _ in showAddSheet = false }

                    InspectorSection(title: "Shapes", systemImage: "square.on.circle") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 12)], spacing: 12) {
                            ForEach(ShapeKind.allCases) { k in
                                Button { Haptics.tap(); showAddSheet = false; addShapeLayer(k) } label: {
                                    VStack(spacing: 6) {
                                        Image(systemName: k.symbol).font(.system(size: 24))
                                            .foregroundStyle(Color.accentColor).frame(height: 36)
                                        Text(k.title).font(.caption2).foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(20)
            }
            .navigationTitle("Add")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { showAddSheet = false } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .tint(Color.accentColor)
    }

    private func addRow(_ title: String, _ icon: String, _ subtitle: String, _ act: @escaping () -> Void) -> some View {
        Button { Haptics.tap(); act() } label: { addRowLabel(title, icon, subtitle) }
            .buttonStyle(.plain)
    }
    private func addRowLabel(_ title: String, _ icon: String, _ subtitle: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.accentColor).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: Adjust inspector (grouped Light / Color)

    private var adjustInspector: some View {
        VStack(alignment: .leading, spacing: 16) {
            autoEditButton
            InspectorSection(title: "Light", systemImage: "sun.max") {
                slider("Brightness", \.brightness, -0.4...0.4, 0, SliderFormat.signedPercent(center: 0, halfSpan: 0.4))
                slider("Contrast", \.contrast, 0.6...1.5, 1.0, SliderFormat.multiplier)
                slider("Exposure", \.exposure, -2...2, 0, SliderFormat.ev)
                slider("Highlights", \.highlights, 0.3...1.0, 1.0, SliderFormat.multiplier)
                slider("Shadows", \.shadows, 0...1, 0, SliderFormat.percent(of: 1))
                slider("Sharpness", \.sharpness, 0...1, 0, SliderFormat.percent(of: 1))
            }
            InspectorSection(title: "Color", systemImage: "paintpalette") {
                slider("Saturation", \.saturation, 0...2, 1.0, SliderFormat.multiplier)
                slider("Vibrance", \.vibrance, -1...1, 0, SliderFormat.signedPercent(center: 0, halfSpan: 1))
                slider("Warmth", \.warmth, -1...1, 0, SliderFormat.signedPercent(center: 0, halfSpan: 1))
                slider("Tint", \.tint, -1...1, 0, SliderFormat.signedPercent(center: 0, halfSpan: 1))
                slider("Hue", \.hue, -3.14...3.14, 0, SliderFormat.degrees)
                slider("Vignette", \.vignette, 0...1.5, 0, SliderFormat.percent(of: 1.5))
                slider("Grain", \.grain, 0...0.5, 0, SliderFormat.percent(of: 0.5))
            }
        }
    }

    private var autoEditButton: some View {
        // Auto-Edit is an EDITING tool — free for everyone, no Pro pill, no paywall.
        Button { autoEdit() } label: {
            Label("Auto-Edit", systemImage: "wand.and.stars").frame(maxWidth: .infinity)
        }
        .buttonStyle(GlassActionButtonStyle())
    }

    // MARK: Outline / glow / shadow inspector

    private var outlineInspector: some View {
        VStack(alignment: .leading, spacing: 16) {
            InspectorSection(title: "Outline", systemImage: "paintbrush.pointed") {
                chipRow(OutlineStyle.allCases, selected: look.outline,
                        title: { $0.title }, swatch: { AnyView(styleSwatch($0)) }) { setLook(tag: nil) { $0.outline = $1 } ($0) }
                colorRow("Color", outlineColorBinding)
                slider("Width", \.outlineWidth, 0...1, 0.5, SliderFormat.percent(of: 1))
                if look.outline == .glow {
                    colorRow("Glow color", lookColorBinding(\.glowColor))
                    slider("Glow radius", \.glowRadius, 0...1, 0.5, SliderFormat.percent(of: 1))
                }
            }
            InspectorSection(title: "Shadow", systemImage: "shadow") {
                slider("Opacity", \.shadowOpacity, 0...0.6, 0, SliderFormat.percent(of: 0.6))
                slider("Blur", \.shadowBlur, 0...1, 0.5, SliderFormat.percent(of: 1))
                slider("Offset", \.shadowOffset, 0...1, 0.5, SliderFormat.percent(of: 1))
            }
            InspectorSection(title: "Edge", systemImage: "scissors") {
                slider("Feather", \.feather, 0...1, 0, SliderFormat.percent(of: 1))
            }
        }
    }

    // MARK: Filter inspector

    private var filterInspector: some View {
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 12)], spacing: 14) {
                ForEach(PhotoFilter.allCases) { f in
                    Button { Haptics.tap(); setLook(tag: nil) { $0.filter = $1 } (f) } label: {
                        VStack(spacing: 6) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color(.secondarySystemBackground)).frame(width: 64, height: 64)
                                if let t = filterThumbs[f] {
                                    Image(uiImage: t).resizable().scaledToFit().padding(6)
                                } else {
                                    // Calm placeholder while the preview renders — never a blank box.
                                    Image(systemName: "camera.filters")
                                        .font(.system(size: 18, weight: .regular))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(look.filter == f ? Color.accentColor : Color.primary.opacity(0.08),
                                              lineWidth: look.filter == f ? 2 : 1))
                            Text(f.title).font(.caption2)
                                .foregroundStyle(look.filter == f ? .primary : .secondary)
                        }
                    }.buttonStyle(.plain)
                }
            }
            if look.filter != .none {
                InspectorSection(title: "Strength") {
                    slider("Strength", \.filterStrength, 0...1, 1.0, SliderFormat.percent(of: 1))
                }
            }
        }
    }

    // MARK: Background inspector (global)

    private var backgroundInspector: some View {
        VStack(alignment: .leading, spacing: 16) {
            chipRow(StickerBackground.allCases, selected: edit.background,
                    title: { $0.title }, swatch: { AnyView(bgSwatch($0)) }) { bg in
                mutate(tag: nil) { $0.background = bg }
            }
            if edit.background == .solid {
                colorRow("Color", editColorBinding(\.bgSolidColor))
            }
            if edit.background == .gradient {
                colorRow("Top", editColorBinding(\.bgGradientTop))
                colorRow("Bottom", editColorBinding(\.bgGradientBottom))
            }
            if edit.background != .none {
                InspectorSection(title: "Shape") {
                    editSlider("Corner radius", \.bgCornerRadius, 0...0.5, 0, SliderFormat.percent(of: 0.5))
                    editSlider("Padding", \.bgPadding, 0...1, 0, SliderFormat.percent(of: 1))
                }
            }
        }
    }

    // MARK: Text inspector

    private var textInspector: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("Add a caption…", text: textStringBinding)
                .textInputAutocapitalization(look.text.uppercase ? .characters : .sentences)
                .padding(12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            fontPicker
            colorRow("Text color", textColorBinding)
            InspectorSection(title: "Type") {
                slider("Size", \.text.sizeFraction, 0.06...0.22, 0.13, SliderFormat.percent(of: 0.22))
                slider("Spacing", \.text.kern, 0...0.3, 0, SliderFormat.percent(of: 0.3))
                slider("Curve", \.text.curve, -1...1, 0, SliderFormat.signedPercent(center: 0, halfSpan: 1))
            }
            Picker("", selection: textPositionBinding) {
                Text("Top").tag(TextPosition.top)
                Text("Middle").tag(TextPosition.middle)
                Text("Bottom").tag(TextPosition.bottom)
            }.pickerStyle(.segmented)
            VStack(spacing: 8) {
                Toggle("Uppercase", isOn: textToggleBinding(\.uppercase))
                Toggle("Outline", isOn: textToggleBinding(\.stroked))
                Toggle("Shadow", isOn: textToggleBinding(\.shadowed))
            }
            .font(.subheadline)
        }
    }

    private var fontPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(StickerFont.allCases) { f in
                    Button { Haptics.tap(); setLook(tag: nil) { $0.text.font = $1 } (f) } label: {
                        VStack(spacing: 2) {
                            Text("Ag").font(.system(size: 17, weight: .bold))
                            Text(f.title).font(.system(size: 8)).foregroundStyle(.secondary)
                        }
                        .frame(width: 52, height: 44)
                        .foregroundStyle(.primary)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(look.text.font == f ? Color.accentColor : .clear, lineWidth: 2))
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Reusable inspector controls

    /// A slider bound to the SELECTED layer's look, bracketed into history (coalesced by `tag`) and
    /// running the heavy composite only on release.
    private func slider(_ title: String, _ kp: WritableKeyPath<LayerLook, Double>,
                        _ range: ClosedRange<Double>, _ def: Double,
                        _ format: @escaping (Double) -> String) -> some View {
        ValueSlider(
            title: title,
            value: lookBinding(kp),
            range: range,
            defaultValue: def,
            format: format,
            onEditingChanged: { editing in editingChanged(editing, tag: "look.\(title)") })
    }

    /// A slider bound to a GLOBAL edit field (background shape).
    private func editSlider(_ title: String, _ kp: WritableKeyPath<StickerEdit, Double>,
                            _ range: ClosedRange<Double>, _ def: Double,
                            _ format: @escaping (Double) -> String) -> some View {
        ValueSlider(
            title: title,
            value: Binding(get: { edit[keyPath: kp] }, set: { edit[keyPath: kp] = $0 }),
            range: range,
            defaultValue: def,
            format: format,
            onEditingChanged: { editing in editingChanged(editing, tag: "edit.\(title)") })
    }

    private func colorRow(_ label: String, _ binding: Binding<Color>) -> some View {
        HStack {
            Text(label).font(.subheadline).foregroundStyle(.primary)
            Spacer()
            ColorPicker("", selection: binding, supportsOpacity: false).labelsHidden()
        }
    }

    private func chipRow<T: Hashable & Identifiable>(_ items: [T], selected: T,
                                                     title: @escaping (T) -> String, swatch: @escaping (T) -> AnyView,
                                                     pick: @escaping (T) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(items) { item in
                    Button { Haptics.tap(); pick(item) } label: {
                        VStack(spacing: 6) {
                            swatch(item)
                            Text(title(item)).font(.caption2)
                                .foregroundStyle(selected == item ? .primary : .secondary)
                        }
                        .padding(5)
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(selected == item ? Color.accentColor : .clear, lineWidth: 2))
                    }.buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func styleSwatch(_ s: OutlineStyle) -> some View {
        ZStack {
            Circle().fill(s.swatch).frame(width: 44, height: 44)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 1))
            if s == .none { Image(systemName: "nosign").foregroundStyle(.secondary) }
            if s == .custom { Image(systemName: "eyedropper").font(.system(size: 14)).foregroundStyle(.white) }
        }
    }
    private func bgSwatch(_ b: StickerBackground) -> some View {
        ZStack {
            Circle().fill(b.swatch).frame(width: 44, height: 44)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 1))
            if b == .none { Image(systemName: "nosign").foregroundStyle(.secondary) }
        }
    }

    // MARK: - Actions bar

    private var actions: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button { share() } label: { Label("Share", systemImage: "square.and.arrow.up") }
                    .buttonStyle(GlassActionButtonStyle(tint: Color(.secondarySystemBackground)))
                Button { addToLibrary() } label: {
                    Label(savedToLibrary ? "Added" : "Add to Stickers", systemImage: savedToLibrary ? "checkmark" : "plus")
                }.buttonStyle(GlassActionButtonStyle())
                .disabled(savedToLibrary)
            }
            Text(quotaHint).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .background(Color(.secondarySystemBackground).opacity(0.5))
    }

    private var quotaHint: String {
        if store.isPro { return "Unlimited creates. Add it to your Peel keyboard or share anywhere." }
        let credits = quota.creditBalance
        if let left = quota.freeRemaining(isPro: false) {
            if left > 0 { return "Free: \(left) of \(DailyQuota.freeDailyLimit) creates left today\(credits > 0 ? " · \(credits) credits" : "")." }
            if credits > 0 { return "Daily free creates used — this one spends 1 of \(credits) credits." }
            return "You've used today's 3 free creates. Get more to keep going."
        }
        return ""
    }

    @ViewBuilder private var toastView: some View {
        if let toast {
            Text(toast).font(.subheadline.weight(.semibold))
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(.ultraThinMaterial, in: Capsule())
                .foregroundStyle(.primary).padding(.bottom, 150)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// Shown when the editor opens with no creation budget — a calm early sheet, not a share-button trap.
    private var quotaBlock: some View {
        ZStack {
            Color(.systemBackground).opacity(0.92).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "sparkles").font(.system(size: 44)).foregroundStyle(Color.accentColor)
                Text("You've used today's 3 free creates")
                    .font(.title3.bold()).multilineTextAlignment(.center)
                Text("Get Sticker Credits or go unlimited to keep making stickers. You can still browse and tweak — credits are only spent when you save or share.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button { showPaywall = true } label: {
                    Label("Get more", systemImage: "plus.circle.fill").frame(maxWidth: .infinity)
                }.buttonStyle(GlassActionButtonStyle())
                Button("Keep editing") { blockedByQuota = false }
                    .buttonStyle(GlassActionButtonStyle(tint: Color(.secondarySystemBackground)))
            }
            .padding(28)
        }
    }

    // MARK: - Selected-layer access

    private var selIndex: Int { edit.layers.firstIndex { $0.id == selectedLayerID } ?? 0 }
    private var hasSel: Bool { edit.layers.indices.contains(selIndex) }

    /// The selected layer's look (falls back to a default when, briefly, there's no selection).
    private var look: LayerLook { hasSel ? edit.layers[selIndex].look : LayerLook() }

    // MARK: - Bindings (selected layer's look / transform / text), bracketed into history

    private func lookBinding(_ kp: WritableKeyPath<LayerLook, Double>) -> Binding<Double> {
        Binding(
            get: { hasSel ? edit.layers[selIndex].look[keyPath: kp] : 0 },
            set: { v in if hasSel { edit.layers[selIndex].look[keyPath: kp] = v } })
    }
    private func lookColorBinding(_ kp: WritableKeyPath<LayerLook, RGBAColor>) -> Binding<Color> {
        Binding(
            get: { hasSel ? edit.layers[selIndex].look[keyPath: kp].color : .clear },
            set: { c in mutate(tag: nil) { e in if e.layers.indices.contains(selIndex) { e.layers[selIndex].look[keyPath: kp] = RGBAColor(c) } } })
    }
    private func editColorBinding(_ kp: WritableKeyPath<StickerEdit, RGBAColor>) -> Binding<Color> {
        Binding(get: { edit[keyPath: kp].color },
                set: { c in mutate(tag: nil) { $0[keyPath: kp] = RGBAColor(c) } })
    }
    private var outlineColorBinding: Binding<Color> {
        Binding(
            get: { look.outlineColor?.color ?? .white },
            set: { c in mutate(tag: nil) { e in
                guard e.layers.indices.contains(selIndex) else { return }
                e.layers[selIndex].look.outlineColor = RGBAColor(c)
                let o = e.layers[selIndex].look.outline
                if o != .glow && o != .dashed && o != .custom { e.layers[selIndex].look.outline = .custom }
            } })
    }
    private var textStringBinding: Binding<String> {
        Binding(get: { look.text.string },
                set: { s in if hasSel { edit.layers[selIndex].look.text.string = s } })
    }
    private var textColorBinding: Binding<Color> {
        Binding(get: { look.text.color.color },
                set: { c in mutate(tag: nil) { e in if e.layers.indices.contains(selIndex) { e.layers[selIndex].look.text.color = RGBAColor(c) } } })
    }
    private var textPositionBinding: Binding<TextPosition> {
        Binding(get: { look.text.position },
                set: { p in mutate(tag: nil) { e in if e.layers.indices.contains(selIndex) { e.layers[selIndex].look.text.position = p } } })
    }
    private func textToggleBinding(_ kp: WritableKeyPath<StickerText, Bool>) -> Binding<Bool> {
        Binding(get: { look.text[keyPath: kp] },
                set: { v in mutate(tag: nil) { e in if e.layers.indices.contains(selIndex) { e.layers[selIndex].look.text[keyPath: kp] = v } } })
    }

    // MARK: - Per-layer (opacity / blend) bindings

    private var layerOpacityBinding: Binding<Double> {
        Binding(get: { hasSel ? edit.layers[selIndex].opacity : 1 },
                set: { v in if hasSel { edit.layers[selIndex].opacity = v } })
    }
    private var selectedBlend: LayerBlendMode { hasSel ? edit.layers[selIndex].blend : .normal }
    private func setSelectedBlend(_ m: LayerBlendMode) {
        mutate(tag: nil) { e in if e.layers.indices.contains(selIndex) { e.layers[selIndex].blend = m } }
    }

    // MARK: - Mutation helpers (history-bracketed)

    /// Apply an atomic edit and record it as one undo step. Composite re-renders via `onChange`.
    private func mutate(tag: String?, _ change: (inout StickerEdit) -> Void) {
        let before = edit
        var e = edit
        change(&e)
        edit = e
        history.record(before: before, after: e, tag: tag)
    }

    /// Curried setter for a look field driven by a chip pick: `setLook { $0.outline = $1 }(value)`.
    private func setLook<V>(tag: String?, _ apply: @escaping (inout LayerLook, V) -> Void) -> (V) -> Void {
        { value in
            mutate(tag: tag) { e in
                guard e.layers.indices.contains(selIndex) else { return }
                apply(&e.layers[selIndex].look, value)
            }
        }
    }

    private func toggle(_ kp: WritableKeyPath<StickerLayer, Bool>, _ id: UUID, _ e: inout StickerEdit) {
        if let i = e.layers.firstIndex(where: { $0.id == id }) { e.layers[i][keyPath: kp].toggle() }
    }

    /// Bracket a continuous slider drag into ONE history step and defer the heavy composite to release.
    private func editingChanged(_ editing: Bool, tag: String) {
        if editing { history.begin(from: edit) }
        else { history.commit(edit, tag: tag); scheduleRender() }
    }

    // MARK: - Layer ops

    private func deleteLayer(_ id: UUID) {
        guard edit.layers.count > 1 else { return }
        mutate(tag: nil) { e in
            e.layers.removeAll { $0.id == id }
        }
        if selectedLayerID == id { selectedLayerID = edit.layers.first?.id }
        Haptics.pop()
    }

    private func rotateSelectedQuarter() {
        mutate(tag: nil) { e in
            guard e.layers.indices.contains(selIndex) else { return }
            e.layers[selIndex].transform.rotationQuarters = (e.layers[selIndex].transform.rotationQuarters + 1) % 4
        }
    }
    private func toggleSelectedFlipH() {
        mutate(tag: nil) { e in
            guard e.layers.indices.contains(selIndex) else { return }
            e.layers[selIndex].transform.flipH.toggle()
        }
    }
    private func toggleSelectedFlipV() {
        mutate(tag: nil) { e in
            guard e.layers.indices.contains(selIndex) else { return }
            e.layers[selIndex].transform.flipV.toggle()
        }
    }

    /// Duplicate the selected layer — a fresh id, nudged so it doesn't sit exactly on top. Selects the copy.
    private func duplicateSelected() {
        guard hasSel else { return }
        var copy = edit.layers[selIndex]
        copy.id = UUID()
        copy.transform.center.x = min(copy.transform.center.x + 0.06, 1.05)
        copy.transform.center.y = min(copy.transform.center.y + 0.06, 1.05)
        let insertAt = selIndex + 1
        mutate(tag: nil) { e in e.layers.insert(copy, at: min(insertAt, e.layers.count)) }
        selectedLayerID = copy.id
        Haptics.success(); flash("Layer duplicated")
    }

    /// Crop / trim the selected layer's cutout to its content bounds (drops empty transparent margins).
    /// One undo step. No-op when the cutout is already tight or the layer has no pixels.
    private func cropSelectedToBounds() {
        guard hasSel, edit.layers[selIndex].type != .text else { return }
        let cutout = edit.layers[selIndex].cutout
        guard let trimmed = cutout.trimmedToAlpha(padFraction: 0.01),
              trimmed.size != cutout.size else { Haptics.tap(); flash("Already trimmed"); return }
        mutate(tag: nil) { e in
            guard e.layers.indices.contains(selIndex) else { return }
            e.layers[selIndex].cutout = trimmed
        }
        Haptics.success(); flash("Cropped to subject")
    }

    /// Apply a one-tap effect preset to the SELECTED layer's look (one undo step).
    private func applyEffectPreset(_ p: EffectPreset) {
        guard hasSel else { return }
        mutate(tag: nil) { e in
            guard e.layers.indices.contains(selIndex) else { return }
            p.apply(to: &e.layers[selIndex].look)
        }
        Haptics.success(); flash("\(p.title) applied")
    }

    // MARK: - New content layers (emoji / shape / photo)

    /// Add the typed emoji as its own movable/resizable/rotatable layer (rendered to pixels on-device).
    private func addEmojiLayer() {
        let glyph = emojiText.trimmingCharacters(in: .whitespacesAndNewlines)
        emojiText = ""
        guard !glyph.isEmpty else { return }
        let img = LayerFactory.emoji(glyph)
        var layer = StickerLayer(cutout: img, type: .emoji)
        layer.look.outline = .none      // emoji shouldn't get a default white rim
        layer.transform.center = CGPoint(x: 0.5, y: 0.42)
        layer.transform.scale = 0.55
        mutate(tag: nil) { $0.layers.append(layer) }
        selectedLayerID = layer.id
        Haptics.success(); flash("Emoji added — drag to place it")
    }

    /// Add a filled shape layer (uses the design accent as the default fill; recolor via Adjust/Outline).
    private func addShapeLayer(_ kind: ShapeKind) {
        let img = LayerFactory.shape(kind, color: UIColor(Brand.accent))
        var layer = StickerLayer(cutout: img, type: .shape)
        layer.look.outline = .none
        layer.transform.center = CGPoint(x: 0.5, y: 0.5)
        layer.transform.scale = 0.6
        mutate(tag: nil) { $0.layers.append(layer) }
        selectedLayerID = layer.id
        Haptics.success(); flash("\(kind.title) added — recolor it in Adjust")
    }

    /// Add a raw photo from the library as an image layer (NOT a cutout — the whole picture is placed).
    private func loadPhotoLayer(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        await MainActor.run { addingPhotoLayer = true }
        defer { Task { @MainActor in addingPhotoLayer = false; photoLayerPick = nil } }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            await MainActor.run { Haptics.warn(); flash("Couldn't load that photo") }
            return
        }
        await MainActor.run {
            var layer = StickerLayer(cutout: image.cappedToLongestSide(1400), type: .photo)
            layer.look.outline = .none
            layer.transform.center = CGPoint(x: 0.5, y: 0.5)
            layer.transform.scale = 0.75
            mutate(tag: nil) { $0.layers.append(layer) }
            selectedLayerID = layer.id
            Haptics.success(); flash("Photo added — drag to place it")
        }
    }

    // MARK: - Doodle (freehand brush) cover

    @ViewBuilder private var drawCover: some View {
        DrawingCanvasView(
            existing: hasSel && edit.layers[selIndex].type == .drawing ? edit.layers[selIndex].cutout : nil,
            onDone: { image in commitDrawing(image); showDraw = false },
            onCancel: { showDraw = false })
    }

    /// Install a finished doodle. If the selected layer is already a drawing, replace its pixels (so the
    /// doodle tool re-opens the same scribble); otherwise add a fresh full-canvas drawing layer on top.
    private func commitDrawing(_ image: UIImage?) {
        guard let image, let trimmed = image.trimmedToAlpha(padFraction: 0.04) else { return }
        if hasSel, edit.layers[selIndex].type == .drawing {
            mutate(tag: nil) { e in
                guard e.layers.indices.contains(selIndex) else { return }
                e.layers[selIndex].cutout = trimmed
            }
        } else {
            var layer = StickerLayer(cutout: trimmed, type: .drawing)
            layer.look.outline = .none
            layer.transform.center = CGPoint(x: 0.5, y: 0.5)
            layer.transform.scale = 0.9
            mutate(tag: nil) { $0.layers.append(layer) }
            selectedLayerID = layer.id
        }
        Haptics.success(); flash("Doodle added")
    }

    /// Share items for the system share sheet: the transparent PNG written to a temp file so receiving
    /// apps (WhatsApp, Instagram, Telegram, Messages, Mail…) get a real image FILE with the .png extension,
    /// which keeps transparency and is accepted everywhere — plus the in-memory UIImage as a fallback.
    private func shareItems(_ image: UIImage) -> [Any] {
        if let url = SharePNG.write(image) { return [url] }
        return [image]
    }

    // MARK: - History apply

    private func applyUndo() {
        guard let e = history.undo() else { return }
        edit = e
        if selectedLayerID == nil || !e.layers.contains(where: { $0.id == selectedLayerID }) {
            selectedLayerID = e.layers.first?.id
        }
        scheduleRender()
    }
    private func applyRedo() {
        guard let e = history.redo() else { return }
        edit = e
        if selectedLayerID == nil || !e.layers.contains(where: { $0.id == selectedLayerID }) {
            selectedLayerID = e.layers.first?.id
        }
        scheduleRender()
    }

    private func autoEdit() {
        guard let primary = edit.primary?.cutout else { return }
        mutate(tag: nil) { e in AutoEdit.enhance(&e, primary: primary) }
        Haptics.success(); flash("Auto-Edit applied")
    }

    // MARK: - Rendering

    private func scheduleRender() {
        renderTask?.cancel()
        let e = edit
        let orig = original
        let side = previewCanvas
        renderTask = Task.detached(priority: .userInitiated) {
            try? await Task.sleep(nanoseconds: 28_000_000)
            if Task.isCancelled { return }
            let img = StickerRenderer.render(edit: e, canvasLongSide: side, original: orig)
            if Task.isCancelled { return }
            await MainActor.run { withAnimation(.easeInOut(duration: 0.15)) { rendered = img } }
        }
    }

    private func exportAsync(_ done: @escaping (UIImage) -> Void) {
        withAnimation(.easeInOut(duration: 0.15)) { exporting = true }
        let e = edit, orig = original, side = exportCanvas
        Task.detached(priority: .userInitiated) {
            let img = StickerRenderer.renderForExport(edit: e, canvasLongSide: side, original: orig)
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.15)) { exporting = false }
                done(img)
            }
        }
    }

    // MARK: - Quota (checked at editor-OPEN, never at share)

    /// Per the fairness rules, the quota is checked when the editor OPENS (creation START). If the user
    /// has no free creates and no credits, a calm early sheet appears — they can still browse/tweak, and
    /// a sticker they DO finish always saves/sends (the slot is consumed once, at save/share).
    private func ensureQuotaAtOpen() {
        // Re-editing an already-saved sticker is always allowed to OPEN; a create slot is only checked
        // when saving the edited result as a new sticker (handled in addToLibrary/share).
        guard !store.isPro, !consumedQuota, !isReedit else { return }
        if !quota.canCreate(isPro: false) { blockedByQuota = true }
    }

    private func consumeQuota() {
        if !store.isPro && !consumedQuota {
            quota.recordCreated(isPro: false)
            consumedQuota = true
        }
    }

    /// After the paywall closes, re-sync the published credit balance (credits bought in the paywall land
    /// in the App Group but the `DailyQuota` publisher needs a nudge) and lift the quota block if the user
    /// now has budget — so a fresh credit purchase immediately reopens editing.
    private func reconcileQuotaAfterPurchase() {
        quota.refresh()
        if store.isPro || quota.canCreate(isPro: store.isPro) {
            blockedByQuota = false
        }
    }

    private func share() {
        // Closed the fail-open leak: a sticker started with NO budget (0 free + 0 credits, reached via
        // "Keep editing") can't be saved/shared free. A legitimately-budgeted sticker still always saves.
        guard store.isPro || consumedQuota || quota.canCreate(isPro: false) else { showPaywall = true; return }
        exportAsync { img in consumeQuota(); shareImage = img; showShare = true }
    }

    private func addToLibrary() {
        guard store.isPro || consumedQuota || quota.canCreate(isPro: false) else { showPaywall = true; return }
        exportAsync { img in
            switch stickers.add(img, edit: edit, templateID: templateID) {
            case .added:
                consumeQuota()
                Haptics.success(); savedToLibrary = true; flash("Added — now in your Peel keyboard")
            case .failed:
                Haptics.warn(); flash("Couldn't add that sticker")
            }
        }
    }

    // MARK: - Second subject

    private func loadSecond(_ item: PhotosPickerItem?) async {
        // Adding another subject layer is an EDITING tool — free for everyone, no Pro gate.
        guard let item else { return }
        await MainActor.run { withAnimation(.easeInOut(duration: 0.15)) { liftingSecond = true } }
        defer { Task { @MainActor in withAnimation(.easeInOut(duration: 0.15)) { liftingSecond = false }; secondPick = nil } }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { return }
        do {
            let cut = try await SubjectLift.cutout(from: image)
            await MainActor.run {
                var layer = StickerLayer(cutout: cut.cappedToLongestSide(1400))
                layer.transform.center = CGPoint(x: 0.62, y: 0.45)
                layer.transform.scale = 0.9
                mutate(tag: nil) { $0.layers.append(layer) }
                selectedLayerID = layer.id
                Haptics.success(); flash("Second subject added — drag to place it")
            }
        } catch {
            await MainActor.run { Haptics.warn(); flash("Couldn't find a subject in that photo") }
        }
    }

    // MARK: - Filter thumbs (rendered against the user's CURRENT edit, not a clean cutout)

    private func buildFilterThumbs() async {
        guard let primary = edit.primary?.cutout else { return }
        let thumbCut = primary.cappedToLongestSide(120)
        let baseLook = look
        let map = await Task.detached(priority: .utility) { () -> [PhotoFilter: UIImage] in
            var m: [PhotoFilter: UIImage] = [:]
            for f in PhotoFilter.allCases {
                var e = StickerEdit()
                var l = baseLook         // start from the current look so the thumb reflects real settings
                l.filter = f
                l.outline = .none
                var layer = StickerLayer(cutout: thumbCut)
                layer.look = l
                e.layers = [layer]
                m[f] = StickerRenderer.render(cutout: thumbCut, edit: e)
            }
            return m
        }.value
        filterThumbs = map
    }

    /// Build the small effect-preset thumbnails (each preset applied to the user's current subject).
    private func buildEffectThumbs() async {
        guard let primary = edit.primary?.cutout else { return }
        let thumbCut = primary.cappedToLongestSide(120)
        let map = await Task.detached(priority: .utility) { () -> [EffectPreset: UIImage] in
            var m: [EffectPreset: UIImage] = [:]
            for p in EffectPreset.allCases {
                var e = StickerEdit()
                var layer = StickerLayer(cutout: thumbCut)
                p.apply(to: &layer.look)
                layer.look.outline = .none
                e.layers = [layer]
                m[p] = StickerRenderer.render(cutout: thumbCut, edit: e)
            }
            return m
        }.value
        effectThumbs = map
    }

    private func flash(_ message: String) {
        withAnimation { toast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation { toast = nil } }
    }
}

/// The real per-layer hit-testing canvas (Stage 3's hard subsystem).
///
/// IDLE: shows the full Core Image `rendered` composite — sharp, with every look applied.
/// SELECTED (no gesture): overlays a bounding box + rotate/scale handles on the selected layer.
/// GESTURE: hides the dragged layer in the composite (`liveLayerID`), shows it as a lightweight `Image`
/// transformed live in SwiftUI (no Core Image per frame), with snap guides; on release the editor commits
/// the transform to history and runs ONE heavy composite.
///
/// Geometry mirrors `StickerRenderer.place()`: a layer's on-screen subject size is
/// `displaySide * fill * margin * transform.scale`, centered at `transform.center` in display points, so
/// the lightweight overlay lines up with the composite it replaces.
private struct LiveCanvasView: View {
    @Binding var edit: StickerEdit
    let rendered: UIImage
    @Binding var selectedLayerID: UUID?
    @Binding var liveLayerID: UUID?
    let isDual: Bool
    var onGestureBegin: () -> Void
    var onGestureEnd: (_ tag: String?) -> Void

    // Gesture start snapshots (so a drag/scale/rotate runs from a fixed origin).
    @State private var startCenter: CGPoint?
    @State private var startScale: CGFloat?
    @State private var startRotation: CGFloat?
    @State private var gestureBegun = false
    @State private var snapX = false
    @State private var snapY = false

    private var selIndex: Int { edit.layers.firstIndex { $0.id == selectedLayerID } ?? -1 }
    private var hasSel: Bool { edit.layers.indices.contains(selIndex) }

    /// `fill` matches the renderer: 0.55 for dual, 0.82 single.
    private var fill: CGFloat { isDual ? 0.55 : 0.82 }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let canvasOrigin = CGPoint(x: (geo.size.width - side) / 2, y: (geo.size.height - side) / 2)

            ZStack {
                // Base composite. During a live gesture the dragged layer is hidden here and shown
                // lightweight on top, so there's no per-frame Core Image cost.
                Image(uiImage: rendered)
                    .resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(liveLayerID == nil ? 1 : 0.0001)   // keep it laid out; hide while dragging

                // Live lightweight overlay for the layer being manipulated.
                if liveLayerID != nil, hasSel {
                    liveLayer(side: side, origin: canvasOrigin)
                }

                // Snap guides (center cross) while a drag is snapping.
                if liveLayerID != nil {
                    snapGuides(side: side, origin: canvasOrigin)
                }

                // Selection chrome (bounding box + handles) on the selected layer when idle.
                if hasSel, !edit.layers[selIndex].isHidden {
                    selectionChrome(side: side, origin: canvasOrigin)
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(side: side, origin: canvasOrigin))
            .simultaneousGesture(magnifyGesture)
            .simultaneousGesture(rotateGesture)
            .onTapGesture { location in handleTap(location, side: side, origin: canvasOrigin) }
        }
    }

    // MARK: - On-screen frame math (mirrors renderer.place())

    /// The subject's on-screen size (longest side, in points) for a layer at a given scale.
    private func subjectScreenLongest(_ layer: StickerLayer, side: CGFloat) -> CGFloat {
        side * fill * marginFactor() * layer.transform.scale
    }
    private func marginFactor() -> CGFloat {
        edit.background != .none ? (1.0 - CGFloat(edit.bgPadding) * 0.4) : 1.0
    }
    /// The on-screen rect (axis-aligned, pre-rotation) of a layer's subject.
    private func subjectRect(_ layer: StickerLayer, side: CGFloat, origin: CGPoint) -> CGRect {
        let img = layer.cutout.size
        let longest = max(img.width, img.height)
        guard longest > 0 else { return .zero }
        let scale = subjectScreenLongest(layer, side: side) / longest
        let w = img.width * scale, h = img.height * scale
        let cx = origin.x + side * layer.transform.center.x
        let cy = origin.y + side * layer.transform.center.y
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }
    private func center(_ layer: StickerLayer, side: CGFloat, origin: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + side * layer.transform.center.x,
                y: origin.y + side * layer.transform.center.y)
    }

    // MARK: - Live layer view

    private func liveLayer(side: CGFloat, origin: CGPoint) -> some View {
        let layer = edit.layers[selIndex]
        let rect = subjectRect(layer, side: side, origin: origin)
        return Image(uiImage: layer.cutout)
            .resizable().scaledToFit()
            .frame(width: rect.width, height: rect.height)
            .scaleEffect(x: layer.transform.flipH ? -1 : 1, y: layer.transform.flipV ? -1 : 1)
            .rotationEffect(.radians(quarterRadians(layer) + Double(layer.transform.rotation)))
            .position(center(layer, side: side, origin: origin))
            .opacity(layer.opacity)
            .allowsHitTesting(false)
    }
    private func quarterRadians(_ layer: StickerLayer) -> Double {
        Double(layer.transform.rotationQuarters % 4) * (.pi / 2)
    }

    // MARK: - Selection chrome

    private func selectionChrome(side: CGFloat, origin: CGPoint) -> some View {
        let layer = edit.layers[selIndex]
        let rect = subjectRect(layer, side: side, origin: origin)
        let angle = quarterRadians(layer) + Double(layer.transform.rotation)
        let pad: CGFloat = 8
        let w = rect.width + pad * 2, h = rect.height + pad * 2
        // Handles sit at the four corners of the chrome frame; `.position` is in the frame's own
        // coordinate space (0…w, 0…h), so the corners are (0,0), (w,0), (0,h), (w,h).
        return ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            handle().position(x: 0, y: 0)                                            // top-left
            handle().position(x: w, y: 0)                                            // top-right
            handle().position(x: 0, y: h)                                            // bottom-left
            handle(icon: "arrow.up.left.and.arrow.down.right").position(x: w, y: h)  // bottom-right = scale hint
        }
        .frame(width: w, height: h)
        .rotationEffect(.radians(angle))
        .position(center(layer, side: side, origin: origin))
        .allowsHitTesting(false)
        .opacity(liveLayerID == nil ? 1 : 0.5)
    }
    private func handle(icon: String? = nil) -> some View {
        ZStack {
            Circle().fill(Color(.systemBackground))
            Circle().strokeBorder(Color.accentColor, lineWidth: 1.5)
            if let icon { Image(systemName: icon).font(.system(size: 8, weight: .bold)).foregroundStyle(Color.accentColor) }
        }
        .frame(width: 16, height: 16)
    }

    // MARK: - Snap guides

    @ViewBuilder private func snapGuides(side: CGFloat, origin: CGPoint) -> some View {
        ZStack {
            if snapX {
                Rectangle().fill(Color.accentColor.opacity(0.6)).frame(width: 1, height: side)
                    .position(x: origin.x + side / 2, y: origin.y + side / 2)
            }
            if snapY {
                Rectangle().fill(Color.accentColor.opacity(0.6)).frame(width: side, height: 1)
                    .position(x: origin.x + side / 2, y: origin.y + side / 2)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Hit testing

    /// Tap selects the topmost (last-drawn) NON-hidden, NON-locked layer under the point. A tap on empty
    /// canvas keeps the current selection (so chrome doesn't flicker off mid-edit).
    private func handleTap(_ location: CGPoint, side: CGFloat, origin: CGPoint) {
        for layer in edit.layers.reversed() where !layer.isHidden {
            if hitTest(layer, location: location, side: side, origin: origin) {
                if selectedLayerID != layer.id { selectedLayerID = layer.id; Haptics.tap() }
                return
            }
        }
    }
    /// Point-in-(rotated)-rect test against the layer's subject rect.
    private func hitTest(_ layer: StickerLayer, location: CGPoint, side: CGFloat, origin: CGPoint) -> Bool {
        let rect = subjectRect(layer, side: side, origin: origin)
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let angle = quarterRadians(layer) + Double(layer.transform.rotation)
        // rotate the point into the rect's local (unrotated) frame
        let dx = location.x - c.x, dy = location.y - c.y
        let cos = CGFloat(Foundation.cos(-angle)), sin = CGFloat(Foundation.sin(-angle))
        let lx = dx * cos - dy * sin, ly = dx * sin + dy * cos
        let tol: CGFloat = 12   // generous so thin subjects are still grabbable
        return abs(lx) <= rect.width / 2 + tol && abs(ly) <= rect.height / 2 + tol
    }

    // MARK: - Gestures (operate on the SELECTED layer; lightweight while live)

    private func dragGesture(side: CGFloat, origin: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { v in
                // Select what's under the finger on the first move, then drag it.
                if startCenter == nil {
                    selectUnder(v.startLocation, side: side, origin: origin)
                    guard hasSel, !edit.layers[selIndex].isLocked else { return }
                    beginLive()
                    startCenter = edit.layers[selIndex].transform.center
                }
                guard hasSel, side > 0, let s = startCenter else { return }
                var nx = s.x + v.translation.width / side
                var ny = s.y + v.translation.height / side
                // snap to canvas center within a small threshold
                let thresh: CGFloat = 0.018
                snapX = abs(nx - 0.5) < thresh
                snapY = abs(ny - 0.5) < thresh
                if snapX { nx = 0.5 }
                if snapY { ny = 0.5 }
                edit.layers[selIndex].transform.center = CGPoint(x: min(max(nx, -0.1), 1.1),
                                                                 y: min(max(ny, -0.1), 1.1))
            }
            .onEnded { _ in
                startCenter = nil; snapX = false; snapY = false
                endLive(tag: "drag")
            }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { v in
                guard hasSel, !edit.layers[selIndex].isLocked else { return }
                if startScale == nil { beginLive(); startScale = edit.layers[selIndex].transform.scale }
                edit.layers[selIndex].transform.scale = min(max((startScale ?? 1) * v.magnification, 0.2), 4)
            }
            .onEnded { _ in startScale = nil; endLive(tag: "scale") }
    }

    private var rotateGesture: some Gesture {
        RotateGesture()
            .onChanged { v in
                guard hasSel, !edit.layers[selIndex].isLocked else { return }
                if startRotation == nil { beginLive(); startRotation = edit.layers[selIndex].transform.rotation }
                edit.layers[selIndex].transform.rotation = (startRotation ?? 0) + CGFloat(v.rotation.radians)
            }
            .onEnded { _ in startRotation = nil; endLive(tag: "rotate") }
    }

    private func selectUnder(_ location: CGPoint, side: CGFloat, origin: CGPoint) {
        for layer in edit.layers.reversed() where !layer.isHidden {
            if hitTest(layer, location: location, side: side, origin: origin) {
                selectedLayerID = layer.id
                return
            }
        }
    }

    private func beginLive() {
        guard !gestureBegun else { liveLayerID = selectedLayerID; return }
        gestureBegun = true
        onGestureBegin()
        liveLayerID = selectedLayerID
    }
    private func endLive(tag: String) {
        guard gestureBegun, startCenter == nil, startScale == nil, startRotation == nil else { return }
        gestureBegun = false
        onGestureEnd(tag)
    }
}
