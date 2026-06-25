import Carbon
import Foundation

enum HotKeyEvent {
    case pressed

    case released

    static func fromCarbonEventKind(_ eventKind: UInt32) -> HotKeyEvent? {
        switch eventKind {
        case UInt32(kEventHotKeyPressed):
            return .pressed
        case UInt32(kEventHotKeyReleased):
            return .released
        default:
            return nil
        }
    }
}

@MainActor
final class HotKeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let handler: (HotKeyEvent) -> Void

    init(handler: @escaping (HotKeyEvent) -> Void) {
        self.handler = handler
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    func registerOptionV() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }

        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return noErr }

            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )

            guard status == noErr, hotKeyID.id == 1 else { return noErr }
            guard let hotKeyEvent = HotKeyEvent.fromCarbonEventKind(GetEventKind(event)) else { return noErr }

            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async {
                manager.handler(hotKeyEvent)
            }
            return noErr
        }

        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        var eventSpecs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        eventSpecs.withUnsafeBufferPointer { buffer in
            InstallEventHandler(GetApplicationEventTarget(), callback, buffer.count, buffer.baseAddress, userData, &eventHandlerRef)
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x434C4950), id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_V), UInt32(optionKey), hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}
