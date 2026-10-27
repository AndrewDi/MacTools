import MacToolsPluginKit
import XCTest
@testable import NotchHoverPanelPlugin

@MainActor
private final class NotchHoverMemoryStorage: PluginStorage {
    var values: [String: Any] = [:]

    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {
        guard legacyKey != key, values[key] == nil, let value = values[legacyKey] else { return }
        values[key] = value
        values.removeValue(forKey: legacyKey)
    }
}

@MainActor
final class NotchHoverPanelControllerTests: XCTestCase {
    func testMenuBarIconIsHiddenByDefault() {
        let controller = makeController(storage: NotchHoverMemoryStorage())

        XCTAssertTrue(controller.snapshot.isEnabled)
        XCTAssertFalse(
            controller.snapshot.showsMenuBarIcon,
            "A freshly installed plugin should hide the host menu-bar icon."
        )
    }

    func testMenuBarIconPreferenceRequestsHostVisibilityAndPersists() {
        let storage = NotchHoverMemoryStorage()
        let controller = makeController(storage: storage)
        var requests: [Bool] = []
        controller.requestAppMenuBarIconVisibility = { requests.append($0) }

        controller.setShowsMenuBarIcon(true)

        XCTAssertEqual(requests, [true])
        XCTAssertTrue(controller.snapshot.showsMenuBarIcon)
        XCTAssertTrue(storage.bool(forKey: "notch-hover.show-menu-bar-icon"))

        controller.setEnabled(false)

        XCTAssertEqual(requests, [true, true], "Disabling the plugin must restore the host icon.")
    }

    private func makeController(storage: NotchHoverMemoryStorage) -> NotchHoverPanelController {
        NotchHoverPanelController(
            storage: storage,
            screensProvider: { [] },
            mouseLocationProvider: { .zero }
        )
    }
}
