@testable import ClipboardMenuBar
import XCTest

@MainActor
final class PastePlanTests: XCTestCase {
    func testEmptySelectionReturnsNil() throws {
        let store = try makeTestStore()
        XCTAssertNil(PasteService().makePlan(for: [], using: store))
    }

    func testSingleAndMultipleTextPlans() throws {
        let store = try makeTestStore()
        let base = Date(timeIntervalSince1970: 30_000)
        let a = insertText("A", copiedAt: base, into: store)
        let b = insertText("B", copiedAt: base.addingTimeInterval(1), into: store)

        guard case .text(let single) = PasteService().makePlan(for: [a], using: store) else {
            XCTFail("Expected text plan")
            return
        }
        XCTAssertEqual(single, "A")

        guard case .text(let combined) = PasteService().makePlan(for: [b, a], using: store) else {
            XCTFail("Expected text plan")
            return
        }
        XCTAssertEqual(combined, "B\nA")
    }

    func testImageAndMixedPlans() throws {
        let environment = try makeTestEnvironment()
        let store = environment.store
        let base = Date(timeIntervalSince1970: 31_000)
        let text = insertText("A", copiedAt: base, into: store)

        guard case .new(let imageToken) = store.reserveExternalCapture(signature: "image-a", copiedAt: base.addingTimeInterval(1)) else {
            XCTFail("Expected image reservation")
            return
        }
        store.commitImage(payload: try makeStoredImagePayload(in: environment.imageStorage), token: imageToken)
        let image = store.fetchItems().first { $0.id == imageToken.id }!

        guard case .sequential(let imagePayloads) = PasteService().makePlan(for: [image], using: store) else {
            XCTFail("Expected sequential plan")
            return
        }
        XCTAssertEqual(imagePayloads.count, 1)

        guard case .sequential(let mixedPayloads) = PasteService().makePlan(for: [text, image], using: store) else {
            XCTFail("Expected sequential plan")
            return
        }
        XCTAssertEqual(mixedPayloads.count, 2)
    }

    func testMissingImageReturnsNil() throws {
        let store = try makeTestStore()
        let item = ClipboardItem(
            kind: .image,
            imagePath: "missing.png",
            imageWidth: 10,
            imageHeight: 10,
            pasteboardSignature: "missing"
        )

        XCTAssertNil(PasteService().makePlan(for: [item], using: store))
    }
}
