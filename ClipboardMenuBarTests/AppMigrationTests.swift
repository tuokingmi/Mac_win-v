@testable import Mac_win_v
import XCTest

@MainActor
final class AppMigrationTests: XCTestCase {
    func testPreviousBundleStoreAndImagesAreCopiedIntoNewBundleDirectory() throws {
        let fileManager = FileManager.default
        let baseURL = fileManager.temporaryDirectory
            .appendingPathComponent("MacWinVMigrationTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? fileManager.removeItem(at: baseURL)
        }

        let previousDirectory = baseURL.appendingPathComponent(AppIdentity.previousBundleIdentifier, isDirectory: true)
        let currentDirectory = baseURL.appendingPathComponent(AppIdentity.bundleIdentifier, isDirectory: true)
        let previousImagesDirectory = previousDirectory.appendingPathComponent("Images", isDirectory: true)
        let currentStoreURL = currentDirectory.appendingPathComponent("ClipboardHistory.store", isDirectory: false)

        try fileManager.createDirectory(at: previousImagesDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: currentDirectory, withIntermediateDirectories: true)

        let previousStoreURL = previousDirectory.appendingPathComponent("ClipboardHistory.store", isDirectory: false)
        try Data("store".utf8).write(to: previousStoreURL)
        try Data("wal".utf8).write(to: URL(fileURLWithPath: previousStoreURL.path + "-wal"))
        try Data("shm".utf8).write(to: URL(fileURLWithPath: previousStoreURL.path + "-shm"))

        let previousImageURL = previousImagesDirectory.appendingPathComponent("preview.png", isDirectory: false)
        try Data("image".utf8).write(to: previousImageURL)

        try AppServices.migrateLegacyStoreIfNeeded(to: currentStoreURL, baseDirectory: baseURL)

        XCTAssertEqual(try Data(contentsOf: currentStoreURL), Data("store".utf8))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: currentStoreURL.path + "-wal")), Data("wal".utf8))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: currentStoreURL.path + "-shm")), Data("shm".utf8))

        let currentImageURL = currentDirectory
            .appendingPathComponent("Images", isDirectory: true)
            .appendingPathComponent("preview.png", isDirectory: false)
        XCTAssertEqual(try Data(contentsOf: currentImageURL), Data("image".utf8))
        XCTAssertTrue(fileManager.fileExists(atPath: previousStoreURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: previousImageURL.path))
    }
}
