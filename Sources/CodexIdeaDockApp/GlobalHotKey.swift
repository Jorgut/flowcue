import Carbon
import Carbon.HIToolbox

@MainActor
final class GlobalHotKey {
    enum RegistrationError: Error {
        case eventHandler(OSStatus)
        case hotKey(OSStatus)
    }

    private final class CarbonRegistration: @unchecked Sendable {
        var eventHandler: EventHandlerRef?
        var hotKey: EventHotKeyRef?
    }

    private let registration = CarbonRegistration()
    private let action: @MainActor () -> Void

    init(action: @escaping @MainActor () -> Void) throws {
        self.action = action

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.eventHandlerCallback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &registration.eventHandler
        )
        guard handlerStatus == noErr else {
            throw RegistrationError.eventHandler(handlerStatus)
        }

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        let hotKeyStatus = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(controlKey | optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &registration.hotKey
        )
        guard hotKeyStatus == noErr else {
            if let eventHandler = registration.eventHandler {
                RemoveEventHandler(eventHandler)
            }
            throw RegistrationError.hotKey(hotKeyStatus)
        }
    }

    deinit {
        if let hotKey = registration.hotKey {
            UnregisterEventHotKey(hotKey)
        }
        if let eventHandler = registration.eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    private func performAction() {
        action()
    }

    private static let signature: OSType = {
        let characters = Array("CIDE".utf8)
        return characters.reduce(0) { ($0 << 8) | OSType($1) }
    }()

    private static let eventHandlerCallback: EventHandlerUPP = { _, _, userData in
        guard let userData else { return OSStatus(eventNotHandledErr) }
        let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
        Task { @MainActor in
            hotKey.performAction()
        }
        return noErr
    }
}
