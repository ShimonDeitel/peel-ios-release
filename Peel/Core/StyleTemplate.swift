import SwiftUI

/// A named, ready-to-apply LOOK for the Style Wall. A template is *literally* a saved `StickerEdit`
/// with empty `layers` — so applying it is "pour the user's own cutout into this edit and render",
/// reusing `StickerRenderer.render(cutout:edit:)` verbatim (near-zero new imaging code, the whole point
/// of the headline feature). Premium templates belong to a `pack` whose product id gates them; the tile
/// still renders live on the user's subject with a quiet PRO chip until the pack is owned.
struct StyleTemplate: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    /// nil for the free starter pack; a `peel_pack_*` product id for premium packs.
    var packID: String?
    /// The look itself — a `StickerEdit` whose `layers` are intentionally empty (filled at apply-time
    /// with the user's cutout). Background + the active look ride along; everything is Codable already.
    var edit: StickerEdit

    /// Every Style Wall look is free. Peel sells a single one-time Pro unlock (unlimited creates +
    /// hi-res export); the cosmetic catalog is never gated.
    func isLocked(ownedPacks: Set<String>) -> Bool {
        false
    }

    /// Produce a fresh `StickerEdit` carrying this template's look with the user's cutout poured in as
    /// the single subject layer. The renderer reads the per-layer look off `layers[0]`, so we copy the
    /// template's active look onto the new subject layer (its empty-layer `orphanLook` is the source).
    func applied(to cutout: UIImage) -> StickerEdit {
        var e = edit
        var layer = StickerLayer(cutout: cutout, type: .subject)
        layer.look = edit.activeLook          // the template's look (held in orphanLook while layerless)
        e.layers = [layer]
        return e
    }

    /// Build a template from a designed look. Keeps `layers` empty so only the LOOK travels.
    init(id: String, title: String, packID: String? = nil, look: LayerLook = LayerLook(),
         background: StickerBackground = .none, bgCornerRadius: Double = 0, bgPadding: Double = 0,
         bgSolid: RGBAColor = .white, bgTop: RGBAColor = RGBAColor(0.30, 0.62, 1.0),
         bgBottom: RGBAColor = RGBAColor(0.36, 0.30, 0.92)) {
        self.id = id
        self.title = title
        self.packID = packID
        var e = StickerEdit()
        e.background = background
        e.bgCornerRadius = bgCornerRadius
        e.bgPadding = bgPadding
        e.bgSolidColor = bgSolid
        e.bgGradientTop = bgTop
        e.bgGradientBottom = bgBottom
        e.activeLook = look                    // stored in orphanLook (no layers yet)
        self.edit = e
    }
}

/// A purchasable cosmetic bundle of templates (the $1.99 Style-Pack SKU). Each pack is just saved
/// `StyleTemplate` JSON — zero new imaging code.
struct StylePack: Identifiable, Equatable {
    var id: String          // the `peel_pack_*` product id
    var title: String
    var subtitle: String
    var templates: [StyleTemplate]
}

/// The Style Wall catalog: ~24 FREE starter templates plus the premium packs. All looks are built from
/// the existing `LayerLook` / outline / filter / background primitives, so every tile renders through the
/// proven alpha-invariant renderer.
enum StyleCatalog {

    // MARK: - Small look builders (kept terse; each returns a fully-formed LayerLook)

    private static func look(outline: OutlineStyle = .white,
                             outlineWidth: Double = 0.5,
                             outlineColor: RGBAColor? = nil,
                             filter: PhotoFilter = .none,
                             filterStrength: Double = 1.0,
                             glow: RGBAColor = RGBAColor(0.45, 0.55, 1.0),
                             glowRadius: Double = 0.5,
                             shadowOpacity: Double = 0,
                             saturation: Double = 1.0,
                             contrast: Double = 1.0,
                             brightness: Double = 0,
                             vibrance: Double = 0) -> LayerLook {
        var l = LayerLook()
        l.outline = outline
        l.outlineWidth = outlineWidth
        l.outlineColor = outlineColor
        l.filter = filter
        l.filterStrength = filterStrength
        l.glowColor = glow
        l.glowRadius = glowRadius
        l.shadowOpacity = shadowOpacity
        l.saturation = saturation
        l.contrast = contrast
        l.brightness = brightness
        l.vibrance = vibrance
        return l
    }

    // MARK: - FREE starter pack (~24 templates)

