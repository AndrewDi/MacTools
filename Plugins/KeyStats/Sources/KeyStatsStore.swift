import Foundation
import MacToolsPluginKit
import OSLog

enum KeyStatsLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools"
    static let store = Logger(subsystem: subsystem, category: "KeyStatsStore")
    static let input = Logger(subsystem: subsystem, category: "KeyStatsInput")
}

enum KeyStatsPersistenceMutationResult: Equatable {
    case committed
    case rejected(rollbackSucceeded: Bool)
    case recoveryRequired
}

@MainActor
final class KeyStatsStore: ObservableObject {
    private enum StorageKey {
        static let days = "key-stats.days.v1"
    }

    private enum Persistence {
        static let debounceDelay: Duration = .seconds(5)
        static let retainedDayCount = 7
    }

    @Published private(set) var days: [String: KeyStatsDailyStats]
    private(set) var loadError: String?

    private let storage: PluginStorage
    private let calendar: Calendar
    private let dateProvider: () -> Date
    private let persistenceDelay: Duration
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var persistenceTask: Task<Void, Never>?
    private var hasPendingChanges = false

    init(
        storage: PluginStorage,
        calendar: Calendar = .autoupdatingCurrent,
        dateProvider: @escaping () -> Date = Date.init,
        persistenceDelay: Duration = Persistence.debounceDelay
    ) {
        self.storage = storage
        self.calendar = calendar
        self.dateProvider = dateProvider
        self.persistenceDelay = persistenceDelay
        let loaded = Self.loadDays(storage: storage, decoder: decoder)
        self.days = loaded.days
        self.loadError = loaded.error

        // Drop records outside the calendar-day window and persist the cleanup
        // even when the user has not pressed a key since the last launch.
        pruneExpiredDays()
        if hasPendingChanges {
            persistPendingChanges()
        }
    }

    deinit {
        persistenceTask?.cancel()
    }

    var today: KeyStatsDailyStats {
        let key = dateKey(for: dateProvider())
        return days[key] ?? KeyStatsDailyStats(date: key)
    }

    var retainedDayCount: Int {
        Persistence.retainedDayCount
    }

    func stats(for date: String) -> KeyStatsDailyStats {
        days[date] ?? KeyStatsDailyStats(date: date)
    }

    func recentDays(count: Int, endingAt endDate: Date? = nil) -> [KeyStatsDailyStats] {
        let end = endDate ?? dateProvider()
        let boundedCount = max(count, 1)

        return (0..<boundedCount).reversed().map { offset in
            let date = calendar.date(byAdding: .day, value: -offset, to: end) ?? end
            return stats(for: dateKey(for: date))
        }
    }

    func record(_ event: KeyStatsInputEvent) {
        switch event {
        case let .keyPress(keyCode, name):
            recordKeyPress(keyCode: keyCode, name: name)
        case .trackpadUse:
            recordTrackpadUse()
        }
    }

    func recordKeyPress(keyCode: Int, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        mutateToday { day in
            if let index = day.keyPresses.firstIndex(where: { $0.keyCode == keyCode }) {
                day.keyPresses[index].count += 1
                day.keyPresses[index].name = trimmed
            } else if let index = day.keyPresses.firstIndex(where: {
                $0.keyCode == nil && $0.name == trimmed
            }) {
                // Upgrade a legacy name-only record to a stable key code.
                day.keyPresses[index].keyCode = keyCode
                day.keyPresses[index].count += 1
            } else {
                day.keyPresses.append(
                    KeyStatsKeyPress(keyCode: keyCode, name: trimmed, count: 1)
                )
            }
        }
    }

    func recordTrackpadUse() {
        mutateToday { day in
            day.trackpadUses += 1
        }
    }

    struct PreparedTodayReset {
        fileprivate let previousDays: [String: KeyStatsDailyStats]
        fileprivate let previousRawValue: Any?
        fileprivate let previousHadPendingChanges: Bool
        fileprivate let candidateDays: [String: KeyStatsDailyStats]
        fileprivate let candidateData: Data
    }

    func prepareTodayReset() -> PreparedTodayReset? {
        guard loadError == nil else {
            return nil
        }

        var candidateDays = days
        let key = dateKey(for: dateProvider())
        candidateDays[key] = KeyStatsDailyStats(date: key)
        candidateDays = prunedDays(candidateDays)

        guard let candidateData = try? encoder.encode(candidateDays) else {
            return nil
        }

        return PreparedTodayReset(
            previousDays: days,
            previousRawValue: storage.object(forKey: StorageKey.days),
            previousHadPendingChanges: hasPendingChanges,
            candidateDays: candidateDays,
            candidateData: candidateData
        )
    }

