import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Composes a finished sticker on a FIXED square canvas from one or more transparent cutouts (layers):
/// per layer → adjustments → filter → outline/glow/shadow → placement transform; then a global
/// background behind everything and text on top. All on-device with Core Image + Core Graphics.
///
/// ALPHA INVARIANT: every color/adjust/filter op runs on RGB then is re-masked to the layer's original
/// silhouette (alphaLuma + blendWithMask), so transparency is never painted into.
enum StickerRenderer {
    private static let ctx = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - Public entry points

    /// Live preview / full fixed-canvas render (NOT cropped, so the subject doesn't jump while dragging).
    static func render(edit: StickerEdit, canvasLongSide: CGFloat, original: UIImage? = nil) -> UIImage {
        let base = renderComposite(edit: edit, canvasLongSide: canvasLongSide, original: original)
        return overlayText(edit, on: base)
    }

    /// The composite WITHOUT any text overlay — text must not influence the die-cut crop, so the export
    /// path crops this image and only then draws text back on (fixing the preview/export divergence).
    private static func renderComposite(edit: StickerEdit, canvasLongSide: CGFloat, original: UIImage?) -> UIImage {
        let canvas = CGRect(x: 0, y: 0, width: canvasLongSide, height: canvasLongSide)
        guard let composed = composite(edit: edit, canvas: canvas, original: original),
              let cg = ctx.createCGImage(composed, from: canvas) else {
            return edit.primary?.cutout ?? UIImage()
        }
        return UIImage(cgImage: cg)
    }

    /// Draw the active look's caption(s) over a rendered image. With a background fill text spans the
    /// full square; on a die-cut (no background) the SAME text is drawn so preview and the
    /// post-crop export match exactly.
    private static func overlayText(_ edit: StickerEdit, on image: UIImage) -> UIImage {
        var out = image
        for layer in edit.layers where !layer.isHidden && !layer.look.text.isEmpty {
            out = drawText(layer.look.text, on: out)
        }
        return out
    }

    /// Export / thumbnail render. Crop the die-cut to the SUBJECT/outline bounds FIRST (text excluded),
    /// then draw text on the cropped frame — so a long caption can't push out the crop and make the
    /// exported sticker framed differently from the live preview.
    static func renderForExport(edit: StickerEdit, canvasLongSide: CGFloat = 1200, original: UIImage? = nil) -> UIImage {
        let composite = renderComposite(edit: edit, canvasLongSide: canvasLongSide, original: original)
        // a background fills the whole square, so there's nothing to die-cut crop
        let usesGlow = edit.layers.contains { $0.look.outline == .glow } || edit.outline == .glow
        let cropped = edit.background == .none
            ? alphaCropped(composite, padFraction: usesGlow ? 0.04 : 0.015)
            : composite
        return overlayText(edit, on: cropped)
    }

    // MARK: - Back-compat wrappers (single layer)

    static func render(cutout: UIImage, style: OutlineStyle) -> UIImage {
        var e = StickerEdit(); e.outline = style
        e.layers = [StickerLayer(cutout: cutout)]
        return renderForExport(edit: e, canvasLongSide: max(cutout.size.width, cutout.size.height) * 1.5, original: cutout)
    }

    static func render(cutout: UIImage, edit incoming: StickerEdit) -> UIImage {
        var e = incoming
        e.layers = [StickerLayer(cutout: cutout)]
        return renderForExport(edit: e, canvasLongSide: max(cutout.size.width, cutout.size.height) * 1.5, original: cutout)
    }

    // MARK: - Composite

    private static func composite(edit: StickerEdit, canvas: CGRect, original: UIImage?) -> CIImage? {
        var acc: CIImage = backgroundFill(edit, canvas: canvas, original: original)
            ?? CIImage(color: .clear).cropped(to: canvas)

        for layer in edit.layers {
            guard !layer.isHidden else { continue }
            guard let placed = layerComposite(layer, edit: edit, canvas: canvas) else { continue }
            acc = blendLayer(placed, over: acc, mode: layer.blend).cropped(to: canvas)
        }
        return acc
    }

    /// Composite one placed layer over the accumulator using its blend mode. `.normal` is plain
    /// source-over; the others use Core Image's named blend filters, which honor the layer's alpha so a
    /// die-cut subject still blends only where it has pixels.
    private static func blendLayer(_ input: CIImage, over background: CIImage, mode: LayerBlendMode) -> CIImage {
        switch mode {
        case .normal:   return sourceOver(input, over: background)
        case .multiply: return blend(CIFilter.multiplyBlendMode(), input, background)
        case .screen:   return blend(CIFilter.screenBlendMode(), input, background)
        case .overlay:  return blend(CIFilter.overlayBlendMode(), input, background)
        case .lighten:  return blend(CIFilter.lightenBlendMode(), input, background)
        case .darken:   return blend(CIFilter.darkenBlendMode(), input, background)
        }
    }
    private static func blend(_ f: CIFilter & CICompositeOperation, _ input: CIImage, _ background: CIImage) -> CIImage {
        f.inputImage = input; f.backgroundImage = background
        return f.outputImage ?? sourceOver(input, over: background)
    }

