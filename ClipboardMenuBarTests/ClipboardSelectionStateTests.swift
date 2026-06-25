@testable import Mac_win_v
import XCTest

@MainActor
final class ClipboardSelectionStateTests: XCTestCase {
    func testVSelectionTogglesAndOrdinaryClickClearsSelection() {
        let a = UUID()
        let b = UUID()
        var state = ClipboardSelectionState()

        state.toggleSelection(itemID: a)
        XCTAssertEqual(state.focusedItemID, a)
        XCTAssertEqual(state.selectedItemIDs, [a])

        state.toggleSelection(itemID: a)
        XCTAssertEqual(state.selectedItemIDs, [])

        state.toggleSelection(itemID: a)
        state.toggleSelection(itemID: b)
        state.ordinaryClick(itemID: a)
        XCTAssertEqual(state.focusedItemID, a)
        XCTAssertTrue(state.selectedItemIDs.isEmpty)
    }

    func testRowClickUsesInputModeForSelection() {
        let a = UUID()
        let b = UUID()
        var state = ClipboardSelectionState()

        let selectionAction = state.handleRowClick(
            itemID: a,
            isVSelectionModeActive: true
        )
        XCTAssertEqual(selectionAction, .updateSelection)
        XCTAssertEqual(state.focusedItemID, a)
        XCTAssertEqual(state.selectedItemIDs, [a])

        let pasteAction = state.handleRowClick(
            itemID: b,
            isVSelectionModeActive: false
        )
        XCTAssertEqual(pasteAction, .pasteSingleItem)
        XCTAssertEqual(state.focusedItemID, b)
        XCTAssertTrue(state.selectedItemIDs.isEmpty)
    }

    func testArrowFocusDoesNotClearSelection() {
        let ids = [UUID(), UUID(), UUID()]
        var state = ClipboardSelectionState(focusedItemID: ids[0], selectedItemIDs: [ids[2]])

        state.moveFocus(direction: 1, orderedIDs: ids)
        XCTAssertEqual(state.focusedItemID, ids[1])
        XCTAssertEqual(state.selectedItemIDs, [ids[2]])
    }

    func testSelectedItemsFollowCurrentDisplayOrderNotClickOrder() {
        let a = ClipboardItem(kind: .text, textContent: "A", pasteboardSignature: "a")
        let b = ClipboardItem(kind: .text, textContent: "B", pasteboardSignature: "b")
        let c = ClipboardItem(kind: .text, textContent: "C", pasteboardSignature: "c")
        var state = ClipboardSelectionState()

        state.toggleSelection(itemID: c.id)
        state.toggleSelection(itemID: a.id)

        XCTAssertEqual(state.selectedItemsInDisplayOrder(from: [a, b, c]).map(\.id), [a.id, c.id])
    }

    func testRepairDropsDeletedIDsAndKeepsSelectionAcrossReorder() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        var state = ClipboardSelectionState(focusedItemID: b, selectedItemIDs: [a, c])

        state.repair(orderedIDs: [c, b])
        XCTAssertEqual(state.focusedItemID, b)
        XCTAssertEqual(state.selectedItemIDs, [c])

        state.repair(orderedIDs: [c])
        XCTAssertEqual(state.focusedItemID, c)
        XCTAssertEqual(state.selectedItemIDs, [c])
    }
}
