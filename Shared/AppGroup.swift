import Foundation

/// Shared between the Peel app and the PeelStickers iMessage extension.
/// Single source of truth for the App Group container layout and the Pro flag.
enum AppGroup {
    static let id = "group.com.joshuadeitel.peel"
    static let proKey = "isPro"
    static let creditsKey = "creditBalance"
    static let packsKey = "ownedStylePacks"

    static var defaults: UserDefaults? {
        UserDefaults(suiteName: id)
    }

    /// Whether the user has the UNLIMITED ceiling (the $9.99 one-time NonConsumable, or a grandfathered
    /// legacy `peel_pro_unlock` owner). Written by the app after a `.verified` StoreKit entitlement is
    /// confirmed; read by both app and extension. Unlimited bypasses the daily quota and credits.
    static var isPro: Bool {
        get { defaults?.bool(forKey: proKey) ?? false }
        set {
            defaults?.set(newValue, forKey: proKey)
        }
    }

    /// Remaining CONSUMABLE Sticker Credits. Each credit makes one sticker beyond the free daily limit.
    /// Credits never expire and are device-local for guests; grants come via Store's Transaction.updates
    /// path (consumables do NOT appear in `currentEntitlements`). Mirrored here so the iMessage extension
    /// and keyboard can read the balance.
    static var creditBalance: Int {
        get { max(0, defaults?.integer(forKey: creditsKey) ?? 0) }
        set { defaults?.set(max(0, newValue), forKey: creditsKey) }
    }

    /// Product IDs of the cosmetic Style Packs the user owns (NonConsumables). Read by the app to unlock
    /// locked Style-Wall tiles; mirrored for the extensions.
    static var ownedStylePacks: Set<String> {
        get { Set(defaults?.stringArray(forKey: packsKey) ?? []) }
        set { defaults?.set(Array(newValue).sorted(), forKey: packsKey) }
    }

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
    }

    // MARK: - Remix deep link (shared across app + extensions)

    /// The `peel://` URL scheme + `remix` host. Lives in Shared so the iMessage extension and keyboard can
    /// BUILD a remix link while the main app (which also has `RemixLink`) PARSES it.
    static let urlScheme = "peel"
    static let remixHost = "remix"

    /// `peel://remix?template=<id>` — opens the app, prompts for a fresh photo, applies that look. The id
    /// is a public built-in template, never user pixels, so it is safe to carry in a sticker filename.
    static func remixURL(templateID: String) -> URL? {
        var c = URLComponents()
        c.scheme = urlScheme
        c.host = remixHost
        c.queryItems = [URLQueryItem(name: "template", value: templateID)]
        return c.url
    }

    /// Directory holding the rendered transparent sticker PNGs.
    static var stickersDirectory: URL? {
        guard let base = containerURL else { return nil }
        let dir = base.appendingPathComponent("Stickers", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static var indexURL: URL? {
        containerURL?.appendingPathComponent("index.json")
    }

    /// Fault-tolerant decode of the sticker index: decodes the array element-by-element and SKIPS any entry
    /// that fails to decode, instead of throwing away the whole library when one legacy/corrupt row is bad.
    /// A fresh install (no file) and a totally unreadable file both yield `[]` — never a crash.
    static func decodeStickerRecords(_ data: Data) -> [StickerRecord] {
        // Fast path: a clean index decodes wholesale.
        if let items = try? JSONDecoder().decode([StickerRecord].self, from: data) {
            return items
        }
        // Lenient path: walk the array and keep only the rows that decode. `LenientRecord` wraps each
        // element so a single malformed entry decodes as `nil` rather than aborting the array.
        struct LenientRecord: Decodable {
            let value: StickerRecord?
            init(from decoder: Decoder) throws {
                value = try? StickerRecord(from: decoder)
            }
        }
        guard let wrapped = try? JSONDecoder().decode([LenientRecord].self, from: data) else { return [] }
        return wrapped.compactMap(\.value)
    }

    /// Sticker file URLs ordered newest-first. Reads the JSON index when present,
    /// otherwise falls back to a directory listing sorted by creation date.
    static func stickerFileURLs() -> [URL] {
        guard let dir = stickersDirectory else { return [] }
        if let indexURL, let data = try? Data(contentsOf: indexURL) {
            let items = decodeStickerRecords(data)
            if !items.isEmpty {
                return items
                    .sorted { $0.createdAt > $1.createdAt }
                    .map { dir.appendingPathComponent($0.file) }
                    .filter { FileManager.default.fileExists(atPath: $0.path) }
            }
        }
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return urls
            .filter { $0.pathExtension.lowercased() == "png" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return da > db
            }
    }

    /// Sticker records newest-first (full metadata incl. the optional `templateID` for Remix links).
    static func stickerRecords() -> [StickerRecord] {
        guard let indexURL, let data = try? Data(contentsOf: indexURL) else { return [] }
        return decodeStickerRecords(data).sorted { $0.createdAt > $1.createdAt }
    }
}

/// Persisted metadata for one sticker. Lives in `index.json` in the App Group.
///
/// `templateID` records which Style-Wall look the sticker was made from, so a "Remix in Peel" deep link
/// from a received sticker can re-apply that exact look onto a friend's own photo. Optional + decoded
/// leniently so pre-existing index entries (no template id) keep working.
struct StickerRecord: Codable, Identifiable, Equatable {
    let id: String
    let file: String
    let createdAt: Date
    var templateID: String? = nil

    init(id: String, file: String, createdAt: Date, templateID: String? = nil) {
        self.id = id
        self.file = file
        self.createdAt = createdAt
        self.templateID = templateID
    }
}
