import UIKit

/// Writes a finished sticker to a temporary transparent PNG FILE so the system share sheet hands receiving
/// apps (WhatsApp, Instagram, Telegram, Messages, Mail, Files, AirDrop…) a real `.png` with its alpha
/// preserved. Sharing a bare `UIImage` lets some targets re-encode it as an opaque JPEG (losing the die-cut
/// transparency); a `.png` file URL is accepted everywhere and stays transparent.
enum SharePNG {
    /// Write `image` as a transparent PNG into a uniquely-named temp file. Returns the file URL, or nil on
    /// failure (callers fall back to sharing the raw `UIImage`). Old peel-share PNGs are swept first so the
    /// temp dir doesn't accumulate.
    static func write(_ image: UIImage, name: String = "Sticker") -> URL? {
        guard let data = image.pngData() else { return nil }
        let dir = FileManager.default.temporaryDirectory
        sweepOld(in: dir)
        // A clean, human-friendly filename (what shows up as the shared item's title).
        let safe = name.components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        let file = "peel-share-\(safe.isEmpty ? "Sticker" : safe)-\(UUID().uuidString.prefix(6)).png"
        let url = dir.appendingPathComponent(file)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Best-effort cleanup of previously-shared temp PNGs (keeps the temp directory tidy; never throws).
    private static func sweepOld(in dir: URL) {
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for u in items where u.lastPathComponent.hasPrefix("peel-share-") {
            try? FileManager.default.removeItem(at: u)
        }
    }
}