    @discardableResult
    func commitTodayReset(_ prepared: PreparedTodayReset) -> KeyStatsPersistenceMutationResult {
        storage.set(prepared.candidateData, forKey: StorageKey.days)
        guard storage.object(forKey: StorageKey.days) as? Data == prepared.candidateData else {
            let rollbackSucceeded = restoreStorageValue(
                prepared.previousRawValue,
                forKey: StorageKey.days
            )
            if !rollbackSucceeded {
                reloadFromStorage()
            }
            return .rejected(rollbackSucceeded: rollbackSucceeded)
        }

        persistenceTask?.cancel()
        persistenceTask = nil
        days = prepared.candidateDays
        hasPendingChanges = false
        loadError = nil
        return .committed
    }

    @discardableResult
    func resetToday() -> KeyStatsPersistenceMutationResult {
        guard let prepared = prepareTodayReset() else {
            return .recoveryRequired
        }
        return commitTodayReset(prepared)
    }

    func flushPendingChanges() {
        persistPendingChanges()
    }

    private func mutateToday(_ update: (inout KeyStatsDailyStats) -> Void) {
        guard loadError == nil else {
            return
        }

        let key = dateKey(for: dateProvider())
        var day = days[key] ?? KeyStatsDailyStats(date: key)
        update(&day)
        days[key] = day
        hasPendingChanges = true
        schedulePersistence()
    }

    private func dateKey(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 0
        let month = components.month ?? 0
        let day = components.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private func schedulePersistence() {
        guard persistenceTask == nil else {
            return
        }

        persistenceTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            do {
                try await Task.sleep(for: self.persistenceDelay)
            } catch {
                return
            }

            guard !Task.isCancelled else {
                return
            }

            self.persistPendingChanges()
        }
    }

    private func persistPendingChanges(force: Bool = false) {
        persistenceTask?.cancel()
        persistenceTask = nil

        guard loadError == nil else {
            return
        }
        pruneExpiredDays()
        guard force || hasPendingChanges else {
            return
        }

        do {
            let data = try encoder.encode(days)
            storage.set(data, forKey: StorageKey.days)
            hasPendingChanges = false
        } catch {
            KeyStatsLog.store.error(
                "Failed to persist key stats: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func reloadFromStorage() {
        let loaded = Self.loadDays(storage: storage, decoder: decoder)
        days = loaded.days
        loadError = loaded.error
        hasPendingChanges = false
        persistenceTask?.cancel()
        persistenceTask = nil
        pruneExpiredDays()
    }

    private func restoreStorageValue(_ value: Any?, forKey key: String) -> Bool {
        if let value {
            storage.set(value, forKey: key)
        } else {
            storage.removeObject(forKey: key)
        }

        switch (storage.object(forKey: key), value) {
        case (nil, nil):
            return true
        case let (stored as NSObject, expected as NSObject):
            return stored.isEqual(expected)
        default:
            return false
        }
    }

    private static func loadDays(
        storage: PluginStorage,
        decoder: JSONDecoder
    ) -> (days: [String: KeyStatsDailyStats], error: String?) {
        guard let rawValue = storage.object(forKey: StorageKey.days) else {
            return ([:], nil)
        }
        guard let data = rawValue as? Data else {
            let message = "Stored key statistics have an invalid format."
            KeyStatsLog.store.error("\(message, privacy: .public)")
            return ([:], message)
        }

        do {
            return (try decoder.decode([String: KeyStatsDailyStats].self, from: data), nil)
        } catch {
            KeyStatsLog.store.error(
                "Failed to load key stats: \(error.localizedDescription, privacy: .public)"
            )
            return ([:], error.localizedDescription)
        }
    }

    /// Removes days that fall outside the retained calendar window.
    ///
    /// Retention is based on the current calendar date rather than on record
    /// count, so stale entries disappear even when the user stops typing.
    @discardableResult
    private func pruneExpiredDays() -> Bool {
        guard loadError == nil else {
            return false
        }

        let candidate = prunedDays(days)
        guard candidate.count != days.count else {
            return false
        }

        days = candidate
        hasPendingChanges = true
        return true
    }

    private func prunedDays(
        _ days: [String: KeyStatsDailyStats]
    ) -> [String: KeyStatsDailyStats] {
        let cutoff = pruningCutoffKey()
        return days.filter { $0.key >= cutoff }
    }

    private func pruningCutoffKey() -> String {
        let today = dateProvider()
        let cutoffDate = calendar.date(
            byAdding: .day,
            value: -(Persistence.retainedDayCount - 1),
            to: today
        ) ?? today
        return dateKey(for: cutoffDate)
    }
}
