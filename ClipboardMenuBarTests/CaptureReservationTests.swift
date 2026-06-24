@testable import ClipboardMenuBar
import XCTest

@MainActor
final class CaptureReservationTests: XCTestCase {
    func testNewTextReservationCreatesIDAndEnqueues() throws {
        let store = try makeTestStore()
        let copiedAt = Date(timeIntervalSince1970: 20_000)

        guard case .new(let token) = store.reserveExternalCapture(signature: "text-a", copiedAt: copiedAt) else {
            XCTFail("Expected new reservation")
            return
        }

        XCTAssertEqual(store.pendingPromotionsForTesting(), [NextOpenPromotion(itemID: token.id, copiedAt: copiedAt)])
        store.commitText("A", token: token)
        XCTAssertEqual(store.fetchItems().first?.id, token.id)
    }

    func testLatestSignatureRefreshesExistingPromotionWithoutNewModel() throws {
        let store = try makeTestStore()
        let base = Date(timeIntervalSince1970: 21_000)
        let item = insertText("A", signature: "text-a", copiedAt: base, into: store)

        XCTAssertEqual(store.reserveExternalCapture(signature: "text-a", copiedAt: base.addingTimeInterval(90)), .existing(item.id))
        XCTAssertEqual(store.fetchItems().count, 1)
        XCTAssertEqual(store.pendingPromotionsForTesting().first?.copiedAt, base.addingTimeInterval(90))
    }

    func testInFlightDuplicateDoesNotStartNewTaskAndCommitUsesLatestCopiedAt() throws {
        let store = try makeTestStore()
        let base = Date(timeIntervalSince1970: 22_000)

        guard case .new(let token) = store.reserveExternalCapture(signature: "image-a", copiedAt: base) else {
            XCTFail("Expected new reservation")
            return
        }

        XCTAssertEqual(store.reserveExternalCapture(signature: "image-a", copiedAt: base.addingTimeInterval(70)), .alreadyInFlight(token.id))
        store.commitImage(payload: try makeStoredImagePayload(), token: token)

        let item = store.fetchItems().first
        XCTAssertEqual(item?.id, token.id)
        XCTAssertEqual(item?.createdAt, base.addingTimeInterval(70))
    }

    func testCancelAndLateCommitDoNotLeavePendingOrInsertModel() throws {
        let store = try makeTestStore()
        let base = Date(timeIntervalSince1970: 23_000)
        guard case .new(let token) = store.reserveExternalCapture(signature: "image-cancel", copiedAt: base) else {
            XCTFail("Expected new reservation")
            return
        }

        store.cancelCapture(token)
        XCTAssertTrue(store.pendingPromotionsForTesting().isEmpty)

        store.commitImage(payload: try makeStoredImagePayload(), token: token)
        XCTAssertTrue(store.fetchItems().isEmpty)
    }

    func testDifferentImagesCommitOutOfOrderKeepOriginalCopyTimes() throws {
        let store = try makeTestStore()
        let base = Date(timeIntervalSince1970: 24_000)
        guard case .new(let tokenA) = store.reserveExternalCapture(signature: "image-a", copiedAt: base),
              case .new(let tokenB) = store.reserveExternalCapture(signature: "image-b", copiedAt: base.addingTimeInterval(10)) else {
            XCTFail("Expected new reservations")
            return
        }

        store.commitImage(payload: try makeStoredImagePayload(), token: tokenB)
        store.commitImage(payload: try makeStoredImagePayload(), token: tokenA)

        let items = store.fetchItems()
        XCTAssertEqual(items.map(\.id), [tokenB.id, tokenA.id])
        XCTAssertEqual(items.first?.createdAt, base.addingTimeInterval(10))
        XCTAssertEqual(items.last?.createdAt, base)
    }
}
