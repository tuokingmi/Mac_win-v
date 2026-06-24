import AppKit
import Carbon
import Foundation

@MainActor
final class DirectPasteObserver {
    private let clipboardStore: ClipboardStore
    private unowned let panelController: PanelController
    private let pasteboard = NSPasteboard.general
    private var monitor: Any?

    init(clipboardStore: ClipboardStore, panelController: PanelController) {
        self.clipboardStore = clipboardStore
        self.panelController = panelController
    }

    func start() {
        stop()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let modifierFlags = event.modifierFlags
            let isARepeat = event.isARepeat

            Task { @MainActor [weak self] in
                self?.handleKeyDown(keyCode: keyCode, modifierFlags: modifierFlags, isARepeat: isARepeat)
            }
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func handleKeyDown(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags, isARepeat: Bool) {
        let changeCount = pasteboard.changeCount

        guard isARepeat == false,
              panelController.isPanelVisible == false,
              isDirectPasteShortcut(keyCode: keyCode, modifierFlags: modifierFlags),
              clipboardStore.isCaptureSuppressed(changeCount: changeCount) == false,
              let content = ClipboardPasteboardContent.snapshot(from: pasteboard) else {
            return
        }

        clipboardStore.markDirectPasteUsed(
            signature: content.signature,
            changeCount: changeCount,
            at: .now
        )
    }

    private func isDirectPasteShortcut(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> Bool {
        guard keyCode == UInt16(kVK_ANSI_V) else { return false }

        let relevantFlags = modifierFlags.intersection([.command, .shift, .option, .control])
        return relevantFlags == [.command] || relevantFlags == [.command, .shift]
    }
}
