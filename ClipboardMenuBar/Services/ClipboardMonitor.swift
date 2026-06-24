import AppKit
import CryptoKit
import Foundation

@MainActor
final class ClipboardMonitor {
    private let clipboardStore: ClipboardStore
    private let imageStorage: ImageStorage
    private let pasteboard = NSPasteboard.general
    private var timer: Timer?
    private var lastChangeCount: Int

    init(clipboardStore: ClipboardStore, imageStorage: ImageStorage) {
        self.clipboardStore = clipboardStore
        self.imageStorage = imageStorage
        self.lastChangeCount = pasteboard.changeCount
    }

    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.captureIfNeeded()
            }
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func captureIfNeeded() {
        let currentChangeCount = pasteboard.changeCount
        guard currentChangeCount != lastChangeCount else { return }
        lastChangeCount = currentChangeCount

        guard clipboardStore.consumeCaptureSuppression(changeCount: currentChangeCount) == false else {
            return
        }

        let copiedAt = Date()

        let imageTypes: Set<NSPasteboard.PasteboardType> = [.tiff, .png]
        let stringTypes: Set<NSPasteboard.PasteboardType> = [.string]
        let types = pasteboard.types ?? []
        let firstImageIndex = types.firstIndex(where: { imageTypes.contains($0) })
        let firstStringIndex = types.firstIndex(where: { stringTypes.contains($0) })

        // If image types appear before string types in the pasteboard, the source
        // primarily intends to provide an image (e.g., copying an image from a browser).
        let preferImage: Bool
        if let imgIdx = firstImageIndex, let strIdx = firstStringIndex {
            preferImage = imgIdx < strIdx
        } else {
            preferImage = firstImageIndex != nil
        }

        if preferImage, let tiffData = pasteboard.data(forType: .tiff) ?? pasteboard.data(forType: .png) {
            captureImage(tiffData: tiffData, copiedAt: copiedAt)
            return
        }

        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            let signature = digest(for: Data(text.utf8), prefix: "text")
            switch clipboardStore.reserveExternalCapture(signature: signature, copiedAt: copiedAt) {
            case .existing, .alreadyInFlight:
                return
            case .new(let token):
                clipboardStore.commitText(text, token: token)
            }
            return
        }

        // Last resort: try image even if text types appeared first but no text was found
        if let tiffData = pasteboard.data(forType: .tiff) ?? pasteboard.data(forType: .png) {
            captureImage(tiffData: tiffData, copiedAt: copiedAt)
        }
    }

    private func captureImage(tiffData: Data, copiedAt: Date) {
        let signature = digest(for: tiffData, prefix: "image")
        let reservation = clipboardStore.reserveExternalCapture(signature: signature, copiedAt: copiedAt)
        guard case .new(let token) = reservation else { return }

        let imageStorage = self.imageStorage
        Task.detached(priority: .utility) { [weak self] in
            do {
                let payload = try imageStorage.store(imageData: tiffData)
                await MainActor.run {
                    self?.clipboardStore.commitImage(payload: payload, token: token)
                }
            } catch {
                await MainActor.run {
                    NSLog("Failed to persist clipboard image: %@", error.localizedDescription)
                    self?.clipboardStore.cancelCapture(token)
                }
            }
        }
    }

    private func digest(for data: Data, prefix: String) -> String {
        let hash = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
        return "\(prefix)-\(hash)"
    }
}
