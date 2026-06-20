import UIKit
import CoreImage

/// Builds the pixel cutouts for the non-photo layer kinds the editor can add — emoji glyphs, solid
/// shapes — and trims a cutout to its content bounds. Everything is on-device Core Graphics / Core Image;
/// no network, no paid APIs. Each returns a transparent PNG-ready `UIImage` so it drops straight into a
/// `StickerLayer` and rides the SAME renderer path (adjust → filter → outline → place) as a lifted subject.
enum LayerFactory {

    /// Render an emoji (or any short string of glyphs) into a transparent, tightly-cropped image. The
    /// glyph is drawn large, then alpha-cropped so the layer's bounds hug the emoji (clean selection box).
    static func emoji(_ string: String, side: CGFloat = 512) -> UIImage {
        let fontSize = side * 0.82
        let font = UIFont.systemFont(ofSize: fontSize)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let str = NSAttributedString(string: string, attributes: attrs)
        let textSize = str.size()
        let canvas = CGSize(width: max(textSize.width, 1), height: max(textSize.height, 1))
        let fmt = UIGraphicsImageRendererFormat.default(); fmt.opaque = false; fmt.scale = 1
        let raw = UIGraphicsImageRenderer(size: canvas, format: fmt).image { _ in
            str.draw(at: .zero)
        }
        return raw.trimmedToAlpha() ?? raw
    }

    /// A solid filled shape (the look's fill is applied later via tint; here we draw it WHITE so the
    /// renderer's color/adjust pipeline can recolor it). Returns a transparent image with the shape's alpha.
    static func shape(_ kind: ShapeKind, color: UIColor, side: CGFloat = 512) -> UIImage {
        let size = CGSize(width: side, height: side)
        let fmt = UIGraphicsImageRendererFormat.default(); fmt.opaque = false; fmt.scale = 1
        let inset = side * 0.06
        let rect = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            color.setFill()
            path(for: kind, in: rect).fill()
        }
    }

    /// The bezier path for a shape kind within a rect.
    static func path(for kind: ShapeKind, in rect: CGRect) -> UIBezierPath {
        switch kind {
        case .circle:
            return UIBezierPath(ovalIn: rect)
        case .roundedRect:
            return UIBezierPath(roundedRect: rect, cornerRadius: rect.width * 0.16)
        case .triangle:
            let p = UIBezierPath()
            p.move(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.close()
            return p
        case .star:
            return starPath(in: rect, points: 5, smoothness: 0.45)
        case .heart:
            return heartPath(in: rect)
        }
    }

    private static func starPath(in rect: CGRect, points: Int, smoothness: CGFloat) -> UIBezierPath {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * smoothness
        let path = UIBezierPath()
        let step = CGFloat.pi / CGFloat(points)
        var angle = -CGFloat.pi / 2
        for i in 0..<(points * 2) {
            let r = (i % 2 == 0) ? outer : inner
            let pt = CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r)
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            angle += step
        }
        path.close()
        return path
    }

    private static func heartPath(in rect: CGRect) -> UIBezierPath {
        let w = rect.width, h = rect.height
        let p = UIBezierPath()
        let topCusp = CGPoint(x: rect.minX + w * 0.5, y: rect.minY + h * 0.28)
        p.move(to: CGPoint(x: rect.minX + w * 0.5, y: rect.minY + h * 0.95))
        p.addCurve(to: CGPoint(x: rect.minX, y: rect.minY + h * 0.30),
                   controlPoint1: CGPoint(x: rect.minX + w * 0.18, y: rect.minY + h * 0.72),
                   controlPoint2: CGPoint(x: rect.minX, y: rect.minY + h * 0.52))
        p.addArc(withCenter: CGPoint(x: rect.minX + w * 0.25, y: rect.minY + h * 0.27),
                 radius: w * 0.25, startAngle: .pi, endAngle: 0, clockwise: true)
        p.addLine(to: topCusp)
        p.addArc(withCenter: CGPoint(x: rect.minX + w * 0.75, y: rect.minY + h * 0.27),
                 radius: w * 0.25, startAngle: .pi, endAngle: 0, clockwise: true)
        p.addCurve(to: CGPoint(x: rect.minX + w * 0.5, y: rect.minY + h * 0.95),
                   controlPoint1: CGPoint(x: rect.maxX, y: rect.minY + h * 0.52),
                   controlPoint2: CGPoint(x: rect.minX + w * 0.82, y: rect.minY + h * 0.72))
        p.close()
        return p
    }
}

extension UIImage {
    /// Crop this image to the bounding box of its non-transparent pixels, with a small pad. Returns nil
    /// (so callers can keep the original) when the image is fully transparent or already tight.
    func trimmedToAlpha(padFraction: CGFloat = 0.02) -> UIImage? {
        guard let cg = cgImage else { return nil }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return nil }
        // Downsample the scan for speed; bounds are scaled back up.
        let sample = 400.0
        let s = min(1, sample / Double(max(w, h)))
        let sw = max(1, Int(Double(w) * s)), sh = max(1, Int(Double(h) * s))
        var px = [UInt8](repeating: 0, count: sw * sh * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let bmp = CGContext(data: &px, width: sw, height: sh, bitsPerComponent: 8,
                                  bytesPerRow: sw * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        bmp.draw(cg, in: CGRect(x: 0, y: 0, width: sw, height: sh))
        var minX = sw, minY = sh, maxX = 0, maxY = 0
        for y in 0..<sh {
            for x in 0..<sw where px[(y * sw + x) * 4 + 3] > 8 {
                if x < minX { minX = x }; if x > maxX { maxX = x }
                if y < minY { minY = y }; if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let inv = 1.0 / s
        let pad = CGFloat(max(w, h)) * padFraction
        var rect = CGRect(x: CGFloat(minX) * inv - pad, y: CGFloat(minY) * inv - pad,
                          width: CGFloat(maxX - minX + 1) * inv + pad * 2,
                          height: CGFloat(maxY - minY + 1) * inv + pad * 2)
        rect = rect.intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard rect.width >= 1, rect.height >= 1, let cropped = cg.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cropped)
    }
}
