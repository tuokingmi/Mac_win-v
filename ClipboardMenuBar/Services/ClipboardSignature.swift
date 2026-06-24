import AppKit
import CryptoKit
import Foundation

enum ClipboardPasteboardPayload {
    case text(String)
    case image(Data)
}

struct ClipboardPasteboardContent {
    let signature: String
    let payload: ClipboardPasteboardPayload

    static func snapshot(from pasteboard: NSPasteboard) -> ClipboardPasteboardContent? {
        let imageTypes: Set<NSPasteboard.PasteboardType> = [.tiff, .png]
        let stringTypes: Set<NSPasteboard.PasteboardType> = [.string]
        let types = pasteboard.types ?? []
        let firstImageIndex = types.firstIndex { imageTypes.contains($0) }
        let firstStringIndex = types.firstIndex { stringTypes.contains($0) }

        let preferImage: Bool
        if let imgIdx = firstImageIndex, let strIdx = firstStringIndex {
            preferImage = imgIdx < strIdx
        } else {
            preferImage = firstImageIndex != nil
        }

        if preferImage, let imageData = pasteboard.data(forType: .tiff) ?? pasteboard.data(forType: .png) {
            return imageSnapshot(data: imageData)
        }

        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            return ClipboardPasteboardContent(
                signature: digest(for: Data(text.utf8), prefix: "text"),
                payload: .text(text)
            )
        }

        if let imageData = pasteboard.data(forType: .tiff) ?? pasteboard.data(forType: .png) {
            return imageSnapshot(data: imageData)
        }

        return nil
    }

    private static func imageSnapshot(data: Data) -> ClipboardPasteboardContent {
        ClipboardPasteboardContent(
            signature: digest(for: data, prefix: "image"),
            payload: .image(data)
        )
    }

    private static func digest(for data: Data, prefix: String) -> String {
        let hash = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
        return "\(prefix)-\(hash)"
    }
}
