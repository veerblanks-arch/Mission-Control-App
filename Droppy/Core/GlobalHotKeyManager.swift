import Carbon
import Foundation

final class GlobalHotKeyManager {
    private var eventHandlerRef: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    private var onPressed: (() -> Void)?

    func registerCommandShiftV(onPressed: @escaping () -> Void) {
        unregister()
        self.onPressed = onPressed

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else {
                    return noErr
                }

                let manager = Unmanaged<GlobalHotKeyManager>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                manager.onPressed?()
                return noErr
            },
            1,
            &eventType,
            userData,
            &eventHandlerRef
        )

        let hotKeyID = EventHotKeyID(
            signature: GlobalHotKeyManager.fourCharacterCode("DROP"),
            id: 1
        )

        RegisterEventHotKey(
            UInt32(kVK_ANSI_V),
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }

        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }

        hotKeyRef = nil
        eventHandlerRef = nil
        onPressed = nil
    }

    private static func fourCharacterCode(_ string: String) -> OSType {
        var result: OSType = 0
        for scalar in string.unicodeScalars.prefix(4) {
            result = (result << 8) + OSType(scalar.value)
        }
        return result
    }
}