    /// Build "subject + its outline/glow/shadow" for one layer (reading that layer's OWN look), then
    /// place it on the fixed canvas. The global `edit` only supplies layout context (dual fill, bg).
    private static func layerComposite(_ layer: StickerLayer, edit: StickerEdit, canvas: CGRect) -> CIImage? {
        guard let cg = layer.cutout.cgImage else { return nil }
        let look = layer.look
        var base = CIImage(cgImage: cg)

        // local transform (flip / quarter-rotate) then re-seat at origin
        let t = layer.transform
        if t.flipH { base = base.transformed(by: CGAffineTransform(scaleX: -1, y: 1)) }
        if t.flipV { base = base.transformed(by: CGAffineTransform(scaleX: 1, y: -1)) }
        // negative so a clockwise quarter ("rotate right") reads clockwise in the displayed image
        let q = -CGFloat(t.rotationQuarters % 4) * (.pi / 2)
        if q != 0 { base = base.transformed(by: CGAffineTransform(rotationAngle: q)) }
        base = base.transformed(by: CGAffineTransform(translationX: -base.extent.minX, y: -base.extent.minY))

        // silhouette mask (with optional feather) preserves transparency through adjust/filter
        let shapeMask = featheredMask(base, feather: look.feather)
        var subject = adjust(base, look)
        subject = applyFilter(subject, look.filter, strength: look.filterStrength, longest: max(base.extent.width, base.extent.height))
        subject = addGrain(subject, amount: look.grain, extent: base.extent)
        subject = blendWithMask(input: subject, background: CIImage(color: .clear).cropped(to: base.extent), mask: shapeMask)
            .cropped(to: base.extent)

        // outline / glow / shadow sized to this subject
        let longest = max(subject.extent.width, subject.extent.height)
        let borderW = max(4, longest * CGFloat(0.02 + look.outlineWidth * 0.08))
        let glowR = max(6, longest * CGFloat(0.04 + look.glowRadius * 0.14))
        let shOffset = longest * CGFloat(look.shadowOffset * 0.05)
        let shBlur = max(2, longest * CGFloat(0.01 + look.shadowBlur * 0.09))
        let pad = ceil(borderW + glowR + shOffset + shBlur + longest * 0.06)
        let local = subject.extent.insetBy(dx: -pad, dy: -pad)
        let clear = CIImage(color: .clear).cropped(to: local)

        var comp = outlineLayers(subject: subject, look: look, over: clear, canvas: local,
                                 borderW: borderW, glowR: glowR, shOffset: shOffset, shBlur: shBlur)
        comp = sourceOver(subject, over: comp).cropped(to: local)

        // per-layer opacity (stack control)
        if layer.opacity < 0.999 { comp = applyOpacity(comp, layer.opacity).cropped(to: local) }

        return place(comp, transform: t, canvas: canvas, fill: edit.isDual ? 0.55 : 0.82,
                     bgPad: edit.bgPadding, hasBG: edit.background != .none, contentLongest: longest)
    }

    /// Place a layer-composite on the fixed canvas via its normalized transform. `contentLongest` is
    /// the SUBJECT silhouette size (pre-padding) so outline/glow/shadow width doesn't shrink the subject.
    private static func place(_ image: CIImage, transform: LayerTransform, canvas: CGRect,
                              fill: CGFloat, bgPad: Double, hasBG: Bool, contentLongest: CGFloat) -> CIImage {
        let src = image.extent
        guard contentLongest > 0 else { return image }
        let margin = hasBG ? (1.0 - CGFloat(bgPad) * 0.4) : 1.0
        let bySubject = (min(canvas.width, canvas.height) * fill * margin) / contentLongest
        let byPadded = (min(canvas.width, canvas.height) * 0.98) / max(src.width, src.height)
        let fitScale = min(bySubject, byPadded)   // size to the subject, but never let outline/glow clip the canvas
        let total = fitScale * transform.scale
        let targetX = canvas.width * transform.center.x
        let targetY = canvas.height * (1 - transform.center.y)   // SwiftUI(top-left) -> CI(bottom-left)
        let tf = CGAffineTransform(translationX: targetX, y: targetY)
            .rotated(by: -transform.rotation)                    // CI is CCW-positive; gesture is CW-positive
            .scaledBy(x: total, y: total)
            .translatedBy(x: -src.midX, y: -src.midY)
        return image.transformed(by: tf)
    }

    // MARK: - Adjustments

