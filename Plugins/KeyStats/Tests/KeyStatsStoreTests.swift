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

        store.recordKeyPress("A")
        store.recordKeyPress("A")
        store.recordKeyPress("Space")
        store.recordTrackpadUse()

        XCTAssertEqual(store.today.date, "2026-10-19")
        XCTAssertEqual(store.today.totalKeyPresses, 3)
        XCTAssertEqual(store.today.keyPressCounts["A"], 2)
        XCTAssertEqual(store.today.trackpadUses, 1)
        XCTAssertEqual(store.today.sortedKeys.map(\.name), ["A", "Space"])
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
            store.recordKeyPress("A")
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

        store.recordKeyPress("A")
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

        store.recordKeyPress("A")
        now = date(2026, 10, 19)
        store.recordKeyPress("B")
        store.recordTrackpadUse()

        XCTAssertEqual(store.resetToday(), .committed)
        XCTAssertEqual(store.today.totalKeyPresses, 0)
        XCTAssertEqual(store.today.trackpadUses, 0)
        XCTAssertEqual(store.stats(for: "2026-10-18").keyPressCounts["A"], 1)
    }

    func testRecentDaysIncludesTodayAndFillsMissingDays() {
        let storage = KeyStatsMemoryStorage()
        let now = date(2026, 10, 19)
        let store = KeyStatsStore(
            storage: storage,
            calendar: calendar,
            dateProvider: { now }
        )

        store.recordKeyPress("A")
        let recent = store.recentDays(count: 7)

        XCTAssertEqual(recent.count, 7)
        XCTAssertEqual(recent.last?.date, "2026-10-19")
        XCTAssertEqual(recent.first?.date, "2026-10-13")
        XCTAssertEqual(recent.first?.totalKeyPresses, 0)
    }
}
