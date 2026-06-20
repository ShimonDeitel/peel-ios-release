import SwiftUI
import UIKit

/// Owns the user's saved stickers, persisted as transparent PNGs in the App Group
/// container with a JSON index. Shared, file-based, and readable by the iMessage extension.
@MainActor
final class StickerStore: ObservableObject {
    @Published private(set) var records: [StickerRecord] = []

    init() { reload() }

    func reload() {
        // Fault-tolerant: a missing index (fresh install) or a partially-corrupt/legacy index never crashes
        // and never blanks the whole library — un-decodable rows are skipped, the rest load. (See
        // AppGroup.decodeStickerRecords.)
        guard let url = AppGroup.indexURL, let data = try? Data(contentsOf: url) else {
            records = []
            return
        }
        records = AppGroup.decodeStickerRecords(data).sorted { $0.createdAt > $1.createdAt }
    }

    func image(for record: StickerRecord) -> UIImage? {
        guard let dir = AppGroup.stickersDirectory else { return nil }
        return UIImage(contentsOfFile: dir.appendingPathComponent(record.file).path)
    }

    enum AddResult { case added(StickerRecord), failed }

    /// Saves a rendered sticker PNG to the App Group and updates the index. The library is unlimited;
    /// the only creation cap is the daily quota (see DailyQuota), enforced by the editor before saving.
    ///
    /// When an editable `edit` is supplied, its full `StickerEdit` JSON is written as a `.peelproj`
    /// SIDECAR beside the PNG (via `ProjectStore`) so the sticker re-opens non-destructively. Best-effort:
    /// a failed sidecar never blocks the sticker — old PNGs simply have no sidecar and open read-only.
    @discardableResult
    func add(_ image: UIImage, edit: StickerEdit? = nil, templateID: String? = nil) -> AddResult {
        reload() // re-sync against disk
        guard let dir = AppGroup.stickersDirectory else { return .failed }
        // iMessage requires each sticker file <= 500KB; cap the longest side and compress.
        let capped = image.cappedToLongestSide(600)
        guard let data = capped.pngData(under: 500_000) else { return .failed }
        let id = UUID().uuidString
        let file = "\(id).png"
        do {
            try data.write(to: dir.appendingPathComponent(file), options: .atomic)
        } catch {
            return .failed
        }
        if let edit { ProjectStore.write(edit, forPNGFile: file) }
        // Record which Style-Wall look this came from, so a received sticker can be Remixed with it.
        let record = StickerRecord(id: id, file: file, createdAt: Date(), templateID: templateID)
        records.insert(record, at: 0)
        persist()
        return .added(record)
    }

    /// The re-openable project for a saved sticker, or nil for legacy PNGs with no sidecar.
    func project(for record: StickerRecord) -> StickerEdit? {
        ProjectStore.read(forPNGFile: record.file)
    }

    /// Removes ALL saved stickers (used by account deletion).
    func deleteAll() {
        if let dir = AppGroup.stickersDirectory {
            for r in records {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(r.file))
                ProjectStore.delete(forPNGFile: r.file)
            }
        }
        records.removeAll()
        persist()
    }

    func delete(_ record: StickerRecord) {
        guard let dir = AppGroup.stickersDirectory else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(record.file))
        ProjectStore.delete(forPNGFile: record.file)
        records.removeAll { $0.id == record.id }
        persist()
    }

    private func persist() {
        guard let url = AppGroup.indexURL else { return }
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

extension UIImage {
    func cappedToLongestSide(_ maxSide: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxSide else { return self }
        let scale = maxSide / longest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    /// PNG data, progressively downscaling until under the byte budget (keeps transparency).
    func pngData(under maxBytes: Int) -> Data? {
        var working = self
        for _ in 0..<8 {
            guard let data = working.pngData() else { return nil }
            if data.count <= maxBytes { return data }
            working = working.cappedToLongestSide(max(working.size.width, working.size.height) * 0.8)
        }
        // Still over budget after downscaling — fail rather than write a sticker iMessage rejects.
        if let data = working.pngData(), data.count <= maxBytes { return data }
        return nil
    }
}
