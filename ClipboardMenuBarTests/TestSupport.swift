import AppKit
@testable import Mac_win_v
import SwiftData
import XCTest

@MainActor
func makeTestStore() throws -> ClipboardStore {
    try makeTestEnvironment().store
}

@MainActor
struct TestClipboardEnvironment {
    let container: ModelContainer
    let store: ClipboardStore
    let imageStorage: ImageStorage
}

@MainActor
func makeTestEnvironment() throws -> TestClipboardEnvironment {
    let schema = Schema([ClipboardItem.self])
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: schema, configurations: [configuration])
    let imageStorage = ImageStorage(bundleIdentifier: "Mac_win_vTests.\(UUID().uuidString)")
    let store = ClipboardStore(modelContext: container.mainContext, imageStorage: imageStorage, modelContainer: container)
    return TestClipboardEnvironment(container: container, store: store, imageStorage: imageStorage)
}

@MainActor
@discardableResult
func insertText(
    _ text: String,
    signature: String? = nil,
    copiedAt: Date,
    isPinned: Bool = false,
    into store: ClipboardStore
) -> ClipboardItem {
    let resolvedSignature = signature ?? "text-\(text)"
    guard case .new(let token) = store.reserveExternalCapture(signature: resolvedSignature, copiedAt: copiedAt) else {
        fatalError("Expected new reservation")
    }
    store.commitText(text, token: token)
    let item = store.fetchItems().first { $0.id == token.id }!
    if isPinned {
        store.togglePin(item)
    }
    return item
}

func makeImageData() -> Data {
    let image = NSImage(size: NSSize(width: 12, height: 8))
    image.lockFocus()
    NSColor.systemBlue.setFill()
    NSRect(x: 0, y: 0, width: 12, height: 8).fill()
    image.unlockFocus()
    return image.tiffRepresentation!
}

@MainActor
func makeStoredImagePayload() throws -> StoredImagePayload {
    let storage = ImageStorage(bundleIdentifier: "Mac_win_vTests.Payload.\(UUID().uuidString)")
    return try storage.store(imageData: makeImageData())
}

func makeStoredImagePayload(in storage: ImageStorage) throws -> StoredImagePayload {
    try storage.store(imageData: makeImageData())
}