    static let starter: [StyleTemplate] = [
        // Clean die-cuts
        StyleTemplate(id: "classic_white", title: "Classic",
                      look: look(outline: .white, outlineWidth: 0.55)),
        StyleTemplate(id: "bold_black", title: "Bold",
                      look: look(outline: .black, outlineWidth: 0.6)),
        StyleTemplate(id: "thick_sticker", title: "Sticker",
                      look: look(outline: .sticker, outlineWidth: 0.55)),
        StyleTemplate(id: "pop_shadow", title: "Pop",
                      look: look(outline: .pop, outlineWidth: 0.5, shadowOpacity: 0.35)),
        StyleTemplate(id: "cut_line", title: "Cut-line",
                      look: look(outline: .dashed, outlineWidth: 0.5)),
        StyleTemplate(id: "no_outline", title: "Bare",
                      look: look(outline: .none)),

        // Color outlines
        StyleTemplate(id: "candy_rim", title: "Candy",
                      look: look(outline: .candy, outlineWidth: 0.6, saturation: 1.1)),
        StyleTemplate(id: "mint_rim", title: "Mint",
                      look: look(outline: .mint, outlineWidth: 0.6)),

        // Neon / glow looks
        StyleTemplate(id: "neon_blue", title: "Neon",
                      look: look(outline: .glow, outlineWidth: 0.45,
                                 glow: RGBAColor(0.30, 0.62, 1.0), glowRadius: 0.6, saturation: 1.1)),
        StyleTemplate(id: "neon_pink", title: "Hot Glow",
                      look: look(outline: .glow, outlineWidth: 0.45,
                                 glow: RGBAColor(1.0, 0.30, 0.66), glowRadius: 0.65, saturation: 1.15)),
        StyleTemplate(id: "neon_green", title: "Toxic",
                      look: look(outline: .glow, outlineWidth: 0.45,
                                 glow: RGBAColor(0.35, 1.0, 0.55), glowRadius: 0.6)),

        // Photo-filter looks (die-cut)
        StyleTemplate(id: "vivid_pop", title: "Vivid",
                      look: look(outline: .white, outlineWidth: 0.5, filter: .vivid, vibrance: 0.3)),
        StyleTemplate(id: "noir", title: "Noir",
                      look: look(outline: .white, outlineWidth: 0.55, filter: .noir)),
        StyleTemplate(id: "mono_ink", title: "Mono",
                      look: look(outline: .black, outlineWidth: 0.5, filter: .mono)),
        StyleTemplate(id: "warm_film", title: "Golden",
                      look: look(outline: .white, outlineWidth: 0.5, filter: .warm)),
        StyleTemplate(id: "cool_chill", title: "Frost",
                      look: look(outline: .white, outlineWidth: 0.5, filter: .cool)),
        StyleTemplate(id: "vintage", title: "Retro",
                      look: look(outline: .white, outlineWidth: 0.55, filter: .vintage)),
        StyleTemplate(id: "line_art", title: "Line Art",
                      look: look(outline: .black, outlineWidth: 0.4, filter: .edges)),
        StyleTemplate(id: "comic_dots", title: "Comic",
                      look: look(outline: .black, outlineWidth: 0.5, filter: .comic)),
        StyleTemplate(id: "popart", title: "Pop Art",
                      look: look(outline: .white, outlineWidth: 0.55, filter: .posterize, saturation: 1.2)),

        // Backgrounds (badge looks)
        StyleTemplate(id: "white_badge", title: "Badge",
                      look: look(outline: .none),
                      background: .white, bgCornerRadius: 0.22, bgPadding: 0.3),
        StyleTemplate(id: "sunset_card", title: "Sunset",
                      look: look(outline: .white, outlineWidth: 0.45),
                      background: .sunset, bgCornerRadius: 0.22, bgPadding: 0.3),
        StyleTemplate(id: "ocean_card", title: "Ocean",
                      look: look(outline: .white, outlineWidth: 0.45),
                      background: .ocean, bgCornerRadius: 0.22, bgPadding: 0.3),
        StyleTemplate(id: "blur_focus", title: "Soft Focus",
                      look: look(outline: .white, outlineWidth: 0.4),
                      background: .blurred, bgCornerRadius: 0.18, bgPadding: 0.18),
    ]

    // MARK: - Premium packs (each a $1.99 cosmetic NonConsumable)

