import AppKit
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

        guard let content = ClipboardPasteboardContent.snapshot(from: pasteboard) else { return }
        let copiedAt = Date()

        switch content.payload {
        case .text(let text):
            switch clipboardStore.reserveExternalCapture(
                signature: content.signature,
                copiedAt: copiedAt,
                changeCount: currentChangeCount
            ) {
            case .existing, .alreadyInFlight:
                return
            case .new(let token):
                clipboardStore.commitText(text, token: token)
            }
        case .image(let imageData):
            captureImage(
                imageData: imageData,
                signature: content.signature,
                copiedAt: copiedAt,
                changeCount: currentChangeCount
            )
        }
    }

    private func captureImage(imageData: Data, signature: String, copiedAt: Date, changeCount: Int) {
        let reservation = clipboardStore.reserveExternalCapture(
            signature: signature,
            copiedAt: copiedAt,
            changeCount: changeCount
        )
        guard case .new(let token) = reservation else { return }

        let imageStorage = self.imageStorage
        Task.detached(priority: .utility) { [weak self] in
            do {
                let payload = try imageStorage.store(imageData: imageData)
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
}
