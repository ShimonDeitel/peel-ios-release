import SwiftUI
import CoreImage

/// A codable RGBA color so user-chosen STICKER colors persist and convert cleanly between
/// SwiftUI / UIKit / Core Image. (App chrome stays mono + Apple blue; these colors are the user's
/// sticker CONTENT, which is allowed to be colorful.)
struct RGBAColor: Equatable, Codable {
    var r: Double, g: Double, b: Double, a: Double

    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }

    init(_ color: Color) {
        let ui = UIColor(color)
        var rr: CGFloat = 0, gg: CGFloat = 0, bb: CGFloat = 0, aa: CGFloat = 0
        ui.getRed(&rr, green: &gg, blue: &bb, alpha: &aa)
        r = Double(rr); g = Double(gg); b = Double(bb); a = Double(aa)
    }

    var color: Color { Color(red: r, green: g, blue: b).opacity(a) }
    var ui: UIColor { UIColor(red: r, green: g, blue: b, alpha: a) }
    var ci: CIColor { CIColor(red: r, green: g, blue: b, alpha: a) }
    var value: Double { max(r, max(g, b)) }

    static let white = RGBAColor(1, 1, 1)
    static let black = RGBAColor(0, 0, 0)
}

/// Where a layer sits on the fixed editor canvas. Stored in NORMALIZED canvas units so the reduced
/// live-preview and the full-resolution export share identical transforms.
struct LayerTransform: Equatable, Codable {
    var center = CGPoint(x: 0.5, y: 0.5)   // 0...1, top-left origin (SwiftUI convention)
    var scale: CGFloat = 1.0               // multiplies the fit-scale
    var rotation: CGFloat = 0              // radians
    var rotationQuarters: Int = 0          // 0..3 ninety-degree steps
    var flipH = false
    var flipV = false
}

/// What a layer represents on the stack. `subject` is a lifted cutout; `text` carries a StickerText
/// drawn directly (no cutout pixels); `shape` is a solid/decorative fill; `emoji` is an emoji glyph
/// rendered to pixels; `drawing` is a freehand doodle layer; `photo` is a raw photo (no cutout).
/// All of `subject`/`emoji`/`drawing`/`photo`/`shape` carry pixels in `cutout`, so the renderer treats
/// them identically (adjust → filter → outline → place). `text` is the only pixel-less type.
enum LayerType: String, Codable, Equatable {
    case subject, text, shape, emoji, drawing, photo
}

/// The decorative shape a `.shape` layer draws (filled, with the look's fill color). All FREE.
enum ShapeKind: String, CaseIterable, Identifiable, Codable {
    case circle, roundedRect, star, heart, triangle
    var id: String { rawValue }
    var title: String {
        switch self {
        case .circle: return "Circle"
        case .roundedRect: return "Rounded"
        case .star: return "Star"
        case .heart: return "Heart"
        case .triangle: return "Triangle"
        }
    }
    var symbol: String {
        switch self {
        case .circle: return "circle.fill"
        case .roundedRect: return "square.fill"
        case .star: return "star.fill"
        case .heart: return "heart.fill"
        case .triangle: return "triangle.fill"
        }
    }
}

/// How a layer blends onto the layers beneath it (a small curated, on-device-cheap subset). All FREE.
enum LayerBlendMode: String, CaseIterable, Identifiable, Codable {
    case normal, multiply, screen, overlay, lighten, darken
    var id: String { rawValue }
    var title: String {
        switch self {
        case .normal: return "Normal"
        case .multiply: return "Multiply"
        case .screen: return "Screen"
        case .overlay: return "Overlay"
        case .lighten: return "Lighten"
        case .darken: return "Darken"
        }
    }
}