    private static func adjust(_ base: CIImage, _ e: LayerLook) -> CIImage {
        var img = base
        if e.exposure != 0 {
            let f = CIFilter.exposureAdjust(); f.inputImage = img; f.ev = Float(e.exposure); img = f.outputImage ?? img
        }
        if e.brightness != 0 || e.contrast != 1.0 || e.saturation != 1.0 {
            let f = CIFilter.colorControls(); f.inputImage = img
            f.brightness = Float(e.brightness); f.contrast = Float(e.contrast); f.saturation = Float(e.saturation)
            img = f.outputImage ?? img
        }
        if e.vibrance != 0 {
            let f = CIFilter.vibrance(); f.inputImage = img; f.amount = Float(e.vibrance); img = f.outputImage ?? img
        }
        if e.highlights != 1.0 || e.shadows != 0 {
            let f = CIFilter.highlightShadowAdjust(); f.inputImage = img
            f.highlightAmount = Float(e.highlights); f.shadowAmount = Float(e.shadows)
            f.radius = Float(max(1, max(base.extent.width, base.extent.height) * 0.02))
            img = f.outputImage ?? img
        }
        if e.warmth != 0 || e.tint != 0 {
            let f = CIFilter.temperatureAndTint(); f.inputImage = img
            f.neutral = CIVector(x: 6500, y: 0)
            // positive tint -> magenta (standard photo-editor convention)
            f.targetNeutral = CIVector(x: 6500 - CGFloat(e.warmth) * 2200, y: -CGFloat(e.tint) * 100)
            img = f.outputImage ?? img
        }
        if e.hue != 0 {
            let f = CIFilter.hueAdjust(); f.inputImage = img; f.angle = Float(e.hue); img = f.outputImage ?? img
        }
        if e.sharpness != 0 {
            let f = CIFilter.sharpenLuminance(); f.inputImage = img.clampedToExtent(); f.sharpness = Float(e.sharpness)
            img = (f.outputImage ?? img).cropped(to: base.extent)
        }
        if e.vignette != 0 {
            let f = CIFilter.vignette(); f.inputImage = img; f.intensity = Float(e.vignette); f.radius = 1.6
            img = f.outputImage ?? img
        }
        return img
    }

