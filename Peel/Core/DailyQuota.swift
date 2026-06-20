import Foundation
import Combine

/// Tracks how many NEW stickers the user has created today and gates creation.
///
/// Order of allowance (the fairness rules, checked at creation START — never at save/share):
///   1. UNLIMITED ceiling owners (`isPro`) create without limit.
///   2. Free users get `freeDailyLimit` creates per local day (resets at midnight).
///   3. After the free creates are used, one CONSUMABLE credit is spent per extra create. Credits
///      never expire and stack on top of the free allowance.
///   4. Only when free creates AND credits are exhausted is the user blocked (paywall).
///
/// Counts + the credit balance live in the App Group so they're a single source of truth shared with
/// the iMessage extension and keyboard.
@MainActor
final class DailyQuota: ObservableObject {
    /// Free users may create this many stickers per local calendar day.
    static let freeDailyLimit = 3

    @Published private(set) var todayCount: Int = 0
    @Published private(set) var creditBalance: Int = 0

    private let countKey = "dailyStickerCount"
    private let dayKey = "dailyStickerDay"

    private var defaults: UserDefaults { AppGroup.defaults ?? .standard }

    init() { rollOverIfNeeded(); creditBalance = AppGroup.creditBalance }

    /// The local-day stamp, e.g. "2026-06-18", used to detect a new day.
    private func todayStamp(_ date: Date = Date()) -> String {
        var cal = Calendar.current
        cal.timeZone = .current
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Reset the counter when the stored day differs from today, and republish `todayCount`.
    ///
    /// IMPORTANT: this MUTATES observable state (`todayCount` is `@Published`), so it must only be called
    /// from outside SwiftUI body evaluation — i.e. `init()`, `recordCreated(...)`, and the explicit
    /// `refresh()` (run on appear / scene activation). Calling it during `body` triggers the
    /// "Publishing changes from within view updates" runtime fault and an infinite render loop. The
    /// read-only accessors below use the PURE `currentCount()` instead and never publish.
    private func rollOverIfNeeded() {
        let today = todayStamp()
        if defaults.string(forKey: dayKey) != today {
            defaults.set(today, forKey: dayKey)
            defaults.set(0, forKey: countKey)
        }
        todayCount = defaults.integer(forKey: countKey)
    }

    /// Today's effective create count, computed WITHOUT mutating any observable/published state. If the
    /// stored day is not today, the effective count is 0 (the rollover write happens later, off-body).
    /// Safe to call from inside a SwiftUI `body`.
    private func currentCount() -> Int {
        defaults.string(forKey: dayKey) == todayStamp() ? defaults.integer(forKey: countKey) : 0
    }

    /// Free creates left today (before any credits). `nil` for unlimited owners.
    /// PURE read — safe to call from a view `body`; does not publish.
    func freeRemaining(isPro: Bool) -> Int? {
        if isPro { return nil }
        return max(0, Self.freeDailyLimit - currentCount())
    }

    /// Back-compat name used by existing UI: the free creates left today (`nil` for unlimited).
    func remaining(isPro: Bool) -> Int? { freeRemaining(isPro: isPro) }

    /// Whether the user may create another sticker right now — counting the free daily allowance AND any
    /// purchased credits. Pure check; does NOT spend anything and does NOT publish.
    func canCreate(isPro: Bool) -> Bool {
        if isPro { return true }
        if currentCount() < Self.freeDailyLimit { return true }
        return AppGroup.creditBalance > 0
    }

    /// Re-sync the published `todayCount` / `creditBalance` from the shared container. Call from `.onAppear`
    /// or on scene activation (NEVER from a `body`) so a day-rollover that happened while backgrounded is
    /// reflected in the UI.
    func refresh() {
        rollOverIfNeeded()
        creditBalance = AppGroup.creditBalance
    }

    /// Record that one sticker was created. Uses a free daily slot first; once those are gone it SPENDS
    /// one credit. Unlimited owners consume nothing. Call after the create is committed (start-gated by
    /// `canCreate`). Returns how the create was paid for, for UI messaging.
    enum CreateCost { case free, credit, unlimited }
    @discardableResult
    func recordCreated(isPro: Bool = false) -> CreateCost {
        if isPro { return .unlimited }
        rollOverIfNeeded()
        if todayCount < Self.freeDailyLimit {
            todayCount += 1
            defaults.set(todayCount, forKey: countKey)
            return .free
        }
        // Out of free creates — spend a credit if we have one.
        if AppGroup.creditBalance > 0 {
            AppGroup.creditBalance -= 1
            creditBalance = AppGroup.creditBalance
            return .credit
        }
        // Nothing left; caller should have blocked via canCreate. Count it as free to avoid a silent
        // negative, but this path shouldn't be reached when the gate is honored.
        return .free
    }

    /// Refresh the published credit balance from the shared container (e.g. after a purchase).
    func refreshCredits() { creditBalance = AppGroup.creditBalance }
}
