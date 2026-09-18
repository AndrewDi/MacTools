import Foundation
import MacToolsPluginKit
import XCTest
@testable import ClipboardHistoryPlugin

@MainActor
final class ClipboardItemShortcutStoreTests: XCTestCase {
    func testTwoItemsRemainIndependentAcrossReloadAndExpiry() {
        let (storage, cleanup) = makeStorage()
        defer { cleanup() }
        var now = Date(timeIntervalSince1970: 1_000)
        let firstID = UUID()
        let secondID = UUID()
        let store = ClipboardItemShortcutStore(storage: storage, now: { now })
        let first = store.assign(itemID: firstID, source: .history, lifetime: .fiveMinutes)
        let second = store.assign(itemID: secondID, source: .snippet, lifetime: .oneDay)
        XCTAssertEqual(store.assignments.count, 2)
        XCTAssertEqual(store.activeHistoryItemIDs, [firstID])
        XCTAssertTrue(store.isCurrent(first.id, itemID: firstID))
        XCTAssertTrue(store.isCurrent(second.id, itemID: secondID))

        let reloaded = ClipboardItemShortcutStore(storage: storage, now: { now })
        XCTAssertEqual(reloaded.assignments.count, 2)
        now.addTimeInterval(301)
        reloaded.expireIfNeeded()
        XCTAssertNil(reloaded.assignment(for: firstID))
        XCTAssertTrue(reloaded.activeHistoryItemIDs.isEmpty)
        XCTAssertTrue(reloaded.isCurrent(second.id, itemID: secondID))
    }

    func testUntilRemovedSurvivesReloadAndItemDeletionRevokesIt() {
        let (storage, cleanup) = makeStorage()
        defer { cleanup() }
        let itemID = UUID()
        let store = ClipboardItemShortcutStore(storage: storage)
        let assignment = store.assign(itemID: itemID, source: .saved, lifetime: .untilRemoved)
        XCTAssertNil(assignment.expiresAt)

        let reloaded = ClipboardItemShortcutStore(storage: storage)
        var removed: [ClipboardItemShortcutStore.Assignment] = []
        reloaded.onRemoved = { removed.append(contentsOf: $0) }
        reloaded.removeMissingItems(historyIDs: [], savedIDs: [])
        XCTAssertEqual(removed.map(\.itemID), [itemID])
        XCTAssertNil(reloaded.assignment(for: itemID))
    }

    func testEditingLifetimeInvalidatesInFlightAssignment() {
        let (storage, cleanup) = makeStorage()
        defer { cleanup() }
        let itemID = UUID()
        let store = ClipboardItemShortcutStore(storage: storage)
        let first = store.assign(itemID: itemID, source: .snippet, lifetime: .oneHour)
        let second = store.assign(itemID: itemID, source: .snippet, lifetime: .untilRemoved)
        XCTAssertFalse(store.isCurrent(first.id, itemID: itemID))
        XCTAssertTrue(store.isCurrent(second.id, itemID: itemID))
        XCTAssertNil(second.expiresAt)
        XCTAssertEqual(ClipboardItemShortcutStore.itemID(for: second.definitionID), itemID)
    }

    private func makeStorage() -> (any PluginStorage, () -> Void) {
        let name = "ClipboardItemShortcutStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (
            UserDefaultsPluginStorage(pluginID: "clipboard", userDefaults: defaults),
            { defaults.removePersistentDomain(forName: name) }
        )
    }
}