/// The per-layer "look": every adjust / filter / outline / glow / shadow / feather / text setting that
/// used to live globally on StickerEdit now rides on the layer, so two subjects can be styled
/// independently. The renderer reads these off each layer (composite() already loops per layer).
struct LayerLook: Equatable, Codable {
    // Adjustments
    var brightness: Double = 0      // -0.4 ... 0.4
    var contrast: Double = 1.0      // 0.6 ... 1.5
    var saturation: Double = 1.0    // 0 ... 2
    var warmth: Double = 0          // -1 ... 1
    var tint: Double = 0            // -1 ... 1
    var vibrance: Double = 0        // -1 ... 1
    var exposure: Double = 0        // -2 ... 2 EV
    var highlights: Double = 1.0    // 0.3 ... 1 (lower recovers)
    var shadows: Double = 0         // 0 ... 1 (raise lifts)
    var hue: Double = 0             // -pi ... pi
    var sharpness: Double = 0       // 0 ... 1
    var vignette: Double = 0        // 0 ... 1.5
    var grain: Double = 0           // 0 ... 0.5

    // Outline / glow / shadow
    var outline: OutlineStyle = .white
    var outlineColor: RGBAColor? = nil      // nil = style default
    var outlineWidth: Double = 0.5          // 0...1 -> longest*(0.02...0.10)
    var glowColor: RGBAColor = RGBAColor(0.45, 0.55, 1.0)
    var glowRadius: Double = 0.5            // 0...1 -> longest*(0.04...0.18)
    var shadowOpacity: Double = 0           // 0 = off; styles add their own
    var shadowOffset: Double = 0.5          // 0...1 -> longest*(0...0.05)
    var shadowBlur: Double = 0.5            // 0...1 -> longest*(0...0.10)

    // Filter
    var filter: PhotoFilter = .none
    var filterStrength: Double = 1.0        // 0...1

    // Cutout edge
    var feather: Double = 0                 // 0...1 erode+soften the silhouette

    // Text carried by this layer (a `.text` layer renders it; subject layers may also caption).
    var text = StickerText()
}

/// One placed item on the canvas. The primary subject is `layers[0]`; additional layers (subjects,
/// text, shapes) stack on top in array order. Each carries its OWN `look`, so two subjects can be
/// styled differently while being positioned independently.
struct StickerLayer: Identifiable, Equatable {
    var id = UUID()
    var cutout: UIImage
    /// The ORIGINAL Vision lift this layer was built from — the ceiling the Cleanup tool resets back to.
    /// Captured at init (defaults to `cutout`) so manual mask refinement can always restore the untouched
    /// silhouette. Not part of equality, so reset alone doesn't pollute history beyond the cutout swap.
    var originalCutout: UIImage
    var transform = LayerTransform()
    var look = LayerLook()
    var type: LayerType = .subject

    // First-class layer stack controls (N layers — the 2-cap is lifted at the StickerEdit level).
    var opacity: Double = 1.0
    var isHidden: Bool = false
    var isLocked: Bool = false
    var zOrder: Int = 0
    /// How this layer composites onto the layers below it (per-layer blend mode). Default `.normal`.
    var blend: LayerBlendMode = .normal

    init(cutout: UIImage, type: LayerType = .subject) {
        self.cutout = cutout
        self.originalCutout = cutout
        self.type = type
    }

    static func == (a: StickerLayer, b: StickerLayer) -> Bool {
        a.id == b.id && a.transform == b.transform && a.look == b.look && a.type == b.type
            && a.opacity == b.opacity && a.isHidden == b.isHidden && a.isLocked == b.isLocked
            && a.zOrder == b.zOrder && a.blend == b.blend && a.cutout === b.cutout
    }
}

