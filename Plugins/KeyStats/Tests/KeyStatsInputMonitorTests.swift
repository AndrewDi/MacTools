import CoreGraphics
import XCTest
@testable import KeyStatsPlugin

@MainActor
final class KeyStatsInputMonitorTests: XCTestCase {
    func testModifierReleaseIsNotCountedWhileOtherSideStaysHeld() {
        let monitor = KeyStatsInputMonitor()
        var events: [KeyStatsInputEvent] = []
        monitor.onEvent = { events.append($0) }

        let leftShiftIdentity = CGEventFlags(rawValue: 0x02)
        let rightShiftIdentity = CGEventFlags(rawValue: 0x04)

        monitor.handle(
            type: .flagsChanged,
            keyCode: 56,
            keyboardType: 0,
            flags: [.maskShift, leftShiftIdentity],
            isAutoRepeat: false
        )
        monitor.handle(
            type: .flagsChanged,
            keyCode: 56,
            keyboardType: 0,
            flags: [.maskShift, rightShiftIdentity],
            isAutoRepeat: false
        )
        monitor.handle(
            type: .flagsChanged,
            keyCode: 56,
            keyboardType: 0,
            flags: [.maskShift, leftShiftIdentity],
            isAutoRepeat: false
        )

        XCTAssertEqual(events, [
            .keyPress(keyCode: 56, name: "⇧L"),
            .keyPress(keyCode: 56, name: "⇧L"),
        ])
    }

    func testFnHardwareKeyCodesShareOneIdentity() {
        let monitor = KeyStatsInputMonitor()
        var events: [KeyStatsInputEvent] = []
        monitor.onEvent = { events.append($0) }

        monitor.handle(
            type: .flagsChanged,
            keyCode: 179,
            keyboardType: 0,
            flags: [.maskSecondaryFn],
            isAutoRepeat: false
        )
        monitor.handle(
            type: .flagsChanged,
            keyCode: 179,
            keyboardType: 0,
            flags: [],
            isAutoRepeat: false
        )

        XCTAssertEqual(events, [.keyPress(keyCode: 63, name: "Fn")])
    }

    func testCapsLockCountsEachToggle() {
        let monitor = KeyStatsInputMonitor()
        var events: [KeyStatsInputEvent] = []
        monitor.onEvent = { events.append($0) }

        monitor.handle(
            type: .flagsChanged,
            keyCode: 57,
            keyboardType: 0,
            flags: [.maskAlphaShift],
            isAutoRepeat: false
        )
        monitor.handle(
            type: .flagsChanged,
            keyCode: 57,
            keyboardType: 0,
            flags: [],
            isAutoRepeat: false
        )

        XCTAssertEqual(events, [
            .keyPress(keyCode: 57, name: "Caps"),
            .keyPress(keyCode: 57, name: "Caps"),
        ])
    }
}
