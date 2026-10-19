import XCTest
@testable import KeyStatsPlugin

@MainActor
final class KeyStatsKeyNameDecoderTests: XCTestCase {
    func testSpecialKeysUseReadableNames() {
        let decoder = KeyStatsKeyNameDecoder()

        XCTAssertEqual(decoder.keyName(for: 36, keyboardType: 0), "Return")
        XCTAssertEqual(decoder.keyName(for: 49, keyboardType: 0), "Space")
        XCTAssertEqual(decoder.keyName(for: 53, keyboardType: 0), "Esc")
        XCTAssertEqual(decoder.keyName(for: 123, keyboardType: 0), "←")
        XCTAssertEqual(decoder.keyName(for: 122, keyboardType: 0), "F1")
    }

    func testModifierKeyNamesDistinguishSides() {
        XCTAssertEqual(KeyStatsKeyNameDecoder.modifierKey(for: 55)?.name, "⌘L")
        XCTAssertEqual(KeyStatsKeyNameDecoder.modifierKey(for: 54)?.name, "⌘R")
        XCTAssertEqual(KeyStatsKeyNameDecoder.modifierKey(for: 63)?.name, "Fn")
        XCTAssertTrue(KeyStatsKeyNameDecoder.isModifierKeyCode(57))
        XCTAssertFalse(KeyStatsKeyNameDecoder.isModifierKeyCode(0))
    }
}
