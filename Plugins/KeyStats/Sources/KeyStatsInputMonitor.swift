import ApplicationServices
import CoreGraphics
import Foundation
import MacToolsPluginKit

@MainActor
protocol KeyStatsInputMonitoring: AnyObject {
    var status: KeyStatsInputMonitorStatus { get }
    var onEvent: ((KeyStatsInputEvent) -> Void)? { get set }

    func start()
    func stop()
}

@MainActor
final class KeyStatsInputMonitor: KeyStatsInputMonitoring {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let decoder = KeyStatsKeyNameDecoder()

    /// Physical modifier key codes that are currently held down. `flagsChanged`
    /// fires for both presses and releases, so this state is required to count
    /// each modifier press exactly once.
    private var pressedModifierKeyCodes: Set<Int> = []

    var status: KeyStatsInputMonitorStatus = .idle
    var onEvent: ((KeyStatsInputEvent) -> Void)?

    func start() {
        guard status != .running else {
            return
        }
        guard CGPreflightListenEventAccess() else {
            status = .inputMonitoringDenied
            KeyStatsLog.input.warning("Input Monitoring is not granted")
            return
        }

        let eventMask = CGEventMask(
            (1 << CGEventType.keyDown.rawValue) |
                (1 << CGEventType.flagsChanged.rawValue)
        )
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: { _, eventType, event, userInfo -> Unmanaged<CGEvent>? in
                guard let userInfo else {
                    return Unmanaged.passUnretained(event)
                }

                let monitor = Unmanaged<KeyStatsInputMonitor>
                    .fromOpaque(userInfo)
                    .takeUnretainedValue()

                if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
                    Task { @MainActor in
                        monitor.reenableTap()
                    }
                    return Unmanaged.passUnretained(event)
                }

                guard eventType == .keyDown || eventType == .flagsChanged else {
                    return Unmanaged.passUnretained(event)
                }

                let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
                let keyboardType = UInt32(event.getIntegerValueField(.keyboardEventKeyboardType))
                let flags = event.flags
                let isAutoRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

                Task { @MainActor in
                    monitor.handle(
                        type: eventType,
                        keyCode: keyCode,
                        keyboardType: keyboardType,
                        flags: flags,
                        isAutoRepeat: isAutoRepeat
                    )
                }

                return Unmanaged.passUnretained(event)
            },
            userInfo: userInfo
        ) else {
            status = .inputMonitoringDenied
            KeyStatsLog.input.warning("Input event tap could not be created")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        status = .running
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }

        eventTap = nil
        runLoopSource = nil
        pressedModifierKeyCodes.removeAll()
        status = .idle
    }

    private func reenableTap() {
        guard let eventTap else {
            return
        }
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    func handle(
        type: CGEventType,
        keyCode: Int,
        keyboardType: UInt32,
        flags: CGEventFlags,
        isAutoRepeat: Bool
    ) {
        switch type {
        case .flagsChanged:
            handleModifierFlagsChanged(keyCode: keyCode, flags: flags)

        case .keyDown:
            guard !isAutoRepeat else {
                return
            }
            guard !KeyStatsKeyNameDecoder.isModifierKeyCode(keyCode) else {
                return
            }
            onEvent?(
                .keyPress(
                    keyCode: keyCode,
                    name: decoder.keyName(for: keyCode, keyboardType: keyboardType)
                )
            )

        default:
            break
        }
    }

    private func handleModifierFlagsChanged(keyCode: Int, flags: CGEventFlags) {
        // Caps Lock is a toggle: every `flagsChanged` event is a distinct press
        // because there is no separate key-up event to pair with it.
        if keyCode == KeyStatsKeyNameDecoder.capsLockKeyCode {
            onEvent?(.keyPress(keyCode: keyCode, name: "Caps"))
            return
        }

        // Fn is reported as 63 on most keyboards and 179 on some hardware.
        // Canonicalize both to one physical identity.
        let identityKeyCode = KeyStatsKeyNameDecoder.functionKeyCodes.contains(keyCode) ? 63 : keyCode
        guard let modifier = KeyStatsKeyNameDecoder.modifierKey(for: identityKeyCode) else {
            return
        }

        if isModifierPressed(keyCode: identityKeyCode, flags: flags) {
            guard pressedModifierKeyCodes.insert(identityKeyCode).inserted else {
                return
            }
            onEvent?(.keyPress(keyCode: identityKeyCode, name: modifier.name))
        } else {
            pressedModifierKeyCodes.remove(identityKeyCode)
        }
    }

    private func isModifierPressed(keyCode: Int, flags: CGEventFlags) -> Bool {
        if keyCode == 63 {
            return flags.contains(.maskSecondaryFn)
        }

        return KeyboardKeyTapEventTransition.isModifierPress(
            keyCode: UInt16(keyCode),
            flags: flags
        )
    }
}