    static let packs: [StylePack] = [
        StylePack(id: "peel_pack_neon", title: "Neon Nights", subtitle: "Glow looks for the dark",
                  templates: [
                    StyleTemplate(id: "nn_electric", title: "Electric", packID: "peel_pack_neon",
                                  look: look(outline: .glow, outlineWidth: 0.5,
                                             glow: RGBAColor(0.20, 0.80, 1.0), glowRadius: 0.8, saturation: 1.2),
                                  background: .ink, bgCornerRadius: 0.2, bgPadding: 0.28),
                    StyleTemplate(id: "nn_magenta", title: "Magenta", packID: "peel_pack_neon",
                                  look: look(outline: .glow, outlineWidth: 0.5,
                                             glow: RGBAColor(1.0, 0.20, 0.80), glowRadius: 0.85, saturation: 1.2),
                                  background: .ink, bgCornerRadius: 0.2, bgPadding: 0.28),
                    StyleTemplate(id: "nn_acid", title: "Acid", packID: "peel_pack_neon",
                                  look: look(outline: .glow, outlineWidth: 0.5,
                                             glow: RGBAColor(0.60, 1.0, 0.20), glowRadius: 0.8),
                                  background: .ink, bgCornerRadius: 0.2, bgPadding: 0.28),
                    StyleTemplate(id: "nn_dream", title: "Dream", packID: "peel_pack_neon",
                                  look: look(outline: .glow, outlineWidth: 0.45, filter: .cool,
                                             glow: RGBAColor(0.70, 0.40, 1.0), glowRadius: 0.9),
                                  background: .ink, bgCornerRadius: 0.2, bgPadding: 0.28),
                  ]),

        StylePack(id: "peel_pack_comic", title: "Comic Shop", subtitle: "Inked & halftoned",
                  templates: [
                    StyleTemplate(id: "cs_inked", title: "Inked", packID: "peel_pack_comic",
                                  look: look(outline: .black, outlineWidth: 0.7, filter: .comic, contrast: 1.1)),
                    StyleTemplate(id: "cs_pow", title: "POW!", packID: "peel_pack_comic",
                                  look: look(outline: .sticker, outlineWidth: 0.65, filter: .posterize, saturation: 1.3),
                                  background: .candy, bgCornerRadius: 0.16, bgPadding: 0.22),
                    StyleTemplate(id: "cs_manga", title: "Manga", packID: "peel_pack_comic",
                                  look: look(outline: .black, outlineWidth: 0.55, filter: .edges)),
                    StyleTemplate(id: "cs_pulp", title: "Pulp", packID: "peel_pack_comic",
                                  look: look(outline: .black, outlineWidth: 0.6, filter: .dramatic),
                                  background: .gold, bgCornerRadius: 0.16, bgPadding: 0.22),
                  ]),

        StylePack(id: "peel_pack_y2k", title: "Y2K", subtitle: "Chrome & candy throwback",
                  templates: [
                    StyleTemplate(id: "y2k_chrome", title: "Chrome", packID: "peel_pack_y2k",
                                  look: look(outline: .sticker, outlineWidth: 0.6, filter: .chrome, saturation: 1.1)),
                    StyleTemplate(id: "y2k_bubblegum", title: "Bubblegum", packID: "peel_pack_y2k",
                                  look: look(outline: .candy, outlineWidth: 0.7, saturation: 1.2),
                                  background: .candy, bgCornerRadius: 0.26, bgPadding: 0.3),
                    StyleTemplate(id: "y2k_holo", title: "Holo", packID: "peel_pack_y2k",
                                  look: look(outline: .glow, outlineWidth: 0.5, filter: .vivid,
                                             glow: RGBAColor(0.60, 0.90, 1.0), glowRadius: 0.7),
                                  background: .mint, bgCornerRadius: 0.26, bgPadding: 0.3),
                    StyleTemplate(id: "y2k_frost", title: "Frost", packID: "peel_pack_y2k",
                                  look: look(outline: .white, outlineWidth: 0.55, filter: .cool, brightness: 0.05),
                                  background: .ocean, bgCornerRadius: 0.26, bgPadding: 0.3),
                  ]),
    ]

    /// Every template the Style Wall shows: free starters first, then each pack's tiles (locked until
    /// owned, but always rendered live on the user's subject with a PRO chip).
    static var allTemplates: [StyleTemplate] {
        starter + packs.flatMap(\.templates)
    }

    /// Find a template by id (used by Remix deep links and re-open).
    static func template(id: String) -> StyleTemplate? {
        allTemplates.first { $0.id == id }
    }
}
