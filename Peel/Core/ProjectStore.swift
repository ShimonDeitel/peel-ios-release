import UIKit

/// Re-openable projects. Every saved sticker PNG gets a `.peelproj` JSON SIDECAR holding the full
/// `StickerEdit` (now Codable) so the sticker reopens for non-destructive editing — same layers, same
/// per-layer looks, same background. Old PNGs from before this feature simply have no sidecar; reading
/// one returns `nil` and the caller opens the flat PNG read-only instead of crashing.
///
/// The sidecar lives beside the PNG in the App Group `Stickers` directory: `<id>.png` ↔ `<id>.peelproj`.
enum ProjectStore {
    static let sidecarExtension = "peelproj"

    /// Sidecar URL for a sticker PNG file name (e.g. `"ABC.png"` → `<stickers>/ABC.peelproj`).
    static func sidecarURL(forPNGFile file: String) -> URL? {
        guard let dir = AppGroup.stickersDirectory else { return nil }
        let base = (file as NSString).deletingPathExtension
        return dir.appendingPathComponent(base).appendingPathExtension(sidecarExtension)
    }

    /// Write the editable project next to a saved sticker. Best-effort: a failed sidecar must never block
    /// the sticker itself from saving (the PNG is the product; the sidecar is a convenience).
    @discardableResult
    static func write(_ edit: StickerEdit, forPNGFile file: String) -> Bool {
        guard let url = sidecarURL(forPNGFile: file) else { return false }
        do {
            let data = try encoder.encode(edit)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Read the editable project for a saved sticker, or `nil` when there's no sidecar (legacy PNG) or it
    /// fails to decode (model drift / corruption) — callers treat `nil` as "open read-only".
    static func read(forPNGFile file: String) -> StickerEdit? {
        guard let url = sidecarURL(forPNGFile: file),
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(StickerEdit.self, from: data)
    }

    /// Whether a re-openable project exists for this sticker (drives the "Edit" affordance in the UI).
    static func hasProject(forPNGFile file: String) -> Bool {
        guard let url = sidecarURL(forPNGFile: file) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Remove the sidecar when its sticker is deleted (keep the container tidy; safe if absent).
    static func delete(forPNGFile file: String) {
        guard let url = sidecarURL(forPNGFile: file) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Coders

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dataEncodingStrategy = .base64    // cutout PNGs encode as base64 (default, stated for clarity)
        return e
    }
    private static var decoder: JSONDecoder {
        JSONDecoder()
    }
}