/// Re-openable projects: a layer persists its transform/look/type/stack-state and its cutout pixels
/// (PNG, alpha preserved). Decoding a sidecar reconstructs the exact editable StickerEdit.
extension StickerLayer: Codable {
    enum CodingKeys: String, CodingKey {
        case id, transform, look, type, opacity, isHidden, isLocked, zOrder, blend, cutoutPNG, originalPNG
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let png = try c.decode(Data.self, forKey: .cutoutPNG)
        self.cutout = UIImage(data: png) ?? UIImage()
        // The original lift is persisted only when cleanup diverged it from the cutout; otherwise the
        // cutout IS the original, so reset stays a no-op after reopen.
        if let opng = try c.decodeIfPresent(Data.self, forKey: .originalPNG), let oimg = UIImage(data: opng) {
            self.originalCutout = oimg
        } else {
            self.originalCutout = self.cutout
        }
        self.id = try c.decode(UUID.self, forKey: .id)
        self.transform = try c.decode(LayerTransform.self, forKey: .transform)
        self.look = try c.decode(LayerLook.self, forKey: .look)
        self.type = try c.decodeIfPresent(LayerType.self, forKey: .type) ?? .subject
        self.opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1.0
        self.isHidden = try c.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        self.isLocked = try c.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
        self.zOrder = try c.decodeIfPresent(Int.self, forKey: .zOrder) ?? 0
        self.blend = try c.decodeIfPresent(LayerBlendMode.self, forKey: .blend) ?? .normal
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(transform, forKey: .transform)
        try c.encode(look, forKey: .look)
        try c.encode(type, forKey: .type)
        try c.encode(opacity, forKey: .opacity)
        try c.encode(isHidden, forKey: .isHidden)
        try c.encode(isLocked, forKey: .isLocked)
        try c.encode(zOrder, forKey: .zOrder)
        try c.encode(blend, forKey: .blend)
        // PNG keeps the lifted alpha; falls back to a 1x1 clear pixel so encoding never throws.
        let png = cutout.pngData() ?? UIImage().pngData() ?? Data()
        try c.encode(png, forKey: .cutoutPNG)
        // Persist the original lift only if cleanup diverged it (keeps sidecars small for untouched layers).
        if originalCutout !== cutout, let opng = originalCutout.pngData() {
            try c.encode(opng, forKey: .originalPNG)
        }
    }
}

/// One-tap photo looks applied to the cutout's pixels (alpha preserved). All FREE.
enum PhotoFilter: String, CaseIterable, Identifiable, Codable {
    case none, vivid, warm, cool, noir, mono, sepia, fade, chrome, vintage,
         invert, posterize, comic, edges, dramatic, duotone, glitch
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "Original"
        case .vivid: return "Vivid"
        case .warm: return "Warm"
        case .cool: return "Cool"
        case .noir: return "Noir"
        case .mono: return "Mono"
        case .sepia: return "Sepia"
        case .fade: return "Fade"
        case .chrome: return "Chrome"
        case .vintage: return "Vintage"
        case .invert: return "Invert"
        case .posterize: return "Pop Art"
        case .comic: return "Comic"
        case .edges: return "Line Art"
        case .dramatic: return "Dramatic"
        case .duotone: return "Duotone"
        case .glitch: return "Glitch"
        }
    }
}

/// One-tap "effect" presets — each bundles a filter + a few adjustments into a single look, so a tap
/// restyles the whole subject (the way Instagram presets do). All FREE, applied to the SELECTED layer.
enum EffectPreset: String, CaseIterable, Identifiable {
    case pop, mono, vivid, vintage, cool, warmGlow, noir, dreamy
    var id: String { rawValue }
    var title: String {
        switch self {
        case .pop: return "Pop"
        case .mono: return "Mono"
        case .vivid: return "Vivid"
        case .vintage: return "Vintage"
        case .cool: return "Cool"
        case .warmGlow: return "Glow"
        case .noir: return "Noir"
        case .dreamy: return "Dreamy"
        }
    }
    var symbol: String {
        switch self {
        case .pop: return "burst.fill"
        case .mono: return "circle.lefthalf.filled"
        case .vivid: return "sun.max.fill"
        case .vintage: return "camera.filters"
        case .cool: return "snowflake"
        case .warmGlow: return "flame.fill"
        case .noir: return "moon.stars.fill"
        case .dreamy: return "sparkles"
        }
    }
    /// Apply this preset onto a layer look (resets the relevant fields, then sets the preset's values).
    func apply(to look: inout LayerLook) {
        // start from a clean adjustment slate so presets are predictable / re-tappable
        look.brightness = 0; look.contrast = 1; look.saturation = 1; look.warmth = 0; look.tint = 0
        look.vibrance = 0; look.exposure = 0; look.highlights = 1; look.shadows = 0; look.hue = 0
        look.vignette = 0; look.grain = 0; look.filter = .none; look.filterStrength = 1
        switch self {
        case .pop:
            look.filter = .vivid; look.saturation = 1.25; look.contrast = 1.12; look.vibrance = 0.4
        case .mono:
            look.filter = .mono; look.contrast = 1.1
        case .vivid:
            look.saturation = 1.4; look.vibrance = 0.6; look.contrast = 1.08; look.exposure = 0.2
        case .vintage:
            look.filter = .vintage; look.warmth = 0.35; look.vignette = 0.6; look.grain = 0.18; look.contrast = 0.95
        case .cool:
            look.filter = .cool; look.warmth = -0.4; look.saturation = 1.1; look.contrast = 1.05
        case .warmGlow:
            look.filter = .warm; look.warmth = 0.5; look.exposure = 0.25; look.highlights = 0.85; look.vibrance = 0.3
        case .noir:
            look.filter = .noir; look.contrast = 1.25; look.vignette = 0.8; look.shadows = 0.15
        case .dreamy:
            look.filter = .fade; look.exposure = 0.3; look.saturation = 0.85; look.highlights = 0.7; look.grain = 0.1
        }
    }
}

