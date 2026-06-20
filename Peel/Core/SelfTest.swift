#if DEBUG
import UIKit

/// Headless verification of the on-device pipeline. Runs only when launched with
/// `-PeelSelfTest`; reads Documents/selftest.jpg, runs the real Vision cutout + every
/// render style, writes outputs to Documents/SelfTest/, prints a summary, then exits.
enum SelfTest {
    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-PeelSelfTest") else { return }
        Task.detached(priority: .userInitiated) {
            await run()
            exit(0)
        }
    }

    static func run() async {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let src = docs.appendingPathComponent("selftest.jpg")
        guard let data = try? Data(contentsOf: src), let img = UIImage(data: data) else {
            log("FAIL: no input at \(src.path)"); return
        }
        let outDir = docs.appendingPathComponent("SelfTest")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        log("input \(Int(img.size.width))x\(Int(img.size.height))")
        do {
            let cutout = try await SubjectLift.cutout(from: img)
            let cov = coverage(cutout)
            try? cutout.pngData()?.write(to: outDir.appendingPathComponent("cutout.png"))
            log(String(format: "cutout %dx%d alphaCoverage=%.1f%%",
                       Int(cutout.size.width), Int(cutout.size.height), cov * 100))
            for style in OutlineStyle.allCases {
                let r = StickerRenderer.render(cutout: cutout, style: style)
                if let d = r.pngData(under: 500_000) {
                    try? d.write(to: outDir.appendingPathComponent("style_\(style.rawValue).png"))
                    log(String(format: "style %@ -> %dx%d %dKB", style.rawValue,
                               Int(r.size.width), Int(r.size.height), d.count / 1024))
                }
            }
            log("DONE OK outDir=\(outDir.path)")
        } catch {
            log("FAIL: \(error)")
        }
    }

    private static func coverage(_ image: UIImage) -> Double {
        guard let cg = image.cgImage else { return 0 }
        let w = 64, h = 64
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var on = 0
        for i in stride(from: 3, to: px.count, by: 4) where px[i] > 10 { on += 1 }
        return Double(on) / Double(w * h)
    }

    private static func log(_ s: String) {
        print("SELFTEST: \(s)")
        NSLog("SELFTEST: %@", s)
    }
}
#endif
