import Foundation
import XCTest
@testable import MacTools

@MainActor
final class PluginOrderingStoreTests: XCTestCase {
    func testManagementOrderMigratesAndPreservesUnavailablePluginSlots() throws {
        let name = "PluginOrderingStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data(#"{"version":4,"generalPluginOrder":["a","missing","b"]}"#.utf8),
                     forKey: MenuBarPanelStore.legacyDisplayStorageKey)
        let store = PluginOrderingStore(userDefaults: defaults)
        XCTAssertEqual(store.orderedPluginIDs(defaultPluginIDs: ["b", "a"]), ["a", "b"])
        store.setOrderedPluginIDs(["b", "a"], defaultPluginIDs: ["a", "b"])
        let reloaded = PluginOrderingStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.orderedPluginIDs(defaultPluginIDs: ["a", "b", "missing"]), ["b", "missing", "a"])
    }

    func testUnknownLegacyPayloadIsNotOverwritten() throws {
        let name = "PluginOrderingStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let data = Data(#"{"version":99,"generalPluginOrder":["a"],"future":"preserve"}"#.utf8)
        defaults.set(data, forKey: MenuBarPanelStore.legacyDisplayStorageKey)
        let store = PluginOrderingStore(userDefaults: defaults)
        store.setOrderedPluginIDs(["b", "a"], defaultPluginIDs: ["a", "b"])
        XCTAssertEqual(defaults.data(forKey: MenuBarPanelStore.legacyDisplayStorageKey), data)
    }

    func testLegacyVisibilityVersionsRemainReadableWithoutRuntimeSurfaceStores() throws {
        for version in 1...4 {
            let object: [String: Any] = [
                "version": version, "orderedPluginIDs": ["a"], "generalPluginOrder": ["a"],
                "hiddenPluginIDs": ["a"], "globallyHiddenPluginIDs": ["a"],
                "pendingLegacyDisabledPluginIDs": ["a"], "legacyHiddenPluginIDs": ["a"],
            ]
            let preferences = try LegacyPanelDisplayPreferences(data: JSONSerialization.data(withJSONObject: object))
            XCTAssertEqual(preferences.generalOrder, ["a"])
            XCTAssertEqual(preferences.dashboardHidden, ["a"])
            XCTAssertEqual(preferences.featureHidden, ["a"])
        }
    }
}
