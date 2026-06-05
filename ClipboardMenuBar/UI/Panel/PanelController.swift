import AppKit
import SwiftUI

@MainActor
final class PanelController: ObservableObject {
    private let clipboardStore: ClipboardStore
    private let pasteService: PasteService
    private unowned let appServices: AppServices
    private lazy var panel: ClipboardPanel = makePanel()
    private var pasteTarget = PasteTarget(application: nil, focusedElement: nil)

    init(clipboardStore: ClipboardStore, pasteService: PasteService, appServices: AppServices) {
        self.clipboardStore = clipboardStore
        self.pasteService = pasteService
        self.appServices = appServices
    }

    var accessibilityEnabled: Bool {
        appServices.accessibilityEnabled
    }

    func requestAccessibilityPermission() {
        appServices.promptForAccessibilityPermission()
        objectWillChange.send()
    }

    func notifyPermissionStateChanged() {
        objectWillChange.send()
    }

    func toggle() {
        if panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        appServices.refreshSystemState()
        pasteTarget = pasteService.captureTarget(for: NSWorkspace.shared.frontmostApplication)
        updateContent()
        positionPanel()
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func hide() {
        pasteTarget = PasteTarget(application: nil, focusedElement: nil)
        panel.hideImmediately()
    }

    @discardableResult
    func paste(_ item: ClipboardItem) -> Bool {
        let target = pasteTarget
        pasteTarget = PasteTarget(application: nil, focusedElement: nil)
        return pasteService.paste(item: item, using: clipboardStore, panel: panel, target: target)
    }

    private func updateContent() {
        let rootView = ClipboardListView(clipboardStore: clipboardStore, panelController: self)
        panel.contentView = NSHostingView(rootView: rootView)
    }

    private func makePanel() -> ClipboardPanel {
        let rootView = ClipboardListView(clipboardStore: clipboardStore, panelController: self)
        let panel = ClipboardPanel(initialContentView: NSHostingView(rootView: rootView))
        panel.onRequestClose = { [weak self] in
            self?.hide()
        }
        return panel
    }

    private func positionPanel() {
        let mouseLocation = NSEvent.mouseLocation
        let activeScreen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
        guard let screenFrame = activeScreen?.visibleFrame ?? NSScreen.main?.visibleFrame else { return }

        let panelSize = panel.frame.size
        let origin = CGPoint(
            x: screenFrame.maxX - panelSize.width - 20,
            y: screenFrame.maxY - panelSize.height - 40
        )
        panel.setFrameOrigin(origin)
    }
}
