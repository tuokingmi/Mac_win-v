@testable import ClipboardMenuBar
import XCTest

@MainActor
final class NextOpenPromotionTests: XCTestCase {
    func testThreeMinuteEligibilityBoundary() {
        let copiedAt = Date(timeIntervalSince1970: 1_000)
        let promotion = NextOpenPromotion(itemID: UUID(), copiedAt: copiedAt)

        XCTAssertTrue(promotion.isEligible(at: copiedAt.addingTimeInterval(179.999)))
        XCTAssertFalse(promotion.isEligible(at: copiedAt.addingTimeInterval(180.000)))
        XCTAssertFalse(promotion.isEligible(at: copiedAt.addingTimeInterval(181)))
    }

    func testLaterCopiesSortFirstAndDoNotExtendEarlierCopies() throws {
        let store = try makeTestStore()
        let base = Date(timeIntervalSince1970: 2_000)

        let itemA = insertText("A", copiedAt: base, into: store)
        let itemB = insertText("B", copiedAt: base.addingTimeInterval(60), into: store)

        XCTAssertEqual(
            store.consumeEligibleNextOpenPromotions(at: base.addingTimeInterval(120)).map(\.itemID),
            [itemB.id, itemA.id]
        )

        _ = insertText("A2", copiedAt: base, into: store)
        let itemB2 = insertText("B2", copiedAt: base.addingTimeInterval(181), into: store)
        XCTAssertEqual(
            store.consumeEligibleNextOpenPromotions(at: base.addingTimeInterval(182)).map(\.itemID),
            [itemB2.id]
        )
    }

    func testSameItemCopyRefreshesOnlyThatItem() throws {
        let store = try makeTestStore()
        let base = Date(timeIntervalSince1970: 3_000)
        let itemB = insertText("B", copiedAt: base, into: store)
        let itemA = insertText("A", signature: "same", copiedAt: base.addingTimeInterval(30), into: store)

        XCTAssertEqual(store.reserveExternalCapture(signature: "same", copiedAt: base.addingTimeInterval(90)), .existing(itemA.id))

        let promotions = store.consumeEligibleNextOpenPromotions(at: base.addingTimeInterval(91))
        XCTAssertEqual(promotions.map(\.itemID), [itemA.id, itemB.id])
        XCTAssertEqual(promotions.first?.copiedAt, base.addingTimeInterval(90))
    }

    func testConsumeClearsAndSecondOpenDoesNotPromoteAgain() throws {
        let store = try makeTestStore()
        let base = Date(timeIntervalSince1970: 4_000)
        let item = insertText("A", copiedAt: base, into: store)

        XCTAssertEqual(store.consumeEligibleNextOpenPromotions(at: base.addingTimeInterval(1)).map(\.itemID), [item.id])
        XCTAssertTrue(store.consumeEligibleNextOpenPromotions(at: base.addingTimeInterval(2)).isEmpty)
    }

    func testCopyDuringOpenBelongsToNextSessionAndCanExpire() throws {
        let store = try makeTestStore()
        let base = Date(timeIntervalSince1970: 5_000)
        let itemA = insertText("A", copiedAt: base, into: store)
        let active = store.consumeEligibleNextOpenPromotions(at: base.addingTimeInterval(10))
        XCTAssertEqual(active.map(\.itemID), [itemA.id])

        let itemC = insertText("C", copiedAt: base.addingTimeInterval(20), into: store)
        store.finishPresentationSession(promotions: active, at: base.addingTimeInterval(30))
        XCTAssertEqual(store.consumeEligibleNextOpenPromotions(at: base.addingTimeInterval(40)).map(\.itemID), [itemC.id])

        _ = insertText("D", copiedAt: base.addingTimeInterval(50), into: store)
        XCTAssertTrue(store.consumeEligibleNextOpenPromotions(at: base.addingTimeInterval(231)).isEmpty)
    }

    func testUnfinishedInFlightActivePromotionCanBeRequeuedWithoutOverwritingNewerPending() throws {
        let store = try makeTestStore()
        let base = Date(timeIntervalSince1970: 6_000)
        guard case .new(let token) = store.reserveExternalCapture(signature: "image-same", copiedAt: base) else {
            XCTFail("Expected new reservation")
            return
        }

        let active = store.consumeEligibleNextOpenPromotions(at: base.addingTimeInterval(10))
        store.finishPresentationSession(promotions: active, at: base.addingTimeInterval(20))
        XCTAssertEqual(store.pendingPromotionsForTesting().map(\.itemID), [token.id])

        let activeAgain = store.consumeEligibleNextOpenPromotions(at: base.addingTimeInterval(30))
        XCTAssertEqual(store.reserveExternalCapture(signature: "image-same", copiedAt: base.addingTimeInterval(40)), .alreadyInFlight(token.id))
        store.finishPresentationSession(promotions: activeAgain, at: base.addingTimeInterval(50))
        XCTAssertEqual(store.pendingPromotionsForTesting().first?.copiedAt, base.addingTimeInterval(40))
    }
}
