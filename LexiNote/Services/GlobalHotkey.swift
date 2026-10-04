import Carbon
import Foundation

/// A physical key and its Carbon modifier flags, suitable for persistence in settings.
struct HotkeyShortcut: Codable, Equatable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let defaultShortcut = HotkeyShortcut(
        keyCode: UInt32(kVK_ANSI_L),
        modifiers: UInt32(controlKey | optionKey)
    )
    static let defaultSaveShortcut = HotkeyShortcut(
        keyCode: UInt32(kVK_ANSI_S),
        modifiers: UInt32(controlKey | optionKey)
    )
    static let defaultRecommendationShortcut = HotkeyShortcut(
        keyCode: UInt32(kVK_ANSI_R),
        modifiers: UInt32(controlKey | optionKey)
    )

    var displayString: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + keyLabel
    }

    private var keyLabel: String {
        switch Int(keyCode) {
        case kVK_ANSI_A: "A"
        case kVK_ANSI_B: "B"
        case kVK_ANSI_C: "C"
        case kVK_ANSI_D: "D"
        case kVK_ANSI_E: "E"
        case kVK_ANSI_F: "F"
        case kVK_ANSI_G: "G"
        case kVK_ANSI_H: "H"
        case kVK_ANSI_I: "I"
        case kVK_ANSI_J: "J"
        case kVK_ANSI_K: "K"
        case kVK_ANSI_L: "L"
        case kVK_ANSI_M: "M"
        case kVK_ANSI_N: "N"
        case kVK_ANSI_O: "O"
        case kVK_ANSI_P: "P"
        case kVK_ANSI_Q: "Q"
        case kVK_ANSI_R: "R"
        case kVK_ANSI_S: "S"
        case kVK_ANSI_T: "T"
        case kVK_ANSI_U: "U"
        case kVK_ANSI_V: "V"
        case kVK_ANSI_W: "W"
        case kVK_ANSI_X: "X"
        case kVK_ANSI_Y: "Y"
        case kVK_ANSI_Z: "Z"
        case kVK_ANSI_0: "0"
        case kVK_ANSI_1: "1"
        case kVK_ANSI_2: "2"
        case kVK_ANSI_3: "3"
        case kVK_ANSI_4: "4"
        case kVK_ANSI_5: "5"
        case kVK_ANSI_6: "6"
        case kVK_ANSI_7: "7"
        case kVK_ANSI_8: "8"
        case kVK_ANSI_9: "9"
        case kVK_Return: "↩"
        case kVK_Tab: "⇥"
        case kVK_Space: "Space"
        case kVK_Delete: "⌫"
        case kVK_Escape: "Esc"
        case kVK_LeftArrow: "←"
        case kVK_RightArrow: "→"
        case kVK_UpArrow: "↑"
        case kVK_DownArrow: "↓"
        default: "Key \(keyCode)"
        }
    }
}

enum HotkeyError: LocalizedError {
    case handlerInstallationFailed(OSStatus)
    case registrationFailed(OSStatus)
    case duplicateShortcut

    var errorDescription: String? {
        switch self {
        case .handlerInstallationFailed(let status):
            return "无法监听全局快捷键（错误 \(status)）。"
        case .registrationFailed(let status):
            return "无法注册快捷键，可能已被其他应用占用（错误 \(status)）。"
        case .duplicateShortcut:
            return "全局快捷键不能相同。"
        }
    }
}

enum HotkeyAction: UInt32, CaseIterable {
    case lookup = 1
    case save = 2
    case recommendation = 3
}

/// Registers an application-wide hotkey with Carbon. Call from the main actor.
@MainActor
final class HotkeyManager {
    private static let signature: OSType = 0x4C584E54 // "LXNT"

    private var handler: EventHandlerRef?
    private struct Registration {
        let reference: EventHotKeyRef
        let id: UInt32
        let shortcut: HotkeyShortcut
        let onPress: () -> Void
    }
    private var registrations: [HotkeyAction: Registration] = [:]
    private var nextID: UInt32 = 1

    /// Keeps the previous shortcut active if registration of the new one fails.
    func register(action: HotkeyAction, shortcut: HotkeyShortcut, onPress: @escaping () -> Void) throws {
        guard !registrations.contains(where: { $0.key != action && $0.value.shortcut == shortcut }) else {
            throw HotkeyError.duplicateShortcut
        }
        if let previous = registrations[action], previous.shortcut == shortcut {
            registrations[action] = Registration(reference: previous.reference, id: previous.id,
                                                 shortcut: shortcut, onPress: onPress)
            return
        }

        let installedHandlerForThisCall = handler == nil
        if installedHandlerForThisCall {
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
            let status = InstallEventHandler(
                GetApplicationEventTarget(),
                lexiNoteHotkeyEventHandler,
                1,
                &eventType,
                Unmanaged.passUnretained(self).toOpaque(),
                &handler
            )
            guard status == noErr else {
                throw HotkeyError.handlerInstallationFailed(status)
            }
        }

        let id = nextID
        nextID &+= 1
        var newHotkey: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(),
            0,
            &newHotkey
        )
        guard status == noErr, let newHotkey else {
            if installedHandlerForThisCall, let handler {
                RemoveEventHandler(handler)
                self.handler = nil
            }
            throw HotkeyError.registrationFailed(status)
        }

        if let previous = registrations[action] {
            UnregisterEventHotKey(previous.reference)
        }
        registrations[action] = Registration(reference: newHotkey, id: id,
                                             shortcut: shortcut, onPress: onPress)
    }

    func unregister(action: HotkeyAction) {
        guard let registration = registrations.removeValue(forKey: action) else { return }
        UnregisterEventHotKey(registration.reference)
        if registrations.isEmpty, let handler {
            RemoveEventHandler(handler)
            self.handler = nil
        }
    }

    func unregister() {
        for registration in registrations.values {
            UnregisterEventHotKey(registration.reference)
        }
        registrations.removeAll()

        if let handler {
            RemoveEventHandler(handler)
            self.handler = nil
        }
    }

    fileprivate func handlePress(id: EventHotKeyID) -> Bool {
        guard id.signature == Self.signature,
              let registration = registrations.values.first(where: { $0.id == id.id }) else { return false }
        registration.onPress()
        return true
    }

    deinit {
        for registration in registrations.values { UnregisterEventHotKey(registration.reference) }
        if let handler { RemoveEventHandler(handler) }
    }
}

/// Carbon dispatches application event target events on the main application event loop.
private func lexiNoteHotkeyEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }

    var id = EventHotKeyID(signature: 0, id: 0)
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &id
    )
    guard status == noErr else { return status }

    let handled = MainActor.assumeIsolated {
        Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue().handlePress(id: id)
    }
    return handled ? noErr : OSStatus(eventNotHandledErr)
}
