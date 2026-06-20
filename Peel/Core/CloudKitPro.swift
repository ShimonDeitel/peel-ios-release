import CloudKit

/// Mirrors the user's paid status to CloudKit's PUBLIC database, keyed by their Sign in with Apple
/// user id (used as the record name). This is the owner-visible source of truth — the owner sees
/// exactly who is paying in the CloudKit Dashboard — and it lets Pro follow the user across devices.
/// The user's own stickers stay on-device (App Group); only the paid flag is synced here.
///
/// Every call is best-effort and degrades silently: with no iCloud account, or any CloudKit error,
/// the app falls back to the signed StoreKit entitlement and keeps working offline.
actor CloudKitPro {
    static let shared = CloudKitPro()

    static let containerID = "iCloud.com.joshuadeitel.peel"
    private let recordType = "UserEntitlement"
    private let container = CKContainer(identifier: CloudKitPro.containerID)
    private var publicDB: CKDatabase { container.publicCloudDatabase }

    /// Reads the owner-visible paid flag for this user. `false` on any miss/error.
    func fetchPro(userID: String) async -> Bool {
        guard let id = Self.recordID(for: userID) else { return false }
        do {
            let record = try await publicDB.record(for: id)
            return (record["pro"] as? Int64 ?? 0) == 1
        } catch {
            return false
        }
    }

    /// Writes `pro:true` (+ the originating transaction id) for this user. Idempotent.
    func setPro(userID: String, transactionID: UInt64?) async {
        guard let id = Self.recordID(for: userID) else { return }
        let record = (try? await publicDB.record(for: id)) ?? CKRecord(recordType: recordType, recordID: id)
        record["pro"] = Int64(1)
        record["appleUserID"] = userID as CKRecordValue
        if let transactionID { record["transactionID"] = String(transactionID) as CKRecordValue }
        record["updatedAt"] = Date() as CKRecordValue
        _ = try? await publicDB.save(record)
    }

    /// Deletes the user's paid-status record (App Store Guideline 5.1.1(v) account deletion).
    func deleteAccount(userID: String) async {
        guard let id = Self.recordID(for: userID) else { return }
        _ = try? await publicDB.deleteRecord(withID: id)
    }

    /// Deterministic record id from the Apple user id. Record names allow only a limited charset
    /// and must not start with an underscore, so we prefix and sanitize defensively.
    private static func recordID(for userID: String) -> CKRecord.ID? {
        let trimmed = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-.")
        let cleaned = String(trimmed.unicodeScalars.filter { allowed.contains($0) })
        return CKRecord.ID(recordName: "user-" + String(cleaned.prefix(240)))
    }
}
