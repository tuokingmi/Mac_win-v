@testable import Mac_win_v
import XCTest

@MainActor
final class PasteboardSuppressionTests: XCTestCase {
    func testRegisteredInternalChangeCountIsSuppressedOnce() throws {
        let store = try makeTestStore()

        store.suppressCapture(changeCount: 10)
        XCTAssertTrue(store.consumeCaptureSuppression(changeCount: 10))
        XCTAssertFalse(store.consumeCaptureSuppression(changeCount: 10))
    }

    func testConsecutiveInternalChangeCountsAreHandled() throws {
        let store = try makeTestStore()

        store.suppressCapture(changeCount: 20)
        store.suppressCapture(changeCount: 21)

        XCTAssertTrue(store.consumeCaptureSuppression(changeCount: 20))
        XCTAssertTrue(store.consumeCaptureSuppression(changeCount: 21))
    }

    func testSuppressionCanBeCheckedWithoutConsuming() throws {
        let store = try makeTestStore()

        store.suppressCapture(changeCount: 25)
        XCTAssertTrue(store.isCaptureSuppressed(changeCount: 25))
        XCTAssertTrue(store.consumeCaptureSuppression(changeCount: 25))
        XCTAssertFalse(store.isCaptureSuppressed(changeCount: 25))
    }

    func testSkippingToLatestInternalChangeStillSuppressesAndDropsOlderCounts() throws {
        let store = try makeTestStore()

        store.suppressCapture(changeCount: 30)
        store.suppressCapture(changeCount: 31)

        XCTAssertTrue(store.consumeCaptureSuppression(changeCount: 31))
        XCTAssertFalse(store.consumeCaptureSuppression(changeCount: 30))
        XCTAssertFalse(store.consumeCaptureSuppression(changeCount: 32))
    }

    func testSuppressionDoesNotCreateOrRefreshPromotion() throws {
        let store = try makeTestStore()
        let base = Date(timeIntervalSince1970: 40_000)
        let item = insertText("A", copiedAt: base, into: store)
        _ = store.consumeEligibleNextOpenPromotions(at: base.addingTimeInterval(1))

        store.suppressCapture(changeCount: 40)
        XCTAssertTrue(store.consumeCaptureSuppression(changeCount: 40))
        XCTAssertTrue(store.consumeEligibleNextOpenPromotions(at: base.addingTimeInterval(2)).isEmpty)
        XCTAssertEqual(store.fetchItems().map(\.id), [item.id])
    }
}
