import AppKit
import ApplicationServices
import CryptoKit
import Foundation

struct PasteTarget {
    let application: NSRunningApplication?
    let focusedElement: AXUIElement?
}

@MainActor
final class PasteService {
    static func hasAccessibilityPermission(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func requestAccessibilityPermission() {
        _ = hasAccessibilityPermission(prompt: true)
    }

    func captureTarget(for application: NSRunningApplication?) -> PasteTarget {
        guard let application else {
            return PasteTarget(application: nil, focusedElement: nil)
        }

        let axApplication = AXUIElementCreateApplication(application.processIdentifier)
        var focusedElement: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            axApplication,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )

        return PasteTarget(
            application: application,
            focusedElement: status == .success ? focusedElement.map { $0 as! AXUIElement } : nil
        )
    }

    func paste(
        item: ClipboardItem,
        using store: ClipboardStore,
        panel: ClipboardPanel,
        target: PasteTarget
    ) -> Bool {
        let pasteboard = NSPasteboard.general
        let signature: String
        let textToInsert: String?

        switch item.kind {
        case .text:
            guard let text = item.textContent else { return false }
            signature = makeSignature(for: Data(text.utf8), prefix: "text")
            store.suppressNextCapture(signature: signature)
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            textToInsert = text
        case .image:
            guard let image = store.image(for: item),
                  let tiffData = image.tiffRepresentation else { return false }
            signature = makeSignature(for: tiffData, prefix: "image")
            store.suppressNextCapture(signature: signature)
            pasteboard.clearContents()
            pasteboard.writeObjects([image])
            textToInsert = nil
        }

        panel.hideImmediately()

        let canAutoPaste = Self.hasAccessibilityPermission(prompt: false)

        if canAutoPaste, let textToInsert, insertText(textToInsert, into: target.focusedElement) {
            activateTargetApplication(target.application)
            return true
        }

        if canAutoPaste {
            scheduleKeyboardPaste(to: target.application)
        } else {
            activateTargetApplication(target.application)
        }

        return true
    }

    private func activateTargetApplication(_ application: NSRunningApplication?) {
        application?.activate(options: [.activateAllWindows])
    }

    private func scheduleKeyboardPaste(to application: NSRunningApplication?) {
        Task { @MainActor in
            activateTargetApplication(application)

            for delay in [120_000_000, 240_000_000, 400_000_000] {
                try? await Task.sleep(nanoseconds: UInt64(delay))
                if application?.isActive == true {
                    break
                }
                activateTargetApplication(application)
            }

            postCommandV(to: application)
        }
    }

    private func postCommandV(to application: NSRunningApplication?) {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let commandDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true),
              let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false),
              let commandUp = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false) else {
            return
        }

        commandDown.flags = .maskCommand
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand

        if let application {
            commandDown.postToPid(application.processIdentifier)
            vDown.postToPid(application.processIdentifier)
            vUp.postToPid(application.processIdentifier)
            commandUp.postToPid(application.processIdentifier)
        } else {
            commandDown.post(tap: .cghidEventTap)
            vDown.post(tap: .cghidEventTap)
            vUp.post(tap: .cghidEventTap)
            commandUp.post(tap: .cghidEventTap)
        }
    }

    private func insertText(_ text: String, into focusedElement: AXUIElement?) -> Bool {
        guard let focusedElement,
              let currentValue = textValue(of: focusedElement),
              isValueSettable(on: focusedElement) else {
            return false
        }

        let nsCurrentValue = currentValue as NSString
        let replacementRange = replacementRange(in: nsCurrentValue, for: focusedElement)

        guard let replacementRange else { return false }

        let updatedValue = nsCurrentValue.replacingCharacters(in: replacementRange, with: text)
        let status = AXUIElementSetAttributeValue(
            focusedElement,
            kAXValueAttribute as CFString,
            updatedValue as CFTypeRef
        )
        guard status == .success else { return false }

        let newSelection = CFRange(location: replacementRange.location + (text as NSString).length, length: 0)
        setSelectedTextRange(newSelection, on: focusedElement)
        return true
    }

    private func textValue(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        guard status == .success else { return nil }
        return value as? String
    }

    private func isValueSettable(on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        return status == .success && settable.boolValue
    }

    private func selectedTextRange(of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value)
        guard status == .success, let value else { return nil }

        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }

        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }

    private func replacementRange(in currentValue: NSString, for element: AXUIElement) -> NSRange? {
        if let selectedRange = selectedTextRange(of: element) {
            let location = min(max(selectedRange.location, 0), currentValue.length)
            let length = min(max(selectedRange.length, 0), currentValue.length - location)
            return NSRange(location: location, length: length)
        }

        guard currentValue.length == 0 else { return nil }
        return NSRange(location: 0, length: 0)
    }

    private func setSelectedTextRange(_ range: CFRange, on element: AXUIElement) {
        var mutableRange = range
        guard let value = AXValueCreate(.cfRange, &mutableRange) else { return }
        _ = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
    }

    private func makeSignature(for data: Data, prefix: String) -> String {
        let hash = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
        return "\(prefix)-\(hash)"
    }
}