    private static func addGrain(_ base: CIImage, amount: Double, extent: CGRect) -> CIImage {
        guard amount > 0, let noise = CIFilter.randomGenerator().outputImage else { return base }
        let mono = CIFilter.colorMatrix()
        mono.inputImage = noise.cropped(to: extent)
        mono.rVector = CIVector(x: 0.6, y: 0, z: 0, w: 0)
        mono.gVector = CIVector(x: 0.6, y: 0, z: 0, w: 0)
        mono.bVector = CIVector(x: 0.6, y: 0, z: 0, w: 0)
        mono.aVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(amount))
        guard let grain = mono.outputImage?.cropped(to: extent) else { return base }
        return sourceOver(grain, over: base).cropped(to: extent)
    }

    // MARK: - Filters

    private static func applyFilter(_ base: CIImage, _ filter: PhotoFilter, strength: Double, longest: CGFloat) -> CIImage {
        guard filter != .none else { return base }
        let filtered = rawFilter(base, filter, longest: longest)
        guard strength < 0.999 else { return filtered }
        let f = CIFilter.dissolveTransition()
        f.inputImage = base; f.targetImage = filtered; f.time = Float(max(0, min(1, strength)))
        return f.outputImage ?? filtered
    }

    private static func rawFilter(_ base: CIImage, _ filter: PhotoFilter, longest: CGFloat) -> CIImage {
        func effect(_ name: String) -> CIImage {
            guard let f = CIFilter(name: name) else { return base }
            f.setValue(base, forKey: kCIInputImageKey)
            return f.outputImage ?? base
        }
        switch filter {
        case .none: return base
        case .vivid:
            let v = CIFilter.vibrance(); v.inputImage = base; v.amount = 0.7
            let c = CIFilter.colorControls(); c.inputImage = v.outputImage ?? base; c.contrast = 1.08; c.saturation = 1.15
            return c.outputImage ?? base
        case .warm:
            let f = CIFilter.temperatureAndTint(); f.inputImage = base
            f.neutral = CIVector(x: 6500, y: 0); f.targetNeutral = CIVector(x: 4600, y: 10)
            return f.outputImage ?? base
        case .cool:
            let f = CIFilter.temperatureAndTint(); f.inputImage = base
            f.neutral = CIVector(x: 6500, y: 0); f.targetNeutral = CIVector(x: 8800, y: -10)
            return f.outputImage ?? base
        case .noir: return effect("CIPhotoEffectNoir")
        case .mono: return effect("CIPhotoEffectMono")
        case .fade: return effect("CIPhotoEffectFade")
        case .chrome: return effect("CIPhotoEffectChrome")
        case .vintage: return effect("CIPhotoEffectTransfer")
        case .sepia:
            let f = CIFilter.sepiaTone(); f.inputImage = base; f.intensity = 0.9; return f.outputImage ?? base
        case .invert: return effect("CIColorInvert")
        case .posterize:
            let p = CIFilter.colorPosterize(); p.inputImage = base; p.levels = 6
            let c = CIFilter.colorControls(); c.inputImage = p.outputImage ?? base; c.saturation = 1.2
            return c.outputImage ?? base
        case .comic:
            let f = CIFilter.cmykHalftone(); f.inputImage = base.clampedToExtent()
            f.width = Float(max(4, longest * 0.022)); f.sharpness = 0.9
            return (f.outputImage ?? base).cropped(to: base.extent)
        case .edges:
            // bright edges on black -> invert to dark line-art on white
            let f = CIFilter.edges(); f.inputImage = base.clampedToExtent(); f.intensity = 3.0
            let e = (f.outputImage ?? base).cropped(to: base.extent)
            let inv = CIFilter.colorInvert(); inv.inputImage = e
            return (inv.outputImage ?? e).cropped(to: base.extent)
        case .dramatic:
            let p = effect("CIPhotoEffectProcess")
            let v = CIFilter.vignette(); v.inputImage = p; v.intensity = 0.7; v.radius = 1.6
            return v.outputImage ?? p
        case .duotone:
            // CIColorMap samples the gradient along its X axis, so the ramp MUST be horizontal
            // (a vertical gradient is constant per row and collapses every tone to one color).
            let mono = effect("CIPhotoEffectMono")
            let g = CIFilter.linearGradient()
            g.point0 = CGPoint(x: base.extent.minX, y: base.extent.midY)
            g.point1 = CGPoint(x: base.extent.maxX, y: base.extent.midY)
            g.color0 = CIColor(red: 0.10, green: 0.12, blue: 0.42)   // shadows
            g.color1 = CIColor(red: 0.98, green: 0.78, blue: 0.42)   // highlights
            let grad = (g.outputImage ?? CIImage(color: g.color1)).cropped(to: base.extent)
            let map = CIFilter.colorMap(); map.inputImage = mono; map.gradientImage = grad
            return (map.outputImage ?? mono).cropped(to: base.extent)
        case .glitch:
            // recombine R/G/B as additive (screen) layers so shifted channels blend, not occlude
            let off = longest * 0.012
            let r = channel(base, keep: .red).transformed(by: CGAffineTransform(translationX: off, y: 0))
            let b = channel(base, keep: .blue).transformed(by: CGAffineTransform(translationX: -off, y: 0))
            let g = channel(base, keep: .green)
            var out = screenBlend(r, over: g)
            out = screenBlend(b, over: out)
            return out.cropped(to: base.extent)
        }
    }

    private enum Chan { case red, green, blue }
    private static func channel(_ img: CIImage, keep: Chan) -> CIImage {
        let f = CIFilter.colorMatrix(); f.inputImage = img
        f.rVector = CIVector(x: keep == .red ? 1 : 0, y: 0, z: 0, w: 0)
        f.gVector = CIVector(x: 0, y: keep == .green ? 1 : 0, z: 0, w: 0)
        f.bVector = CIVector(x: 0, y: 0, z: keep == .blue ? 1 : 0, w: 0)
        f.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return f.outputImage ?? img
    }
    private static func screenBlend(_ input: CIImage, over background: CIImage) -> CIImage {
        let f = CIFilter.screenBlendMode(); f.inputImage = input; f.backgroundImage = background
        return f.outputImage ?? background
    }

    // MARK: - Outline layers

    private static func outlineLayers(subject: CIImage, look: LayerLook, over background: CIImage,
                                      canvas: CGRect, borderW: CGFloat, glowR: CGFloat,
                                      shOffset: CGFloat, shBlur: CGFloat) -> CIImage {
        let longest = max(subject.extent.width, subject.extent.height)
        var layers = background

        // independent drop shadow (driven by the Shadow sliders), behind everything
        if look.shadowOpacity > 0 {
            layers = dropShadow(base: subject, onto: layers, canvas: canvas,
                                blur: shBlur, offset: shOffset, alpha: CGFloat(look.shadowOpacity))
        }

        // Only .custom and .dashed honor the user's outline color; named presets keep their literal color.
        let custom = look.outlineColor?.ci
        switch look.outline {
        case .none:
            if look.shadowOpacity == 0 {
                layers = dropShadow(base: subject, onto: layers, canvas: canvas,
                                    blur: longest * 0.03, offset: longest * 0.008, alpha: 0.14)
            }
        case .white:
            layers = composite(borderColor: .white, width: borderW, base: subject, over: layers, canvas: canvas)
        case .black:
            layers = composite(borderColor: .black, width: borderW, base: subject, over: layers, canvas: canvas)
        case .candy:
            layers = composite(borderColor: CIColor(red: 1.0, green: 0.28, blue: 0.58), width: borderW, base: subject, over: layers, canvas: canvas)
        case .mint:
            layers = composite(borderColor: CIColor(red: 0.20, green: 0.85, blue: 0.70), width: borderW, base: subject, over: layers, canvas: canvas)
        case .custom:
            layers = composite(borderColor: custom ?? .white, width: borderW, base: subject, over: layers, canvas: canvas)
        case .glow:
            let glow = coloredSilhouette(base: subject, color: look.glowColor.ci, canvas: canvas)
            let blurred = blur(glow, radius: glowR).cropped(to: canvas)
            layers = sourceOver(blurred, over: layers)
            layers = sourceOver(blurred, over: layers)
            layers = composite(borderColor: .white, width: borderW * 0.7, base: subject, over: layers, canvas: canvas)
        case .pop:
            layers = dropShadow(base: subject, onto: layers, canvas: canvas,
                                blur: longest * 0.07, offset: longest * 0.03, alpha: 0.35)
            layers = composite(borderColor: .white, width: borderW, base: subject, over: layers, canvas: canvas)
        case .sticker:
            // double rim: dark outer, white inner
            layers = composite(borderColor: CIColor(red: 0.1, green: 0.1, blue: 0.12), width: borderW * 1.8, base: subject, over: layers, canvas: canvas)
            layers = composite(borderColor: .white, width: borderW, base: subject, over: layers, canvas: canvas)
        case .dashed:
            layers = dashedRing(base: subject, color: custom ?? CIColor(red: 0.1, green: 0.1, blue: 0.12),
                                width: borderW * 1.3, over: layers, canvas: canvas, longest: longest)
        }
        return layers
    }

    // MARK: - Background

    private static func backgroundFill(_ e: StickerEdit, canvas: CGRect, original: UIImage?) -> CIImage? {
        switch e.background {
        case .none: return nil
        case .white, .ink, .sunset, .ocean, .candy, .mint, .gold:
            let (t, b) = e.background.presetColors!
            return rounded(gradientFill(canvas: canvas, top: CIColor(color: t), bottom: CIColor(color: b)), e, canvas)
        case .solid:
            return rounded(CIImage(color: e.bgSolidColor.ci).cropped(to: canvas), e, canvas)
        case .gradient:
            return rounded(gradientFill(canvas: canvas, top: e.bgGradientTop.ci, bottom: e.bgGradientBottom.ci), e, canvas)
        case .dots, .stripes, .checker:
            return rounded(patternImage(e.background, canvas: canvas), e, canvas)
        case .blurred:
            guard let original, let cg = original.cgImage else { return nil }
            var img = CIImage(cgImage: cg)
            img = aspectFill(img, into: canvas)
            let b = CIFilter.gaussianBlur(); b.inputImage = img.clampedToExtent()
            b.radius = Float(max(canvas.width, canvas.height) * 0.06)
            img = (b.outputImage ?? img).cropped(to: canvas)
            let c = CIFilter.colorControls(); c.inputImage = img; c.brightness = -0.08; c.saturation = 1.1
            return rounded((c.outputImage ?? img).cropped(to: canvas), e, canvas)
        }
    }

    private static func aspectFill(_ image: CIImage, into canvas: CGRect) -> CIImage {
        let s = max(canvas.width / image.extent.width, canvas.height / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let dx = canvas.midX - scaled.extent.midX, dy = canvas.midY - scaled.extent.midY
        return scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy)).cropped(to: canvas)
    }

    private static func rounded(_ fill: CIImage, _ e: StickerEdit, _ canvas: CGRect) -> CIImage {
        guard e.bgCornerRadius > 0 else { return fill.cropped(to: canvas) }
        let r = min(canvas.width, canvas.height) * CGFloat(e.bgCornerRadius)
        // scale MUST be 1 so the mask's pixel size equals the canvas extent in Core Image space;
        // the default renderer scale (screen 2x/3x) would make the mask 2-3x too big and misalign.
        let fmt = UIGraphicsImageRendererFormat.default(); fmt.scale = 1; fmt.opaque = true
        let renderer = UIGraphicsImageRenderer(size: canvas.size, format: fmt)
        let maskImg = renderer.image { _ in
            UIColor.white.setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: canvas.size), cornerRadius: r).fill()
        }
        guard let mcg = maskImg.cgImage else { return fill.cropped(to: canvas) }
        let mask = CIImage(cgImage: mcg)
        return blendWithMask(input: fill, background: CIImage(color: .clear).cropped(to: canvas), mask: mask).cropped(to: canvas)
    }

    private static func patternImage(_ bg: StickerBackground, canvas: CGRect) -> CIImage {
        let size = canvas.size
        let fmt = UIGraphicsImageRendererFormat.default(); fmt.scale = 1; fmt.opaque = true
        let r = UIGraphicsImageRenderer(size: size, format: fmt)
        let img = r.image { context in
            let c = context.cgContext
            let base = UIColor(white: 0.97, alpha: 1)
            base.setFill(); c.fill(CGRect(origin: .zero, size: size))
            let step = max(size.width, size.height) * 0.06
            switch bg {
            case .dots:
                UIColor(red: 1.0, green: 0.55, blue: 0.45, alpha: 1).setFill()
                var y = step / 2
                while y < size.height {
                    var x = step / 2
                    while x < size.width {
                        c.fillEllipse(in: CGRect(x: x - step * 0.18, y: y - step * 0.18, width: step * 0.36, height: step * 0.36))
                        x += step
                    }
                    y += step
                }
            case .stripes:
                UIColor(red: 0.30, green: 0.78, blue: 0.74, alpha: 1).setFill()
                var x = -size.height
                while x < size.width {
                    let path = UIBezierPath()
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x + step * 0.5, y: 0))
                    path.addLine(to: CGPoint(x: x + step * 0.5 + size.height, y: size.height))
                    path.addLine(to: CGPoint(x: x + size.height, y: size.height))
                    path.close(); path.fill()
                    x += step
                }
            case .checker:
                UIColor(white: 0.85, alpha: 1).setFill()
                var row = 0
                while CGFloat(row) * step < size.height {
                    var col = 0
                    while CGFloat(col) * step < size.width {
                        if (row + col) % 2 == 0 {
                            c.fill(CGRect(x: CGFloat(col) * step, y: CGFloat(row) * step, width: step, height: step))
                        }
                        col += 1
                    }
                    row += 1
                }
            default: break
            }
        }
        guard let cg = img.cgImage else { return CIImage(color: .white).cropped(to: canvas) }
        return CIImage(cgImage: cg).cropped(to: canvas)
    }

    // MARK: - Text

    private static func drawText(_ text: StickerText, on image: UIImage) -> UIImage {
        let size = image.size
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1; format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { rendererCtx in
            image.draw(in: CGRect(origin: .zero, size: size))
            let fontSize = max(18, size.width * CGFloat(text.sizeFraction))
            let font = text.font.uiFont(size: fontSize, weight: .heavy)
            let para = NSMutableParagraphStyle(); para.alignment = .center
            let fill = text.uiColor
            let stroke = text.strokeColor?.ui ?? (fill == .black ? UIColor.white : UIColor.black)
            var attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: fill,
                .paragraphStyle: para,
                .kern: fontSize * CGFloat(text.kern),
            ]
            if text.stroked {
                attrs[.strokeColor] = stroke
                // lighter stroke: 0.12 floods heavy/script fonts to a solid blob and spikes miter joins
                attrs[.strokeWidth] = -fontSize * 0.05
            }
            if text.shadowed {
                let sh = NSShadow(); sh.shadowBlurRadius = fontSize * 0.12
                sh.shadowOffset = CGSize(width: 0, height: fontSize * 0.06)
                sh.shadowColor = UIColor.black.withAlphaComponent(0.5)
                attrs[.shadow] = sh
            }
            let string = text.uppercase ? text.string.uppercased() : text.string

            if text.isCurved {
                drawArcText(string, attrs: attrs, fontSize: fontSize, text: text,
                            in: size, cg: rendererCtx.cgContext)
                return
            }

            let str = NSAttributedString(string: string, attributes: attrs)
            let maxRect = CGRect(x: size.width * 0.06, y: 0, width: size.width * 0.88, height: size.height)
            let bounds = str.boundingRect(with: maxRect.size, options: [.usesLineFragmentOrigin], context: nil)
            // boundingRect under-reports for heavy fonts; pad so descenders/stroke/shadow aren't clipped
            let drawH = ceil(bounds.height + fontSize * 0.4)
            let y: CGFloat
            switch text.position {
            case .top: y = size.height * 0.07
            case .middle: y = (size.height - drawH) / 2
            case .bottom: y = size.height * 0.9 - drawH
            }
            str.draw(with: CGRect(x: maxRect.minX, y: y, width: maxRect.width, height: drawH),
                     options: [.usesLineFragmentOrigin], context: nil)
        }
    }

    /// Draw a caption bent around a circular arc. Each glyph is rotated to sit on the curve. `curve`
    /// (-1...1) sets the total sweep and direction: positive arcs UP (smile), negative arcs DOWN (frown).
    private static func drawArcText(_ string: String, attrs: [NSAttributedString.Key: Any],
                                    fontSize: CGFloat, text: StickerText, in size: CGSize, cg: CGContext) {
        let chars = Array(string)
        guard !chars.isEmpty else { return }
        // Per-glyph advances (with kern) so spacing matches the straight path.
        let kern = fontSize * CGFloat(text.kern)
        let widths: [CGFloat] = chars.map { ch in
            NSAttributedString(string: String(ch), attributes: attrs).size().width + kern
        }
        let totalWidth = widths.reduce(0, +)
        // Sweep angle: clamp so even a long word stays readable.
        let sweep = CGFloat(max(-1, min(1, text.curve))) * (.pi * 0.9)
        let arcLen = max(totalWidth, fontSize)
        // radius from arc length & sweep (R = L / |θ|); guard tiny angles.
        let radius = arcLen / max(0.0001, abs(sweep))
        let up = text.curve >= 0
        // Center the arc horizontally; place vertically by the text position.
        let cx = size.width / 2
        let cy: CGFloat
        switch text.position {
        case .top: cy = up ? size.height * 0.07 + radius : size.height * 0.20 - radius
        case .middle: cy = up ? size.height * 0.5 + radius * 0.5 : size.height * 0.5 - radius * 0.5
        case .bottom: cy = up ? size.height * 0.93 + radius - fontSize : size.height * 0.80 - radius
        }
        // Walk glyphs from -sweep/2 to +sweep/2 along the arc.
        var advanced: CGFloat = 0
        for (i, ch) in chars.enumerated() {
            let mid = advanced + widths[i] / 2
            // fraction along the arc (0...1) -> angle offset
            let frac = totalWidth > 0 ? mid / totalWidth : 0.5
            let theta = sweep * (frac - 0.5)
            let glyph = NSAttributedString(string: String(ch), attributes: attrs)
            let gSize = glyph.size()
            cg.saveGState()
            // Position on the circle. For an UP arc the glyphs sit ABOVE the center; for DOWN, below.
            let px = cx + sin(theta) * radius
            let py = up ? cy - cos(theta) * radius : cy + cos(theta) * radius
            cg.translateBy(x: px, y: py)
            cg.rotate(by: up ? theta : -theta)
            glyph.draw(at: CGPoint(x: -gSize.width / 2, y: -gSize.height / 2))
            cg.restoreGState()
            advanced += widths[i]
        }
    }

    // MARK: - Core Image helpers

    private static func gradientFill(canvas: CGRect, top: CIColor, bottom: CIColor) -> CIImage {
        let f = CIFilter.linearGradient()
        f.point0 = CGPoint(x: canvas.midX, y: canvas.maxY)
        f.point1 = CGPoint(x: canvas.midX, y: canvas.minY)
        f.color0 = top
        f.color1 = bottom
        return (f.outputImage ?? CIImage(color: top)).cropped(to: canvas)
    }

    private static func composite(borderColor: CIColor, width: CGFloat,
                                  base: CIImage, over background: CIImage, canvas: CGRect) -> CIImage {
        let mask = alphaLuma(dilate(base, radius: width))
        let colorImg = CIImage(color: borderColor).cropped(to: canvas)
        let borderLayer = blendWithMask(input: colorImg, background: CIImage(color: .clear).cropped(to: canvas), mask: mask).cropped(to: canvas)
        return sourceOver(borderLayer, over: background)
    }
    private static func dashedRing(base: CIImage, color: CIColor, width: CGFloat, over background: CIImage,
                                   canvas: CGRect, longest: CGFloat) -> CIImage {
        // ring = dilated silhouette minus original silhouette
        let outer = alphaLuma(dilate(base, radius: width))
        let inner = alphaLuma(base)
        let ringMask = subtractMask(outer, inner)
        // Isotropic dashes from a checkerboard so they read as a cut-line on ALL edge orientations
        // (a single-axis stripe pattern degenerates into solid bars on the parallel edges).
        // BUG FIX: use OPAQUE black/white squares and take their LUMA as the on/off mask. The old code
        // used a `.clear` square whose premultiplied alpha bled a faint full-silhouette halo when
        // multiplied across the canvas. The dash mask is then clipped to the ring BAND via `ringMask`,
        // so dashes can only ever appear inside the thin ring — never as a wash over the subject.
        let checker = CIFilter.checkerboardGenerator()
        checker.center = CGPoint(x: canvas.midX, y: canvas.midY)
        checker.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)   // dash "on"
        checker.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 1)   // gap "off" (opaque, no alpha bleed)
        checker.width = Float(max(4, longest * 0.025))
        checker.sharpness = 1
        let dashLuma = lumaMask((checker.outputImage ?? CIImage(color: .white)).cropped(to: canvas))
        // dash mask = ring band AND dash-on squares -> strictly inside the ring
        let dashMask = multiplyMask(ringMask, dashLuma).cropped(to: canvas)
        let colorImg = CIImage(color: color).cropped(to: canvas)
        let ring = blendWithMask(input: colorImg, background: CIImage(color: .clear).cropped(to: canvas), mask: dashMask).cropped(to: canvas)
        return sourceOver(ring, over: background)
    }
    /// A mask whose alpha = the input's luminance (used to read opaque black/white dashes as on/off).
    private static func lumaMask(_ image: CIImage) -> CIImage {
        let f = CIFilter.colorMatrix(); f.inputImage = image
        // collapse RGB->alpha by luma; zero the color channels so it's a clean coverage mask
        f.rVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        f.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        f.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        f.aVector = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        return f.outputImage ?? image
    }
    private static func coloredSilhouette(base: CIImage, color: CIColor, canvas: CGRect) -> CIImage {
        blendWithMask(input: CIImage(color: color).cropped(to: canvas),
                      background: CIImage(color: .clear).cropped(to: canvas), mask: alphaLuma(base)).cropped(to: canvas)
    }
    private static func dropShadow(base: CIImage, onto background: CIImage, canvas: CGRect,
                                   blur radius: CGFloat, offset: CGFloat, alpha: CGFloat) -> CIImage {
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: alpha)).cropped(to: canvas)
        let shadow = blendWithMask(input: black, background: CIImage(color: .clear).cropped(to: canvas), mask: alphaLuma(base))
        let moved = shadow.transformed(by: CGAffineTransform(translationX: 0, y: -offset))
        return sourceOver(blur(moved, radius: radius).cropped(to: canvas), over: background)
    }
    private static func dilate(_ image: CIImage, radius: CGFloat) -> CIImage {
        let f = CIFilter.morphologyMaximum(); f.inputImage = image.clampedToExtent(); f.radius = Float(radius); return f.outputImage ?? image
    }
    private static func featheredMask(_ image: CIImage, feather: Double) -> CIImage {
        let mask = alphaLuma(image)
        guard feather > 0 else { return mask }
        let longest = max(image.extent.width, image.extent.height)
        let r = max(1, longest * CGFloat(feather) * 0.01)
        let e = CIFilter.morphologyMinimum(); e.inputImage = mask.clampedToExtent(); e.radius = Float(r)
        let eroded = (e.outputImage ?? mask).cropped(to: image.extent)
        return blur(eroded, radius: r).cropped(to: image.extent)
    }
    private static func alphaLuma(_ image: CIImage) -> CIImage {
        let f = CIFilter.colorMatrix(); f.inputImage = image
        f.rVector = CIVector(x: 0, y: 0, z: 0, w: 1); f.gVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        f.bVector = CIVector(x: 0, y: 0, z: 0, w: 1); f.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        f.biasVector = CIVector(x: 0, y: 0, z: 0, w: 1); return f.outputImage ?? image
    }
    private static func subtractMask(_ a: CIImage, _ b: CIImage) -> CIImage {
        // a AND (NOT b): multiply a by inverted b
        let inv = CIFilter.colorInvert(); inv.inputImage = b
        return multiplyMask(a, inv.outputImage ?? b)
    }
    private static func multiplyMask(_ a: CIImage, _ b: CIImage) -> CIImage {
        let f = CIFilter.multiplyCompositing(); f.inputImage = a; f.backgroundImage = b; return f.outputImage ?? a
    }
    private static func blur(_ image: CIImage, radius: CGFloat) -> CIImage {
        let f = CIFilter.gaussianBlur(); f.inputImage = image.clampedToExtent(); f.radius = Float(radius); return f.outputImage ?? image
    }
    /// Scale a layer-composite's alpha uniformly (per-layer opacity, 0...1).
    private static func applyOpacity(_ image: CIImage, _ opacity: Double) -> CIImage {
        let f = CIFilter.colorMatrix(); f.inputImage = image
        f.aVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(max(0, min(1, opacity))))
        return f.outputImage ?? image
    }
    private static func blendWithMask(input: CIImage, background: CIImage, mask: CIImage) -> CIImage {
        let f = CIFilter.blendWithMask(); f.inputImage = input; f.backgroundImage = background; f.maskImage = mask; return f.outputImage ?? input
    }
    private static func sourceOver(_ input: CIImage, over background: CIImage) -> CIImage {
        let f = CIFilter.sourceOverCompositing(); f.inputImage = input; f.backgroundImage = background; return f.outputImage ?? background
    }

    // MARK: - Export crop (die-cut to content bounds)

    private static func alphaCropped(_ image: UIImage, padFraction: CGFloat) -> UIImage {
        guard let cg = image.cgImage else { return image }
        let w = cg.width, h = cg.height
        let sample = 320.0
        let scale = min(1, sample / Double(max(w, h)))
        let sw = max(1, Int(Double(w) * scale)), sh = max(1, Int(Double(h) * scale))
        var pixels = [UInt8](repeating: 0, count: sw * sh * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let bmp = CGContext(data: &pixels, width: sw, height: sh, bitsPerComponent: 8,
                                  bytesPerRow: sw * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        bmp.draw(cg, in: CGRect(x: 0, y: 0, width: sw, height: sh))
        var minX = sw, minY = sh, maxX = 0, maxY = 0
        for y in 0..<sh {
            for x in 0..<sw where pixels[(y * sw + x) * 4 + 3] > 10 {
                if x < minX { minX = x }; if x > maxX { maxX = x }
                if y < minY { minY = y }; if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return image }
        let inv = 1.0 / scale
        let pad = CGFloat(max(w, h)) * padFraction
        var rect = CGRect(x: CGFloat(minX) * inv - pad,
                          y: CGFloat(minY) * inv - pad,
                          width: CGFloat(maxX - minX + 1) * inv + pad * 2,
                          height: CGFloat(maxY - minY + 1) * inv + pad * 2)
        rect = rect.intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard let cropped = cg.cropping(to: rect) else { return image }
        return UIImage(cgImage: cropped)
    }
}
