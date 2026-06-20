import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// One-tap Auto-Edit (Pro). Deterministic, 100% on-device — NO network, NO ML model. It samples a few
/// cheap Core Image statistics of the subject and writes concrete values into the edit's look fields,
/// so the result is a normal, fully tweakable (and resettable) StickerEdit. Layers, background and
/// text are left untouched — Auto-Edit enhances the photo, it doesn't reframe or add chrome.
enum AutoEdit {
    private static let ctx = CIContext(options: [.useSoftwareRenderer: false])

    static func enhance(_ edit: inout StickerEdit, primary cutout: UIImage) {
        guard let cg = cutout.cgImage else { return }
        let ci = CIImage(cgImage: cg)
        guard let avg = areaAverage(ci, ci.extent), avg.a > 0.02 else { return }

        // Alpha-correct the premultiplied average so transparent pixels never bias the result.
        let A = avg.a
        let R = avg.r / A, G = avg.g / A, B = avg.b / A
        let L = 0.2126 * R + 0.7152 * G + 0.0722 * B
        let maxC = max(R, max(G, B)), minC = min(R, min(G, B))
        let S = maxC <= 0 ? 0 : (maxC - minC) / maxC
        let cast = R - B
        let (H, _, _) = rgbToHSV(R, G, B)
        let skin = (R > G && G > B && (R - B) > 0.05 && (R - B) < 0.45 &&
                    H >= 5 && H <= 55 && S >= 0.15 && S <= 0.55 && L >= 0.25 && L <= 0.85)

        // Baseline pop (overridden by branches below).
        edit.filter = .none
        edit.contrast = 1.10; edit.saturation = 1.06; edit.vibrance = 0.20
        edit.exposure = 0; edit.brightness = 0; edit.highlights = 1.0; edit.shadows = 0; edit.hue = 0; edit.tint = 0

        // Tone
        if L < 0.32 {
            edit.exposure = 0.45; edit.brightness = 0.08; edit.contrast = max(edit.contrast, 1.14)
        } else if L > 0.78 {
            edit.exposure = -0.20; edit.brightness = -0.05; edit.contrast = 1.18
        } else {
            edit.brightness = 0.03
        }

        // Color
        if S < 0.12 {
            edit.saturation = 1.0; edit.contrast = max(edit.contrast, 1.16)
        } else if S < 0.30 {
            edit.saturation = 1.18; edit.vibrance = 0.35
        } else if S > 0.55 {
            edit.saturation = skin ? 0.98 : 1.0; edit.vibrance = 0.10
        }

        // White balance
        if cast > 0.10 && !skin { edit.warmth = -0.22 }
        else if cast < -0.10 { edit.warmth = 0.20 }
        else { edit.warmth = 0 }

        // Skin protection
        if skin {
            edit.warmth = clamp(edit.warmth + 0.10, -0.15, 0.30)
            edit.saturation = min(edit.saturation, 1.10)
            edit.vibrance = min(edit.vibrance, 0.25)
        }

        // Outline (complementary tint) + finish
        if S >= 0.18 && !skin {
            let hue = (H + 180).truncatingRemainder(dividingBy: 360)
            let oc = hsvToRGB(hue, 0.20, 0.97)
            edit.outline = .custom; edit.outlineColor = oc
            if S > 0.45 { edit.glowColor = oc; edit.glowRadius = 0.4 }
        } else {
            edit.outline = .white; edit.outlineColor = nil
        }
        // Guarantee the cutout never vanishes on a dark chat background.
        if L < 0.32, (edit.outlineColor?.value ?? 1) < 0.6 { edit.outline = .white; edit.outlineColor = nil }

        // Soft drop shadow — the single biggest "pro" tell.
        edit.shadowOpacity = 0.20; edit.shadowBlur = 0.45; edit.shadowOffset = 0.30

        // Clamp to documented ranges.
        edit.brightness = clamp(edit.brightness, -0.4, 0.4)
        edit.contrast = clamp(edit.contrast, 0.6, 1.5)
        edit.saturation = clamp(edit.saturation, 0, 2)
        edit.warmth = clamp(edit.warmth, -1, 1)
        edit.vibrance = clamp(edit.vibrance, -1, 1)
        edit.exposure = clamp(edit.exposure, -2, 2)
    }

    // MARK: - Stats

    private static func areaAverage(_ image: CIImage, _ extent: CGRect) -> (r: Double, g: Double, b: Double, a: Double)? {
        let f = CIFilter.areaAverage(); f.inputImage = image; f.extent = extent
        guard let out = f.outputImage else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        ctx.render(out, toBitmap: &px, rowBytes: 4,
                   bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                   format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return (Double(px[0]) / 255, Double(px[1]) / 255, Double(px[2]) / 255, Double(px[3]) / 255)
    }

    // MARK: - Color math

    /// Returns hue in degrees (0..360), saturation 0..1, value 0..1.
    private static func rgbToHSV(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let maxC = max(r, max(g, b)), minC = min(r, min(g, b))
        let delta = maxC - minC
        var h = 0.0
        if delta > 0 {
            if maxC == r { h = 60 * (((g - b) / delta).truncatingRemainder(dividingBy: 6)) }
            else if maxC == g { h = 60 * (((b - r) / delta) + 2) }
            else { h = 60 * (((r - g) / delta) + 4) }
        }
        if h < 0 { h += 360 }
        let s = maxC <= 0 ? 0 : delta / maxC
        return (h, s, maxC)
    }

    private static func hsvToRGB(_ h: Double, _ s: Double, _ v: Double) -> RGBAColor {
        let c = v * s
        let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c
        let (r1, g1, b1): (Double, Double, Double)
        switch h {
        case 0..<60: (r1, g1, b1) = (c, x, 0)
        case 60..<120: (r1, g1, b1) = (x, c, 0)
        case 120..<180: (r1, g1, b1) = (0, c, x)
        case 180..<240: (r1, g1, b1) = (0, x, c)
        case 240..<300: (r1, g1, b1) = (x, 0, c)
        default: (r1, g1, b1) = (c, 0, x)
        }
        return RGBAColor(r1 + m, g1 + m, b1 + m, 1)
    }

    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }
}
