import XCTest
import UIKit
@testable import Peel

/// Covers the two Stage-2 features:
/// 1) The Cleanup brush (`MaskRefine`) — erase removes alpha where painted, restore brings it back, and
///    the brush respects the normalized top-left coordinate convention the canvas feeds it.
/// 2) Re-editable saved stickers — a `StickerEdit` survives a full Codable round-trip (the `.peelproj`
///    sidecar payload) with its layers, looks, text, and background intact.
@MainActor
final class CleanupAndReeditTests: XCTestCase {

    // MARK: - Cleanup brush (MaskRefine)

    /// A fully-opaque square so every pixel starts as "keep" — erasing must drive a region to transparent.
    private func opaqueCutout(_ side: Int = 120) -> UIImage {
        let size = CGSize(width: side, height: side)
        let fmt = UIGraphicsImageRendererFormat.default(); fmt.opaque = false; fmt.scale = 1
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// Alpha (0…255) at a normalized top-left point of an image's CGImage.
    private func alpha(_ image: UIImage, atFraction p: CGPoint) -> Int {
        guard let cg = image.cgImage else { return -1 }
        let x = max(0, min(cg.width - 1, Int(CGFloat(cg.width) * p.x)))
        let y = max(0, min(cg.height - 1, Int(CGFloat(cg.height) * p.y)))
        var px = [UInt8](repeating: 0, count: 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return -1 }
        ctx.draw(cg, in: CGRect(x: -x, y: -(cg.height - 1 - y), width: cg.width, height: cg.height))
        return Int(px[3])
    }

    func testEraseClearsPaintedRegionTopLeftOriented() throws {
        let cut = opaqueCutout()
        let refine = try XCTUnwrap(MaskRefine(cutout: cut))
        // Paint a stroke across the TOP-LEFT quadrant (normalized top-left coords).
        let pts = [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.3, y: 0.25), CGPoint(x: 0.25, y: 0.3)]
        let erased = refine.painting(.erase, points: pts, radius: 0.12).composite(defringe: false)

        // The painted top-left region should now be (near) transparent…
        XCTAssertLessThan(alpha(erased, atFraction: CGPoint(x: 0.25, y: 0.25)), 40,
                          "erase should clear alpha where painted (and at the correct top-left location)")
        // …while the opposite (bottom-right) corner stays fully opaque — proves no Y flip / wrong mapping.
        XCTAssertGreaterThan(alpha(erased, atFraction: CGPoint(x: 0.8, y: 0.8)), 200,
                             "unpainted region must remain opaque")
    }

    func testRestoreBringsBackErasedAlpha() throws {
        let cut = opaqueCutout()
        let base = try XCTUnwrap(MaskRefine(cutout: cut))
        let pts = [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.55, y: 0.5)]
        // Erase the center, then restore the same spot — alpha should come back toward opaque.
        let erased = base.painting(.erase, points: pts, radius: 0.15)
        XCTAssertLessThan(alpha(erased.composite(defringe: false), atFraction: CGPoint(x: 0.5, y: 0.5)), 60,
                          "precondition: center erased")
        let restored = erased.painting(.restore, points: pts, radius: 0.15).composite(defringe: false)
        XCTAssertGreaterThan(alpha(restored, atFraction: CGPoint(x: 0.5, y: 0.5)), 180,
                             "restore should bring back the erased alpha (clamped to the original lift)")
    }

    func testRestoreCannotExceedOriginalSilhouette() throws {
        // A cutout with a transparent half: restore must NOT invent alpha where the lift never had any.
        let side = 120
        let size = CGSize(width: side, height: side)
        let fmt = UIGraphicsImageRendererFormat.default(); fmt.opaque = false; fmt.scale = 1
        let halfCut = UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            UIColor.green.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: side / 2, height: side))   // left half opaque, right transparent
        }
        let refine = try XCTUnwrap(MaskRefine(cutout: halfCut))
        // Paint restore over the RIGHT (originally transparent) half.
        let pts = [CGPoint(x: 0.8, y: 0.3), CGPoint(x: 0.8, y: 0.7)]
        let out = refine.painting(.restore, points: pts, radius: 0.2).composite(defringe: false)
        XCTAssertLessThan(alpha(out, atFraction: CGPoint(x: 0.85, y: 0.5)), 40,
                          "restore must stay clamped to the original silhouette and not paint in new pixels")
    }

    // MARK: - Re-editable projects (StickerEdit Codable round-trip = the .peelproj payload)

    func testStickerEditSurvivesCodableRoundTrip() throws {
        let cut = RenderMatrixTests.syntheticCutout()
        var edit = StickerEdit()
        var layer = StickerLayer(cutout: cut)
        layer.look.brightness = 0.2
        layer.look.outline = .glow
        layer.look.glowColor = RGBAColor(1, 0.3, 0.6)
        layer.look.filter = .noir
        layer.look.text.string = "HELLO"
        layer.look.text.font = .impact
        layer.transform.center = CGPoint(x: 0.42, y: 0.58)
        layer.transform.scale = 1.3
        layer.opacity = 0.9
        layer.blend = .multiply
        layer.look.text.curve = 0.6
        edit.layers = [layer]
        edit.background = .gradient
        edit.bgGradientTop = RGBAColor(0.1, 0.2, 0.9)
        edit.bgCornerRadius = 0.25

        let data = try JSONEncoder().encode(edit)
        let decoded = try JSONDecoder().decode(StickerEdit.self, from: data)

        XCTAssertEqual(decoded.layers.count, 1)
        let dl = try XCTUnwrap(decoded.layers.first)
        XCTAssertEqual(dl.look.brightness, 0.2, accuracy: 0.0001)
        XCTAssertEqual(dl.look.outline, .glow)
        XCTAssertEqual(dl.look.filter, .noir)
        XCTAssertEqual(dl.look.text.string, "HELLO")
        XCTAssertEqual(dl.look.text.font, .impact)
        XCTAssertEqual(dl.transform.scale, 1.3, accuracy: 0.0001)
        XCTAssertEqual(dl.transform.center.x, 0.42, accuracy: 0.0001)
        XCTAssertEqual(dl.opacity, 0.9, accuracy: 0.0001)
        XCTAssertEqual(dl.blend, .multiply)
        XCTAssertEqual(dl.look.text.curve, 0.6, accuracy: 0.0001)
        XCTAssertEqual(decoded.background, .gradient)
        XCTAssertEqual(decoded.bgCornerRadius, 0.25, accuracy: 0.0001)
        // The layer's cutout pixels must survive (alpha-bearing PNG), so the sticker can re-render.
        XCTAssertNotNil(dl.cutout.cgImage)
        XCTAssertGreaterThan(dl.cutout.size.width, 10)
    }

    func testReopenedEditRendersWithoutCrash() throws {
        // Simulate the re-edit path: encode an edit, decode it, render it for export.
        let cut = RenderMatrixTests.syntheticCutout()
        var edit = StickerEdit(); edit.layers = [StickerLayer(cutout: cut)]
        edit.outline = .white
        let data = try JSONEncoder().encode(edit)
        let decoded = try JSONDecoder().decode(StickerEdit.self, from: data)
        let primary = try XCTUnwrap(decoded.primary)
        let img = StickerRenderer.renderForExport(edit: decoded, canvasLongSide: 600, original: primary.cutout)
        XCTAssertGreaterThan(img.size.width, 10)
        XCTAssertGreaterThan(img.size.height, 10)
    }
}
