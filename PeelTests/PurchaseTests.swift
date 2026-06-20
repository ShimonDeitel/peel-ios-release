import XCTest
@testable import Peel

/// Tests the new monetization gate: the editor is fully free, free users get one sticker per local
/// day (resets at midnight), and Pro is unlimited. This is pure, deterministic logic — no StoreKit
/// test session (SKTestSession is unreliable on the current Xcode/iOS-26 simulator toolchain;
/// the actual purchase→charge→unlock is verified on-device against the App Store sandbox).
@MainActor
final class PurchaseTests: XCTestCase {

    private func clearQuota() {
        let d = AppGroup.defaults ?? .standard
        d.removeObject(forKey: "dailyStickerCount")
        d.removeObject(forKey: "dailyStickerDay")
        d.removeObject(forKey: AppGroup.creditsKey)   // credit balance must not leak between cases
    }

    override func setUp() { super.setUp(); clearQuota() }
    override func tearDown() { clearQuota(); super.tearDown() }

    func testFreeUserGetsThreeStickersPerDay() {
        let q = DailyQuota()
        XCTAssertTrue(q.canCreate(isPro: false), "a fresh day allows the first free sticker")
        XCTAssertEqual(q.remaining(isPro: false), 3)
        q.recordCreated(); q.recordCreated()
        XCTAssertEqual(q.remaining(isPro: false), 1)
        XCTAssertTrue(q.canCreate(isPro: false), "the third free sticker is still allowed")
        q.recordCreated()
        XCTAssertEqual(q.remaining(isPro: false), 0)
        XCTAssertFalse(q.canCreate(isPro: false), "a 4th sticker is blocked once the free 3 are used")
    }

    func testProIsUnlimited() {
        let q = DailyQuota()
        for _ in 0..<5 { q.recordCreated(isPro: true) }
        XCTAssertTrue(q.canCreate(isPro: true), "Pro is never capped by the daily quota")
        XCTAssertNil(q.remaining(isPro: true), "Pro reports no remaining count (unlimited)")
    }

    func testUsedSlotsPersistSameDay() {
        let q = DailyQuota()
        q.recordCreated(); q.recordCreated(); q.recordCreated()
        let next = DailyQuota()   // simulates a relaunch within the same day
        XCTAssertEqual(next.remaining(isPro: false), 0, "the used free slots survive a relaunch")
        XCTAssertFalse(next.canCreate(isPro: false), "no free creates remain after a relaunch")
    }

    func testRollsOverOnNewDay() {
        let d = AppGroup.defaults ?? .standard
        d.set("2000-01-01", forKey: "dailyStickerDay")
        d.set(9, forKey: "dailyStickerCount")
        let q = DailyQuota()      // init rolls over against today's date
        XCTAssertTrue(q.canCreate(isPro: false), "a new day resets the free allowance")
        XCTAssertEqual(q.remaining(isPro: false), 3)
    }

    // MARK: - Consumable credits

    func testCreditsExtendCreationBeyondFreeLimit() {
        AppGroup.creditBalance = 2
        let q = DailyQuota()
        q.recordCreated(); q.recordCreated(); q.recordCreated()   // use the free 3
        XCTAssertEqual(q.remaining(isPro: false), 0, "free allowance is spent")
        XCTAssertTrue(q.canCreate(isPro: false), "credits keep creation open past the free limit")
        XCTAssertEqual(q.recordCreated(), .credit, "a 4th create spends a credit, not a free slot")
        XCTAssertEqual(q.creditBalance, 1, "one credit was decremented")
        XCTAssertEqual(q.recordCreated(), .credit)
        XCTAssertEqual(q.creditBalance, 0, "credits decrement to zero")
        XCTAssertFalse(q.canCreate(isPro: false), "with no free slots and no credits, creation is blocked")
    }

    func testFreeSlotsSpentBeforeCredits() {
        AppGroup.creditBalance = 5
        let q = DailyQuota()
        XCTAssertEqual(q.recordCreated(), .free, "the first create uses a free slot, not a credit")
        XCTAssertEqual(q.creditBalance, 5, "credits are untouched while free slots remain")
    }

    func testCreditsNeverExpireAcrossDayRollover() {
        AppGroup.creditBalance = 4
        let d = AppGroup.defaults ?? .standard
        d.set("2000-01-01", forKey: "dailyStickerDay")   // force a stale day
        let q = DailyQuota()                              // rolls the daily count over...
        XCTAssertEqual(q.remaining(isPro: false), 3, "the daily free count reset")
        XCTAssertEqual(q.creditBalance, 4, "purchased credits survive the day rollover (never expire)")
    }

    func testAutoEditProducesAValidEdit() {
        // Auto-Edit must always return a clamped, valid StickerEdit (never out of range).
        let img = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { ctx in
            UIColor(red: 0.2, green: 0.3, blue: 0.5, alpha: 1).setFill()
            ctx.fill(CGRect(x: 8, y: 8, width: 24, height: 24))
        }
        var edit = StickerEdit()
        edit.layers = [StickerLayer(cutout: img)]
        AutoEdit.enhance(&edit, primary: img)
        XCTAssert((0.6...1.5).contains(edit.contrast), "contrast stays in range")
        XCTAssert((0...2).contains(edit.saturation), "saturation stays in range")
        XCTAssert((-2.0...2.0).contains(edit.exposure), "exposure stays in range")
    }
}