/// Optional fill behind the cutout — turns a die-cut sticker into a badge. All FREE.
enum StickerBackground: String, CaseIterable, Identifiable, Codable {
    case none, white, ink, sunset, ocean, candy, mint, gold, solid, gradient, dots, stripes, checker, blurred
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "None"
        case .white: return "White"
        case .ink: return "Ink"
        case .sunset: return "Sunset"
        case .ocean: return "Ocean"
        case .candy: return "Candy"
        case .mint: return "Mint"
        case .gold: return "Gold"
        case .solid: return "Color"
        case .gradient: return "Gradient"
        case .dots: return "Dots"
        case .stripes: return "Stripes"
        case .checker: return "Checker"
        case .blurred: return "Blur"
        }
    }
    /// Preset (top, bottom) gradient colors; equal = solid. nil for custom/pattern/none/blurred.
    var presetColors: (UIColor, UIColor)? {
        switch self {
        case .white:  return (.white, .white)
        case .ink:    return (UIColor(white: 0.10, alpha: 1), UIColor(white: 0.02, alpha: 1))
        case .sunset: return (UIColor(red: 1.0, green: 0.50, blue: 0.36, alpha: 1), UIColor(red: 0.95, green: 0.25, blue: 0.55, alpha: 1))
        case .ocean:  return (UIColor(red: 0.30, green: 0.62, blue: 1.0, alpha: 1), UIColor(red: 0.36, green: 0.30, blue: 0.92, alpha: 1))
        case .candy:  return (UIColor(red: 1.0, green: 0.45, blue: 0.72, alpha: 1), UIColor(red: 0.78, green: 0.40, blue: 1.0, alpha: 1))
        case .mint:   return (UIColor(red: 0.40, green: 0.92, blue: 0.74, alpha: 1), UIColor(red: 0.20, green: 0.75, blue: 0.78, alpha: 1))
        case .gold:   return (UIColor(red: 0.97, green: 0.88, blue: 0.62, alpha: 1), UIColor(red: 0.78, green: 0.60, blue: 0.34, alpha: 1))
        default:      return nil
        }
    }
    var swatch: Color {
        switch self {
        case .none: return .gray.opacity(0.3)
        case .solid, .gradient: return .blue
        case .dots, .stripes, .checker: return .gray
        case .blurred: return .gray.opacity(0.5)
        default: return Color(presetColors!.0)
        }
    }
}

enum TextPosition: String, CaseIterable, Codable { case top, middle, bottom }

