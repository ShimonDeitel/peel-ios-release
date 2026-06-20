import XCTest
import UIKit
@testable import Peel

/// Headless render harness: exercises EVERY editor feature through the real StickerRenderer pipeline,
/// writes a PNG per feature/value plus a manifest.json, and asserts basic invariants (no crash, sane
/// size, die-cut transparency). The PNGs are what the 100-agent review fleet visually inspects.
/// (Vision subject-lift can't run in the sim, so synthetic cutouts stand in for the on-device cutout.)
@MainActor
final class RenderMatrixTests: XCTestCase {

    private var dir: URL!
    private var manifest: [[String: Any]] = []

    func testRenderEveryFeature() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("peel-shots", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let cutout = Self.syntheticCutout()
        let cutout2 = Self.syntheticCutout(palette: 1)
        let original = Self.syntheticPhoto()

        // baseline
        shoot("00_baseline", "Default white outline, no edits", base(cutout), transparentCorners: true)

        // 1) Filters
        for f in PhotoFilter.allCases {
            var e = base(cutout); e.filter = f
            shoot("filter_\(f.rawValue)", "Filter: \(f.title)", e, transparentCorners: true)
        }
        // filter strength sweep on a strong filter
        for s in [0.0, 0.5, 1.0] {
            var e = base(cutout); e.filter = .noir; e.filterStrength = s
            shoot("filterStrength_\(Int(s*100))", "Noir at strength \(Int(s*100))%", e, transparentCorners: true)
        }

        // 2) Outlines
        for o in OutlineStyle.allCases {
            var e = base(cutout); e.outline = o
            shoot("outline_\(o.rawValue)", "Outline: \(o.title)", e, transparentCorners: true)
        }
        // custom outline color + width
        do {
            var e = base(cutout); e.outline = .custom; e.outlineColor = RGBAColor(0.2, 0.8, 1.0); e.outlineWidth = 0.9
            shoot("outline_custom_wide", "Custom cyan outline, max width", e, transparentCorners: true)
        }
        // glow color + radius
        do {
            var e = base(cutout); e.outline = .glow; e.glowColor = RGBAColor(1.0, 0.3, 0.6); e.glowRadius = 0.8
            shoot("outline_glow_pink", "Neon glow, pink, large radius", e, transparentCorners: true)
        }
        // independent shadow
        do {
            var e = base(cutout); e.outline = .none; e.shadowOpacity = 0.5; e.shadowBlur = 0.7; e.shadowOffset = 0.6
            shoot("shadow_strong", "Drop shadow only, strong", e, transparentCorners: true)
        }

        // 3) Adjustments (each pushed to a visible value)
        let adjustments: [(String, (inout StickerEdit) -> Void)] = [
            ("brightness_up", { $0.brightness = 0.35 }), ("brightness_down", { $0.brightness = -0.35 }),
            ("contrast_up", { $0.contrast = 1.45 }), ("contrast_down", { $0.contrast = 0.65 }),
            ("saturation_up", { $0.saturation = 1.9 }), ("saturation_down", { $0.saturation = 0.1 }),
            ("vibrance", { $0.vibrance = 0.9 }), ("exposure_up", { $0.exposure = 1.5 }), ("exposure_down", { $0.exposure = -1.5 }),
            ("highlights", { $0.highlights = 0.4 }), ("shadows", { $0.shadows = 0.8 }),
            ("warmth_warm", { $0.warmth = 0.7 }), ("warmth_cool", { $0.warmth = -0.7 }), ("tint", { $0.tint = 0.6 }),
            ("hue", { $0.hue = 2.0 }), ("sharpness", { $0.sharpness = 0.9 }),
            ("vignette", { $0.vignette = 1.2 }), ("grain", { $0.grain = 0.4 }),
        ]
        for (name, mut) in adjustments {
            var e = base(cutout); mut(&e)
            shoot("adjust_\(name)", "Adjustment: \(name)", e, transparentCorners: true)
        }

        // 4) Backgrounds
        for b in StickerBackground.allCases {
            var e = base(cutout); e.background = b
            shoot("bg_\(b.rawValue)", "Background: \(b.title)", e, original: original, transparentCorners: false)
        }
        // custom solid + gradient + corner radius
        do {
            var e = base(cutout); e.background = .solid; e.bgSolidColor = RGBAColor(0.95, 0.4, 0.7); e.bgCornerRadius = 0.4
            shoot("bg_solid_rounded", "Solid pink background, rounded corners", e, transparentCorners: true)
        }
        do {
            var e = base(cutout); e.background = .gradient; e.bgGradientTop = RGBAColor(1, 0.8, 0.2); e.bgGradientBottom = RGBAColor(0.2, 0.4, 1)
            shoot("bg_gradient_custom", "Custom 2-color gradient background", e, original: original, transparentCorners: false)
        }

        // 5) Text
        let texts: [(String, (inout StickerText) -> Void)] = [
            ("bottom", { $0.string = "HELLO"; $0.position = .bottom }),
            ("top", { $0.string = "WOW"; $0.position = .top }),
            ("middle_noupper", { $0.string = "Mixed Case"; $0.position = .middle; $0.uppercase = false }),
            ("colored_shadow", { $0.string = "POP"; $0.color = RGBAColor(1, 0.85, 0.2); $0.shadowed = true }),
            ("nostroke", { $0.string = "CLEAN"; $0.stroked = false }),
            ("spaced", { $0.string = "SPACE"; $0.kern = 0.25 }),
        ]
        for (name, mut) in texts {
            var e = base(cutout); mut(&e.text)
            shoot("text_\(name)", "Text: \(name)", e, transparentCorners: true)
        }
        // fonts
        for fnt in StickerFont.allCases {
            var e = base(cutout); e.text.string = "Ag"; e.text.font = fnt; e.text.sizeFraction = 0.18
            shoot("font_\(fnt.rawValue)", "Font: \(fnt.title)", e, transparentCorners: true)
        }

        // 6) Transforms
        do { var e = base(cutout); e.layers[0].transform.rotationQuarters = 1; shoot("xf_rotate90", "Quarter rotate (right)", e, transparentCorners: true) }
        do { var e = base(cutout); e.layers[0].transform.flipH = true; shoot("xf_flipH", "Flip horizontal", e, transparentCorners: true) }
        do { var e = base(cutout); e.layers[0].transform.flipV = true; shoot("xf_flipV", "Flip vertical", e, transparentCorners: true) }
        do { var e = base(cutout); e.layers[0].transform.rotation = 0.3; shoot("xf_freeRotate", "Free rotate ~17deg CW", e, transparentCorners: true) }
        do { var e = base(cutout); e.layers[0].transform.scale = 1.6; shoot("xf_scaleUp", "Scale up 1.6x", e, transparentCorners: true) }
        do { var e = base(cutout); e.layers[0].transform.scale = 0.6; shoot("xf_scaleDown", "Scale down 0.6x", e, transparentCorners: true) }
        do { var e = base(cutout); e.feather = 0.8; shoot("xf_feather", "Edge feather", e, transparentCorners: true) }

        // 7) Dual stickers (Pro)
        do {
            var e = base(cutout)
            var l2 = StickerLayer(cutout: cutout2)
            l2.transform.center = CGPoint(x: 0.66, y: 0.5); l2.transform.scale = 0.85
            e.layers.append(l2)
            shoot("dual_basic", "Dual: two subjects side by side", e, transparentCorners: true)
        }
        do {
            var e = base(cutout)
            var l2 = StickerLayer(cutout: cutout2)
            l2.transform.center = CGPoint(x: 0.4, y: 0.4); l2.transform.scale = 0.7; l2.transform.rotation = 0.4; l2.transform.flipH = true
            e.layers.append(l2)
            shoot("dual_transformed", "Dual: second subject scaled/rotated/flipped", e, transparentCorners: true)
        }

        // 8) Auto-Edit on varied inputs
        let inputs: [(String, UIImage)] = [
            ("dark", Self.syntheticCutout(brightness: 0.18)),
            ("bright", Self.syntheticCutout(brightness: 0.9)),
            ("colorful", Self.syntheticCutout(palette: 2)),
            ("skin", Self.syntheticSkin()),
        ]
        for (name, img) in inputs {
            var e = StickerEdit(); e.layers = [StickerLayer(cutout: img)]
            AutoEdit.enhance(&e, primary: img)
            shoot("autoedit_\(name)", "Auto-Edit applied to a \(name) subject", e, transparentCorners: true)
            manifest[manifest.count - 1]["autoEditFields"] =
                "outline=\(e.outline.rawValue) contrast=\(String(format: "%.2f", e.contrast)) sat=\(String(format: "%.2f", e.saturation)) exp=\(String(format: "%.2f", e.exposure)) warmth=\(String(format: "%.2f", e.warmth)) shadow=\(String(format: "%.2f", e.shadowOpacity))"
        }

        // 9) NEW Stage-3 features

        // a) Emoji layer
        do {
            var e = base(cutout)
            var emoji = StickerLayer(cutout: LayerFactory.emoji("😎"), type: .emoji)
            emoji.look.outline = .none
            emoji.transform.center = CGPoint(x: 0.62, y: 0.40); emoji.transform.scale = 0.5
            e.layers.append(emoji)
            shoot("new_emoji", "Emoji mashup layer", e, transparentCorners: true)
        }
        // b) Doodle / drawing layer (synthetic squiggle cutout)
        do {
            var e = base(cutout)
            var doodle = StickerLayer(cutout: Self.syntheticDoodle(), type: .drawing)
            doodle.look.outline = .none
            e.layers.append(doodle)
            shoot("new_doodle", "Freehand doodle layer", e, transparentCorners: true)
        }
        // c) Photo layer (a raw, fully-opaque photo placed as a layer)
        do {
            var e = base(cutout)
            var photo = StickerLayer(cutout: original, type: .photo)
            photo.look.outline = .none
            photo.transform.center = CGPoint(x: 0.5, y: 0.5); photo.transform.scale = 0.6
            e.layers.append(photo)
            shoot("new_photo_layer", "Raw photo as an image layer", e, transparentCorners: true)
        }
        // d) Shape layers
        for k in ShapeKind.allCases {
            var e = base(cutout)
            var shape = StickerLayer(cutout: LayerFactory.shape(k, color: UIColor(red: 0, green: 0.48, blue: 1, alpha: 1)), type: .shape)
            shape.look.outline = .none
            shape.transform.center = CGPoint(x: 0.6, y: 0.55); shape.transform.scale = 0.5
            e.layers.append(shape)
            shoot("new_shape_\(k.rawValue)", "Shape layer: \(k.title)", e, transparentCorners: true)
        }
        // e) Duplicate (two of the same layer offset)
        do {
            var e = base(cutout)
            var copy = e.layers[0]
            copy.id = UUID()
            copy.transform.center = CGPoint(x: 0.6, y: 0.6); copy.transform.scale = 0.7
            e.layers.append(copy)
            shoot("new_duplicate", "Duplicated layer offset", e, transparentCorners: true)
        }
        // f) Flip / mirror (flipV — flipH already covered above)
        do { var e = base(cutout); e.layers[0].transform.flipV = true; shoot("new_flipV", "Flip vertical (mirror)", e, transparentCorners: true) }
        // g) Per-layer opacity + blend modes
        do { var e = base(cutout); e.layers[0].opacity = 0.5; shoot("new_opacity50", "Layer opacity 50%", e, transparentCorners: true) }
        for m in LayerBlendMode.allCases {
            var e = base(cutout)
            var top = StickerLayer(cutout: cutout2, type: .subject)
            top.look.outline = .none
            top.transform.center = CGPoint(x: 0.5, y: 0.5); top.transform.scale = 0.9
            top.blend = m; top.opacity = 0.85
            e.layers.append(top)
            shoot("new_blend_\(m.rawValue)", "Blend mode: \(m.title)", e, transparentCorners: true)
        }
        // h) Crop / trim to bounds — a padded cutout must trim to a smaller image
        do {
            let padded = Self.paddedCutout()
            let trimmed = padded.trimmedToAlpha(padFraction: 0.01)
            XCTAssertNotNil(trimmed, "trimmedToAlpha should return a cropped image for a padded cutout")
            if let trimmed {
                XCTAssertLessThan(trimmed.size.width, padded.size.width, "crop should shrink width")
                XCTAssertLessThan(trimmed.size.height, padded.size.height, "crop should shrink height")
            }
            var e = StickerEdit(); e.layers = [StickerLayer(cutout: trimmed ?? padded)]
            shoot("new_crop_trim", "Cropped/trimmed cutout bounds", e, transparentCorners: true)
        }
        // i) Richer text: extra fonts + curved/arc text
        for fnt in [StickerFont.condensed, .american, .copperplate, .bradley, .party] {
            var e = base(cutout); e.text.string = "Ag"; e.text.font = fnt; e.text.sizeFraction = 0.18
            shoot("new_font_\(fnt.rawValue)", "New font: \(fnt.title)", e, transparentCorners: true)
        }
        do { var e = base(cutout); e.text.string = "SMILE"; e.text.curve = 0.7; e.text.position = .top
             shoot("new_text_arc_up", "Curved text (arc up)", e, transparentCorners: true) }
        do { var e = base(cutout); e.text.string = "FROWN"; e.text.curve = -0.7; e.text.position = .bottom
             shoot("new_text_arc_down", "Curved text (arc down)", e, transparentCorners: true) }
        // j) One-tap effect presets
        for p in EffectPreset.allCases {
            var e = base(cutout)
            p.apply(to: &e.layers[0].look)
            shoot("new_preset_\(p.rawValue)", "Effect preset: \(p.title)", e, transparentCorners: true)
        }

        // Write manifest
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: dir.appendingPathComponent("manifest.json"))
        print("PEEL_SHOTS_DIR:\(dir.path)")
        print("PEEL_SHOTS_COUNT:\(manifest.count)")
    }

    // MARK: - Render + invariants

    private func base(_ cutout: UIImage) -> StickerEdit {
        var e = StickerEdit(); e.layers = [StickerLayer(cutout: cutout)]; return e
    }

    private func shoot(_ name: String, _ desc: String, _ edit: StickerEdit, original: UIImage? = nil, transparentCorners: Bool) {
        let img = StickerRenderer.renderForExport(edit: edit, canvasLongSide: 900, original: original)
        XCTAssertGreaterThan(img.size.width, 10, "\(name): width sane")
        XCTAssertGreaterThan(img.size.height, 10, "\(name): height sane")
        var entry: [String: Any] = ["name": name, "description": desc, "file": "\(name).png",
                                    "width": Int(img.size.width), "height": Int(img.size.height)]
        if let cg = img.cgImage {
            let center = Self.alpha(cg, atFraction: CGPoint(x: 0.5, y: 0.5))
            let corner = Self.alpha(cg, atFraction: CGPoint(x: 0.04, y: 0.04))
            entry["centerAlpha"] = center
            entry["cornerAlpha"] = corner
            XCTAssertGreaterThan(center, 40, "\(name): subject should be visible at center")
            if transparentCorners {
                XCTAssertLessThan(corner, 40, "\(name): die-cut corner should be transparent")
            }
        }
        if let data = img.pngData() {
            try? data.write(to: dir.appendingPathComponent("\(name).png"))
            entry["bytes"] = data.count
        }
        manifest.append(entry)
    }

    private static func alpha(_ cg: CGImage, atFraction p: CGPoint) -> Int {
        let x = max(0, min(cg.width - 1, Int(CGFloat(cg.width) * p.x)))
        let y = max(0, min(cg.height - 1, Int(CGFloat(cg.height) * p.y)))
        var px = [UInt8](repeating: 0, count: 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        ctx.draw(cg, in: CGRect(x: -x, y: -(cg.height - 1 - y), width: cg.width, height: cg.height))
        return Int(px[3])
    }

    // MARK: - Synthetic inputs (transparent cutouts standing in for the Vision lift)

    static func syntheticCutout(palette: Int = 0, brightness: CGFloat = 0.6) -> UIImage {
        let size = CGSize(width: 360, height: 440)
        let fmt = UIGraphicsImageRendererFormat.default(); fmt.opaque = false; fmt.scale = 1
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            let c = ctx.cgContext
            // body: rounded blob with a vertical gradient -> gives filters/adjustments something to work on
            let blob = UIBezierPath(roundedRect: CGRect(x: 70, y: 40, width: 220, height: 360), cornerRadius: 110)
            c.saveGState(); blob.addClip()
            let cs = CGColorSpaceCreateDeviceRGB()
            let (c0, c1): ([CGFloat], [CGFloat])
            switch palette {
            case 1: c0 = [0.95, 0.45, 0.25, 1]; c1 = [0.35, 0.15, 0.55, 1]
            case 2: c0 = [0.1, 0.9, 0.5, 1]; c1 = [0.9, 0.2, 0.8, 1]
            default: c0 = [0.25*Double(brightness)/0.6, 0.5*Double(brightness)/0.6, brightness, 1]
                     c1 = [brightness, 0.45*Double(brightness)/0.6, 0.2, 1]
            }
            let grad = CGGradient(colorSpace: cs, colorComponents: c0 + c1, locations: [0, 1], count: 2)!
            c.drawLinearGradient(grad, start: CGPoint(x: 180, y: 40), end: CGPoint(x: 180, y: 400), options: [])
            c.restoreGState()
            // a couple of features so edges/sharpen/comic have detail
            UIColor.white.withAlphaComponent(0.85).setFill()
            c.fillEllipse(in: CGRect(x: 120, y: 120, width: 50, height: 50))
            c.fillEllipse(in: CGRect(x: 200, y: 120, width: 50, height: 50))
            UIColor.black.withAlphaComponent(0.7).setFill()
            c.fillEllipse(in: CGRect(x: 135, y: 135, width: 20, height: 20))
            c.fillEllipse(in: CGRect(x: 215, y: 135, width: 20, height: 20))
        }
    }

    static func syntheticSkin() -> UIImage {
        let size = CGSize(width: 360, height: 440)
        let fmt = UIGraphicsImageRendererFormat.default(); fmt.opaque = false; fmt.scale = 1
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            let c = ctx.cgContext
            UIColor(red: 0.85, green: 0.62, blue: 0.5, alpha: 1).setFill()
            UIBezierPath(roundedRect: CGRect(x: 90, y: 60, width: 180, height: 300), cornerRadius: 90).fill()
            UIColor(red: 0.2, green: 0.15, blue: 0.1, alpha: 1).setFill()
            c.fillEllipse(in: CGRect(x: 130, y: 150, width: 28, height: 28))
            c.fillEllipse(in: CGRect(x: 200, y: 150, width: 28, height: 28))
        }
    }

    /// A transparent image with a single bright squiggle — stands in for a hand-drawn doodle layer.
    static func syntheticDoodle() -> UIImage {
        let size = CGSize(width: 360, height: 360)
        let fmt = UIGraphicsImageRendererFormat.default(); fmt.opaque = false; fmt.scale = 1
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            let c = ctx.cgContext
            c.setStrokeColor(UIColor(red: 0, green: 0.48, blue: 1, alpha: 1).cgColor)
            c.setLineWidth(14); c.setLineCap(.round); c.setLineJoin(.round)
            c.move(to: CGPoint(x: 60, y: 180))
            c.addCurve(to: CGPoint(x: 300, y: 180),
                       control1: CGPoint(x: 140, y: 40), control2: CGPoint(x: 220, y: 320))
            c.strokePath()
        }
    }

    /// A small opaque blob centered in a large transparent canvas — its content bounds are far inside the
    /// image, so `trimmedToAlpha` must crop to a meaningfully smaller image.
    static func paddedCutout() -> UIImage {
        let size = CGSize(width: 400, height: 400)
        let fmt = UIGraphicsImageRendererFormat.default(); fmt.opaque = false; fmt.scale = 1
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            UIColor.systemTeal.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 160, y: 160, width: 80, height: 80))
        }
    }

    static func syntheticPhoto() -> UIImage {
        let size = CGSize(width: 500, height: 500)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let cs = CGColorSpaceCreateDeviceRGB()
            let grad = CGGradient(colorSpace: cs, colorComponents: [0.2, 0.5, 0.9, 1, 0.9, 0.4, 0.6, 1], locations: [0, 1], count: 2)!
            ctx.cgContext.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 500, y: 500), options: [])
        }
    }
}
