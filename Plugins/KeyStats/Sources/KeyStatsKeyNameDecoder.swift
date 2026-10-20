import Carbon
import CoreGraphics
import Foundation

struct KeyStatsModifierKey {
    let keyCode: Int
    let name: String
}

@MainActor
final class KeyStatsKeyNameDecoder {
    /// Caps Lock is a toggle, so its press is reported through `flagsChanged`
    /// instead of a regular key event.
    static let capsLockKeyCode = 57

    /// The Fn key is reported with two different key codes depending on the
    /// hardware revision.
    static let functionKeyCodes: Set<Int> = [63, 179]

    nonisolated private static let specialKeyNames: [Int: String] = [
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc",
        57: "Caps", 64: "F17", 71: "Clear", 76: "KPEnter", 79: "F18",
        80: "F19", 96: "F5", 97: "F6", 98: "F7", 99: "F3",
        100: "F8", 101: "F9", 103: "F11", 105: "F13", 106: "F16",
        107: "F14", 109: "F10", 111: "F12", 113: "F15", 114: "Help",
        115: "Home", 116: "PageUp", 117: "ForwardDelete", 118: "F4",
        119: "End", 120: "F2", 121: "PageDown", 122: "F1",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        179: "Fn",
    ]

    nonisolated private static let keypadKeyNames: [Int: String] = [
        65: "KP.", 67: "KP*", 69: "KP+", 75: "KP/", 78: "KP-", 81: "KP=",
        82: "KP0", 83: "KP1", 84: "KP2", 85: "KP3", 86: "KP4",
        87: "KP5", 88: "KP6", 89: "KP7", 91: "KP8", 92: "KP9",
    ]

    nonisolated private static let ansiFallbackNames: [Int: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L",
        38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "N", 46: "M", 47: ".", 50: "`",
    ]

    /// Reverse lookup used when reading statistics that were recorded before
    /// key presses were tracked by their physical key code.
    nonisolated private static let keyCodesByName: [String: Int] = {
        var result: [String: Int] = [:]
        for (keyCode, name) in ansiFallbackNames {
            result[name] = keyCode
        }
        for (keyCode, name) in specialKeyNames {
            result[name] = keyCode
        }
        for (keyCode, name) in keypadKeyNames {
            result[name] = keyCode
        }
        result["⌘L"] = 55
        result["⌘R"] = 54
        result["⇧L"] = 56
        result["⇧R"] = 60
        result["⌥L"] = 58
        result["⌥R"] = 61
        result["⌃L"] = 59
        result["⌃R"] = 62
        result["Fn"] = 63
        result["Caps"] = 57
        return result
    }()

    private var layoutData: CFData?
    nonisolated(unsafe) private var inputSourceObserver: NSObjectProtocol?

    init() {
        inputSourceObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshLayoutCache()
            }
        }
        refreshLayoutCache()
    }

    deinit {
        if let inputSourceObserver {
            DistributedNotificationCenter.default().removeObserver(inputSourceObserver)
        }
    }

    /// A human readable name for the key that produced the event.
    ///
    /// The name follows the active keyboard layout, so it may differ from the
    /// physical key the user pressed. Callers that need a stable identity must
    /// use the key code instead.
    func keyName(for keyCode: Int, keyboardType: UInt32) -> String {
        if let specialName = Self.specialKeyNames[keyCode] {
            return specialName
        }
        if let keypadName = Self.keypadKeyNames[keyCode] {
            return keypadName
        }
        if let translated = translatedKeyName(for: keyCode, keyboardType: keyboardType) {
            return translated
        }
        if let fallback = Self.ansiFallbackNames[keyCode] {
            return fallback
        }
        return "Key\(keyCode)"
    }

    /// The physical key code for a previously recorded name, when the name
    /// identifies exactly one key.
    nonisolated static func keyCode(forName name: String) -> Int? {
        keyCodesByName[name]
    }

    static func modifierKey(for keyCode: Int) -> KeyStatsModifierKey? {
        switch keyCode {
        case 55:
            return KeyStatsModifierKey(keyCode: keyCode, name: "⌘L")
        case 54:
            return KeyStatsModifierKey(keyCode: keyCode, name: "⌘R")
        case 56:
            return KeyStatsModifierKey(keyCode: keyCode, name: "⇧L")
        case 60:
            return KeyStatsModifierKey(keyCode: keyCode, name: "⇧R")
        case 58:
            return KeyStatsModifierKey(keyCode: keyCode, name: "⌥L")
        case 61:
            return KeyStatsModifierKey(keyCode: keyCode, name: "⌥R")
        case 59:
            return KeyStatsModifierKey(keyCode: keyCode, name: "⌃L")
        case 62:
            return KeyStatsModifierKey(keyCode: keyCode, name: "⌃R")
        case 63, 179:
            return KeyStatsModifierKey(keyCode: keyCode, name: "Fn")
        default:
            return nil
        }
    }

    static func isModifierKeyCode(_ keyCode: Int) -> Bool {
        modifierKey(for: keyCode) != nil || keyCode == capsLockKeyCode
    }

    private func translatedKeyName(for keyCode: Int, keyboardType: UInt32) -> String? {
        guard let layoutData, let layoutPointer = CFDataGetBytePtr(layoutData) else {
            return nil
        }

        return layoutPointer.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { keyboardLayout in
            var deadKeyState: UInt32 = 0
            var characters = [UniChar](repeating: 0, count: 4)
            var actualLength = 0

            let status = UCKeyTranslate(
                keyboardLayout,
                UInt16(keyCode),
                UInt16(kUCKeyActionDown),
                0,
                keyboardType,
                UInt32(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                characters.count,
                &actualLength,
                &characters
            )

            guard status == noErr, actualLength > 0 else {
                return nil
            }

            let raw = String(utf16CodeUnits: characters, count: actualLength)
            let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, cleaned.count == 1 else {
                return nil
            }

            switch cleaned {
            case " ":
                return "Space"
            case "\t":
                return "Tab"
            case "\r":
                return "Return"
            default:
                return cleaned.uppercased()
            }
        }
    }

    private func refreshLayoutCache() {
        let currentSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
        let currentDataPointer = currentSource.flatMap {
            TISGetInputSourceProperty($0, kTISPropertyUnicodeKeyLayoutData)
        }
        var data = currentDataPointer.map {
            Unmanaged<CFData>.fromOpaque($0).takeUnretainedValue()
        }

        if data == nil,
           let asciiSource = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() {
            let asciiDataPointer = TISGetInputSourceProperty(
                asciiSource,
                kTISPropertyUnicodeKeyLayoutData
            )
            data = asciiDataPointer.map {
                Unmanaged<CFData>.fromOpaque($0).takeUnretainedValue()
            }
        }

        layoutData = data
    }
}
