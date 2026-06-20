import UIKit
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins

enum SubjectLiftError: Error { case noSubject, failed }

/// Lifts the foreground subject out of a photo entirely on-device using the Vision
/// foreground-instance mask (iOS 17+). Returns a tight, transparent cutout image.
enum SubjectLift {
    static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    static func cutout(from input: UIImage) async throws -> UIImage {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try makeCutout(from: input)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func makeCutout(from input: UIImage) throws -> UIImage {
        // Normalize orientation and cap size so Vision runs fast on huge photos.
        let normalized = input.orientationNormalized().cappedToLongestSide(2200)
        guard let cg = normalized.cgImage else { throw SubjectLiftError.failed }
        let ciImage = CIImage(cgImage: cg)

        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up)
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])

        guard let observation = request.results?.first,
              !observation.allInstances.isEmpty else {
            throw SubjectLiftError.noSubject
        }

        let maskBuffer = try observation.generateScaledMaskForImage(
            forInstances: observation.allInstances, from: handler)
        let maskCI = CIImage(cvPixelBuffer: maskBuffer)

        // Blend the original over a transparent background using the subject mask.
        let blend = CIFilter.blendWithMask()
        blend.inputImage = ciImage
        blend.backgroundImage = CIImage(color: .clear).cropped(to: ciImage.extent)
        blend.maskImage = maskCI
        guard let output = blend.outputImage else { throw SubjectLiftError.failed }

        // Crop tightly to the subject's alpha bounds.
        let cropRect = alphaBounds(of: output, in: ciImage.extent)
        let cropped = output.cropped(to: cropRect)
        guard let outCG = ciContext.createCGImage(cropped, from: cropped.extent) else {
            throw SubjectLiftError.failed
        }
        return UIImage(cgImage: outCG)
    }

    /// Tight bounding box of the non-transparent region, found from a downsampled alpha pass.
    private static func alphaBounds(of image: CIImage, in extent: CGRect) -> CGRect {
        let sample = 240.0
        let scale = min(1, sample / max(extent.width, extent.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let w = Int(small.extent.width.rounded()), h = Int(small.extent.height.rounded())
        guard w > 0, h > 0,
              let cg = ciContext.createCGImage(small, from: small.extent) else { return extent }

        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * h)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return extent }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var minX = w, minY = h, maxX = 0, maxY = 0
        for y in 0..<h {
            for x in 0..<w {
                if pixels[(y * bytesPerRow) + (x * 4) + 3] > 10 {
                    if x < minX { minX = x }; if x > maxX { maxX = x }
                    if y < minY { minY = y }; if y > maxY { maxY = y }
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return extent }
        // Map back to full-resolution CI coordinates (origin bottom-left).
        let pad: CGFloat = 2
        let fx = CGFloat(minX) / scale - pad
        let fw = CGFloat(maxX - minX + 1) / scale + pad * 2
        let fyTop = CGFloat(minY) / scale - pad
        let fh = CGFloat(maxY - minY + 1) / scale + pad * 2
        let fy = extent.height - (fyTop + fh) // flip
        return CGRect(x: fx, y: fy, width: fw, height: fh).intersection(extent)
    }
}

extension UIImage {
    func orientationNormalized() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
