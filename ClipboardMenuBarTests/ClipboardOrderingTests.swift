@testable import ClipboardMenuBar
import XCTest

@MainActor
final class ClipboardOrderingTests: XCTestCase {
    func testActivePromotionsPrecedePinnedAndUnpinnedWithoutDuplicates() throws {
        let store = try makeTestStore()
        let base = Date(timeIntervalSince1970: 10_000)

        let oldUnpinned = insertText("old", copiedAt: base, into: store)
        let promotedPinned = insertText("promoted pinned", copiedAt: base.addingTimeInterval(10), isPinned: true, into: store)
        let pinnedNew = insertText("pinned new", copiedAt: base.addingTimeInterval(20), isPinned: true, into: store)
        let pinnedOld = insertText("pinned old", copiedAt: base.addingTimeInterval(30), isPinned: true, into: store)
        let promotedUnpinned = insertText("promoted unpinned", copiedAt: base.addingTimeInterval(40), into: store)
        let newUnpinned = insertText("new", copiedAt: base.addingTimeInterval(50), into: store)

        let active = [
            NextOpenPromotion(itemID: promotedUnpinned.id, copiedAt: base.addingTimeInterval(1)),
            NextOpenPromotion(itemID: promotedPinned.id, copiedAt: base.addingTimeInterval(2))
        ]

        let ordered = store.fetchItems(promoting: active)
        XCTAssertEqual(
            ordered.map(\.id),
            [promotedUnpinned.id, promotedPinned.id, pinnedOld.id, pinnedNew.id, newUnpinned.id, oldUnpinned.id]
        )
        XCTAssertEqual(Set(ordered.map(\.id)).count, ordered.count)
    }
}
