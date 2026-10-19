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
        status = .idle
    }

    private func reenableTap() {
        guard let eventTap else {
            return
        }
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    private func handle(
        type: CGEventType,
        keyCode: Int,
        keyboardType: UInt32,
        flags: CGEventFlags,
        isAutoRepeat: Bool
    ) {
        switch type {
        case .flagsChanged:
            if keyCode == 57 {
                onEvent?(.keyPress(name: "Caps"))
            } else if let modifier = KeyStatsKeyNameDecoder.modifierKey(for: keyCode),
                      flags.contains(modifier.flag) {
                onEvent?(.keyPress(name: modifier.name))
            }

        case .keyDown:
            guard !isAutoRepeat else {
                return
            }
            guard !KeyStatsKeyNameDecoder.isModifierKeyCode(keyCode) else {
                return
            }
            onEvent?(.keyPress(name: decoder.keyName(for: keyCode, keyboardType: keyboardType)))

        default:
            break
        }
    }
}