/// One of a curated set of system fonts (no bundled/network fonts).
enum StickerFont: String, CaseIterable, Identifiable, Codable {
    case system, rounded, serif, mono, marker, chalk, futura, avenir, snell, impact,
         condensed, american, copperplate, bradley, party
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "System"
        case .rounded: return "Rounded"
        case .serif: return "Serif"
        case .mono: return "Mono"
        case .marker: return "Marker"
        case .chalk: return "Chalk"
        case .futura: return "Futura"
        case .avenir: return "Avenir"
        case .snell: return "Script"
        case .impact: return "Impact"
        case .condensed: return "Condensed"
        case .american: return "Western"
        case .copperplate: return "Copper"
        case .bradley: return "Hand"
        case .party: return "Party"
        }
    }
    func uiFont(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        switch self {
        case .system: return .systemFont(ofSize: size, weight: weight)
        case .rounded:
            let base = UIFont.systemFont(ofSize: size, weight: weight)
            if let d = base.fontDescriptor.withDesign(.rounded) { return UIFont(descriptor: d, size: size) }
            return base
        case .serif: return UIFont(name: "Georgia-Bold", size: size) ?? .systemFont(ofSize: size, weight: weight)
        case .mono: return UIFont(name: "Menlo-Bold", size: size) ?? .monospacedSystemFont(ofSize: size, weight: weight)
        case .marker: return UIFont(name: "MarkerFelt-Wide", size: size) ?? .systemFont(ofSize: size, weight: weight)
        case .chalk: return UIFont(name: "Chalkduster", size: size) ?? .systemFont(ofSize: size, weight: weight)
        case .futura: return UIFont(name: "Futura-Bold", size: size) ?? .systemFont(ofSize: size, weight: weight)
        case .avenir: return UIFont(name: "AvenirNext-Bold", size: size) ?? .systemFont(ofSize: size, weight: weight)
        case .snell: return UIFont(name: "SnellRoundhand-Bold", size: size) ?? .systemFont(ofSize: size, weight: weight)
        case .impact: return UIFont(name: "Impact", size: size) ?? .systemFont(ofSize: size, weight: .heavy)
        case .condensed:
            // Compressed/condensed system face for tall narrow captions.
            let base = UIFont.systemFont(ofSize: size, weight: .black)
            let d = base.fontDescriptor.withSymbolicTraits(.traitCondensed) ?? base.fontDescriptor
            return UIFont(descriptor: d, size: size)
        case .american: return UIFont(name: "AmericanTypewriter-Bold", size: size) ?? .systemFont(ofSize: size, weight: weight)
        case .copperplate: return UIFont(name: "Copperplate-Bold", size: size) ?? .systemFont(ofSize: size, weight: weight)
        case .bradley: return UIFont(name: "BradleyHandITCTT-Bold", size: size) ?? .systemFont(ofSize: size, weight: weight)
        case .party: return UIFont(name: "PartyLetPlain", size: size) ?? UIFont(name: "MarkerFelt-Wide", size: size) ?? .systemFont(ofSize: size, weight: weight)
        }
    }
}

/// A text overlay that sits on the sticker (meme-style).
struct StickerText: Equatable, Codable {
    var string: String = ""
    var color: RGBAColor = .white
    var strokeColor: RGBAColor? = nil          // nil = auto contrast
    var stroked: Bool = true
    var position: TextPosition = .bottom
    var font: StickerFont = .system
    var sizeFraction: Double = 0.13            // of image width
    var kern: Double = 0                       // 0...0.2 of font size
    var uppercase: Bool = true
    var shadowed: Bool = false
    /// Bend the caption along an arc. 0 = flat; >0 curves UP (smile); <0 curves DOWN (frown). The
    /// magnitude is the sweep as a fraction of a half-circle (-1...1). When curved, the text is drawn
    /// glyph-by-glyph around a circle instead of on a straight baseline.
    var curve: Double = 0                      // -1 ... 1

    var isCurved: Bool { abs(curve) > 0.02 }
    var isEmpty: Bool { string.trimmingCharacters(in: .whitespaces).isEmpty }
    var uiColor: UIColor { color.ui }
}

/// The full, editable state of a sticker — the "project". Per-layer LOOKS (adjust/filter/outline/
/// glow/shadow/feather/text) now live on each `StickerLayer.look`. The BACKGROUND stays a single global
/// fill behind the whole composite.
///
/// For source compatibility with the existing single-look editor + test harness, every look field is
/// exposed here as a computed bridge onto the *active look* (`layers[0].look`, or a stored fallback when
/// there are no layers). Writing `edit.brightness = …` mutates layer 0's look; the renderer reads the
/// look off each layer directly. New code that wants true per-layer control should edit
/// `layer.look.*` instead of the bridge.
struct StickerEdit: Equatable, Codable {
    var layers: [StickerLayer] = []

