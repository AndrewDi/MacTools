import Foundation
import XCTest
@testable import KeyStatsPlugin

@MainActor
final class KeyStatsStoreTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    func testRecordsKeysAndTrackpadSessionsForToday() {
        let storage = KeyStatsMemoryStorage()
        let now = date(2026, 10, 19)
        let store = KeyStatsStore(
            storage: storage,
            calendar: calendar,
            dateProvider: { now }
        )

        store.recordKeyPress(keyCode: 0, name: "A")
        store.recordKeyPress(keyCode: 0, name: "A")
        store.recordKeyPress(keyCode: 49, name: "Space")
        store.recordTrackpadUse()

        XCTAssertEqual(store.today.date, "2026-10-19")
        XCTAssertEqual(store.today.totalKeyPresses, 3)
        XCTAssertEqual(store.today.count(forKeyCode: 0), 2)
        XCTAssertEqual(store.today.trackpadUses, 1)
        XCTAssertEqual(store.today.sortedPresses.map(\.name), ["A", "Space"])
    }

    func testKeyPressesAreCountedByPhysicalKeyCodeAcrossLayouts() {
        let storage = KeyStatsMemoryStorage()
        let now = date(2026, 10, 19)
        let store = KeyStatsStore(
            storage: storage,
            calendar: calendar,
            dateProvider: { now }
        )

        store.recordKeyPress(keyCode: 0, name: "A")
        store.recordKeyPress(keyCode: 0, name: "Ф")

        XCTAssertEqual(store.today.count(forKeyCode: 0), 2)
        XCTAssertEqual(store.today.usedKeyCount, 1)
        XCTAssertEqual(store.today.keyPresses.first?.name, "Ф")
    }

    func testPersistenceKeepsOnlySevenMostRecentDays() {
        let storage = KeyStatsMemoryStorage()
        var now = date(2026, 10, 12)
        let store = KeyStatsStore(
            storage: storage,
            calendar: calendar,
            dateProvider: { now }
        )

        for offset in 0..<9 {
            now = calendar.date(byAdding: .day, value: offset, to: date(2026, 10, 12))!
            store.recordKeyPress(keyCode: 0, name: "A")
            store.recordTrackpadUse()
        }

        store.flushPendingChanges()
        XCTAssertEqual(store.days.count, 7)
        XCTAssertNil(store.days["2026-10-12"])
        XCTAssertNotNil(store.days["2026-10-20"])

        let reloaded = KeyStatsStore(
            storage: storage,
            calendar: calendar,
            dateProvider: { now }
        )
        XCTAssertEqual(reloaded.days.count, 7)
        XCTAssertEqual(reloaded.today.totalKeyPresses, 1)
        XCTAssertEqual(reloaded.today.trackpadUses, 1)
    }

    func testDayChangeStartsANewZeroedTodayAndKeepsHistory() {
        let storage = KeyStatsMemoryStorage()
        var now = date(2026, 10, 19)
        let store = KeyStatsStore(
            storage: storage,
            calendar: calendar,
            dateProvider: { now }
        )

        store.recordKeyPress(keyCode: 0, name: "A")
        store.recordTrackpadUse()
        store.flushPendingChanges()

        now = date(2026, 10, 20)
        XCTAssertEqual(store.today.date, "2026-10-20")
        XCTAssertEqual(store.today.totalKeyPresses, 0)
        XCTAssertEqual(store.today.trackpadUses, 0)
        XCTAssertEqual(store.stats(for: "2026-10-19").totalKeyPresses, 1)
    }

    func testResetTodayKeepsPreviousDays() {
        let storage = KeyStatsMemoryStorage()
        var now = date(2026, 10, 18)
        let store = KeyStatsStore(
            storage: storage,
            calendar: calendar,
            dateProvider: { now }
        )

        store.recordKeyPress(keyCode: 0, name: "A")
        now = date(2026, 10, 19)
        store.recordKeyPress(keyCode: 11, name: "B")
        store.recordTrackpadUse()

        XCTAssertEqual(store.resetToday(), .committed)
        XCTAssertEqual(store.today.totalKeyPresses, 0)
        XCTAssertEqual(store.today.trackpadUses, 0)
        XCTAssertEqual(store.stats(for: "2026-10-18").count(forKeyCode: 0), 1)
    }

    func testRecentDaysIncludesTodayAndFillsMissingDays() {
        let storage = KeyStatsMemoryStorage()
        let now = date(2026, 10, 19)
        let store = KeyStatsStore(
            storage: storage,
            calendar: calendar,
            dateProvider: { now }
        )

        store.recordKeyPress(keyCode: 0, name: "A")
        let recent = store.recentDays(count: 7)

        XCTAssertEqual(recent.count, 7)
        XCTAssertEqual(recent.last?.date, "2026-10-19")
        XCTAssertEqual(recent.first?.date, "2026-10-13")
        XCTAssertEqual(recent.first?.totalKeyPresses, 0)
    }

    func testLegacyNamedCountsMigrateToPhysicalKeyCodes() throws {
        struct LegacyDay: Encodable {
            let date: String
            let keyPressCounts: [String: Int]
            let trackpadUses: Int
        }

        let storage = KeyStatsMemoryStorage()
        let now = date(2026, 10, 19)
        let legacy = [
            "2026-10-19": LegacyDay(
                date: "2026-10-19",
                keyPressCounts: ["A": 3, "Space": 1, "Ф": 2],
                trackpadUses: 1
            )
        ]
        storage.set(
            try JSONEncoder().encode(legacy),
            forKey: "key-stats.days.v1"
        )

        let store = KeyStatsStore(
            storage: storage,
            calendar: calendar,
            dateProvider: { now }
        )

        XCTAssertEqual(store.today.count(forKeyCode: 0), 3)
        XCTAssertEqual(store.today.count(forKeyCode: 49), 1)
        XCTAssertNil(store.today.sortedPresses.first { $0.name == "Ф" }?.keyCode)
    }

    func testLoadingPrunesDaysOutsideCalendarWindowAndPersistsCleanup() throws {
        let storage = KeyStatsMemoryStorage()
        var now = date(2026, 10, 1)
        let store = KeyStatsStore(
            storage: storage,
            calendar: calendar,
            dateProvider: { now }
        )

        store.recordKeyPress(keyCode: 0, name: "A")
        store.flushPendingChanges()

        now = date(2026, 10, 20)
        let reloaded = KeyStatsStore(
            storage: storage,
            calendar: calendar,
            dateProvider: { now }
        )

        XCTAssertTrue(reloaded.days.isEmpty)
        let data = try XCTUnwrap(storage.object(forKey: "key-stats.days.v1") as? Data)
        let persisted = try JSONDecoder().decode(
            [String: KeyStatsDailyStats].self,
            from: data
        )
        XCTAssertTrue(persisted.isEmpty)
    }

    func testDayChangePrunesExpiredDaysWithoutNewInput() {
        let storage = KeyStatsMemoryStorage()
        var now = date(2026, 10, 1)
        let store = KeyStatsStore(
            storage: storage,
            calendar: calendar,
            dateProvider: { now }
        )

        store.recordKeyPress(keyCode: 0, name: "A")
        store.flushPendingChanges()

        now = date(2026, 10, 20)
        store.flushPendingChanges()

        XCTAssertTrue(store.days.isEmpty)
    }
}
