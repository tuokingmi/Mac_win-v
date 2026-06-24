import AppKit
import ApplicationServices
import Foundation

struct PasteTarget {
    let application: NSRunningApplication?
    let focusedElement: AXUIElement?
}

enum PastePayload {
    case text(String)
    case image(NSImage)
}

enum PastePlan {
    case text(String)
    case sequential([PastePayload])
}

@MainActor
final class PasteService {
    private let multiPasteInterval: UInt64 = 220_000_000

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

    func makePlan(for items: [ClipboardItem], using store: ClipboardStore) -> PastePlan? {
        guard items.isEmpty == false else { return nil }

        if items.allSatisfy({ $0.kind == .text }) {
            let texts = items.compactMap(\.textContent)
            guard texts.count == items.count else { return nil }
            return .text(texts.joined(separator: "\n"))
        }

        var payloads: [PastePayload] = []
        for item in items {
            switch item.kind {
            case .text:
                guard let text = item.textContent else { return nil }
                payloads.append(.text(text))
            case .image:
                guard let image = store.image(for: item) else { return nil }
                payloads.append(.image(image))
            }
        }
        return .sequential(payloads)
    }

    func execute(_ plan: PastePlan, using store: ClipboardStore, target: PasteTarget) {
        let pasteboard = NSPasteboard.general
        let canAutoPaste = Self.hasAccessibilityPermission(prompt: false)

        switch plan {
        case .text(let text):
            write(.text(text), to: pasteboard)
            markInternalWrite(pasteboard: pasteboard, store: store)

            if canAutoPaste, insertText(text, into: target.focusedElement) {
                activateTargetApplication(target.application)
                return
            }

            if canAutoPaste {
                scheduleKeyboardPaste(to: target.application)
            } else {
                activateTargetApplication(target.application)
            }

        case .sequential(let payloads):
            if canAutoPaste {
                executeSequential(payloads, pasteboard: pasteboard, store: store, target: target)
            } else {
                write(payloads, to: pasteboard)
                markInternalWrite(pasteboard: pasteboard, store: store)
                activateTargetApplication(target.application)
            }
        }
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

    private func executeSequential(
        _ payloads: [PastePayload],
        pasteboard: NSPasteboard,
        store: ClipboardStore,
        target: PasteTarget
    ) {
        Task { @MainActor in
            activateTargetApplication(target.application)
            await waitForActivation(target.application)

            for (index, payload) in payloads.enumerated() {
                write(payload, to: pasteboard)
                markInternalWrite(pasteboard: pasteboard, store: store)
                postCommandV(to: target.application)

                if index < payloads.count - 1 {
                    try? await Task.sleep(nanoseconds: multiPasteInterval)
                }
            }
        }
    }

    private func waitForActivation(_ application: NSRunningApplication?) async {
        for delay in [120_000_000, 240_000_000, 400_000_000] {
            if application?.isActive == true {
                return
            }
            try? await Task.sleep(nanoseconds: UInt64(delay))
            activateTargetApplication(application)
        }
    }

    private func write(_ payload: PastePayload, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        switch payload {
        case .text(let text):
            pasteboard.setString(text, forType: .string)
        case .image(let image):
            pasteboard.writeObjects([image])
        }
    }

    private func write(_ payloads: [PastePayload], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let objects: [NSPasteboardWriting] = payloads.map { payload in
            switch payload {
            case .text(let text):
                return text as NSString
            case .image(let image):
                return image
            }
        }
        pasteboard.writeObjects(objects)
    }

    private func markInternalWrite(pasteboard: NSPasteboard, store: ClipboardStore) {
        store.suppressCapture(changeCount: pasteboard.changeCount)
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
}