    // Background (global)
    var background: StickerBackground = .none
    var bgSolidColor: RGBAColor = .white
    var bgGradientTop: RGBAColor = RGBAColor(0.30, 0.62, 1.0)
    var bgGradientBottom: RGBAColor = RGBAColor(0.36, 0.30, 0.92)
    var bgCornerRadius: Double = 0          // 0...0.5 of canvas
    var bgPadding: Double = 0               // 0...1 extra breathing room

    /// Holds the look while there are no layers yet (mirrors onto layer 0 the moment one is added).
    private var orphanLook = LayerLook()

    var primary: StickerLayer? { layers.first }
    var isDual: Bool { layers.count > 1 }

    // MARK: - Active-look bridge

    /// The look that the single-look editor + tests read/write. Backed by layer 0 when present.
    var activeLook: LayerLook {
        get { layers.first?.look ?? orphanLook }
        set {
            if layers.isEmpty { orphanLook = newValue }
            else { layers[0].look = newValue }
        }
    }

    // Adjustments
    var brightness: Double { get { activeLook.brightness } set { activeLook.brightness = newValue } }
    var contrast: Double   { get { activeLook.contrast }   set { activeLook.contrast = newValue } }
    var saturation: Double { get { activeLook.saturation } set { activeLook.saturation = newValue } }
    var warmth: Double     { get { activeLook.warmth }     set { activeLook.warmth = newValue } }
    var tint: Double       { get { activeLook.tint }       set { activeLook.tint = newValue } }
    var vibrance: Double   { get { activeLook.vibrance }   set { activeLook.vibrance = newValue } }
    var exposure: Double   { get { activeLook.exposure }   set { activeLook.exposure = newValue } }
    var highlights: Double { get { activeLook.highlights } set { activeLook.highlights = newValue } }
    var shadows: Double    { get { activeLook.shadows }    set { activeLook.shadows = newValue } }
    var hue: Double        { get { activeLook.hue }        set { activeLook.hue = newValue } }
    var sharpness: Double  { get { activeLook.sharpness }  set { activeLook.sharpness = newValue } }
    var vignette: Double   { get { activeLook.vignette }   set { activeLook.vignette = newValue } }
    var grain: Double      { get { activeLook.grain }      set { activeLook.grain = newValue } }

    // Outline / glow / shadow
    var outline: OutlineStyle      { get { activeLook.outline }       set { activeLook.outline = newValue } }
    var outlineColor: RGBAColor?   { get { activeLook.outlineColor }  set { activeLook.outlineColor = newValue } }
    var outlineWidth: Double       { get { activeLook.outlineWidth }  set { activeLook.outlineWidth = newValue } }
    var glowColor: RGBAColor       { get { activeLook.glowColor }     set { activeLook.glowColor = newValue } }
    var glowRadius: Double         { get { activeLook.glowRadius }    set { activeLook.glowRadius = newValue } }
    var shadowOpacity: Double      { get { activeLook.shadowOpacity } set { activeLook.shadowOpacity = newValue } }
    var shadowOffset: Double       { get { activeLook.shadowOffset }  set { activeLook.shadowOffset = newValue } }
    var shadowBlur: Double         { get { activeLook.shadowBlur }    set { activeLook.shadowBlur = newValue } }

    // Filter
    var filter: PhotoFilter { get { activeLook.filter }         set { activeLook.filter = newValue } }
    var filterStrength: Double { get { activeLook.filterStrength } set { activeLook.filterStrength = newValue } }

    // Cutout edge
    var feather: Double { get { activeLook.feather } set { activeLook.feather = newValue } }

    // Text (the active look's caption)
    var text: StickerText { get { activeLook.text } set { activeLook.text = newValue } }

    // MARK: - Codable (only persist real state; the bridge accessors derive from layers)

    enum CodingKeys: String, CodingKey {
        case layers, background, bgSolidColor, bgGradientTop, bgGradientBottom
        case bgCornerRadius, bgPadding, orphanLook
    }
}
