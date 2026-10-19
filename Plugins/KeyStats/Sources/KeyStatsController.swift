import AppKit
import CoreGraphics
import Foundation
import MacToolsPluginKit

final class KeyStatsTrackpadSessionDetector: @unchecked Sendable {
    private let lock = NSLock()
    private var activeDeviceIDs: Set<UInt64> = []

    /// Returns true only when a device transitions from no contacts to at least one contact.
    func observe(_ frame: TrackpadSensorFrame) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if frame.contacts.isEmpty {
            activeDeviceIDs.remove(frame.deviceID)
            return false
        }

        return activeDeviceIDs.insert(frame.deviceID).inserted
    }

    func reset() {
        lock.lock()
        activeDeviceIDs.removeAll()
        lock.unlock()
    }
}

@MainActor
final class KeyStatsController: ObservableObject {
    static let pluginID = KeyStatsConstants.pluginID

    private enum StorageKey {
        static let isTrackingEnabled = "key-stats.tracking.enabled"
    }

    @Published private(set) var isTrackingEnabled: Bool

    let localization: PluginLocalization
    let store: KeyStatsStore

    var onStateChange: (() -> Void)?
    var onStatisticsChange: (() -> Void)?

    private let storage: PluginStorage
    private let monitor: any KeyStatsInputMonitoring
    private let notificationDelay: Duration
    private let trackpadSessionDetector = KeyStatsTrackpadSessionDetector()

    private var trackpadService: (any TrackpadInputService)?
    private var trackpadSubscriptionID: UUID?
    private var isActivated = false
    private var dayChangeObserver: NSObjectProtocol?
    private var midnightTimer: Timer?
    private var statisticsNotificationTask: Task<Void, Never>?

    init(
        context: PluginRuntimeContext,
        monitor: (any KeyStatsInputMonitoring)? = nil,
        store: KeyStatsStore? = nil,
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        notificationDelay: Duration = .milliseconds(650)
    ) {
        let resolvedStore = store ?? KeyStatsStore(storage: context.storage)
        let resolvedMonitor = monitor ?? KeyStatsInputMonitor()

        storage = context.storage
        self.localization = localization
        self.store = resolvedStore
        self.monitor = resolvedMonitor
        self.notificationDelay = notificationDelay
        isTrackingEnabled = context.storage.object(forKey: StorageKey.isTrackingEnabled) as? Bool ?? true

        self.monitor.onEvent = { [weak self] event in
            guard let self else {
                return
            }
            self.store.record(event)
            self.scheduleStatisticsNotification()
        }
    }

    @MainActor deinit {
        statisticsNotificationTask?.cancel()
        midnightTimer?.invalidate()
        if let dayChangeObserver {
            NotificationCenter.default.removeObserver(dayChangeObserver)
        }
    }

    var todayStats: KeyStatsDailyStats {
        store.today
    }

    var recentDays: [KeyStatsDailyStats] {
        store.recentDays(count: store.retainedDayCount)
    }

    var monitorStatus: KeyStatsInputMonitorStatus {
        monitor.status
    }

    var isTrackpadAvailable: Bool {
        trackpadService != nil
    }

    var panelSubtitle: String {
        if !isTrackingEnabled {
            return localization.string("status.paused", defaultValue: "已暂停统计")
        }
        if monitor.status == .inputMonitoringDenied {
            return localization.string("status.permission", defaultValue: "需要输入监控授权")
        }
        if monitor.status == .idle {
            return localization.string("status.idle", defaultValue: "尚未开始统计")
        }

        return localization.format(
            "panel.subtitle.running",
            defaultValue: "今日 %@ 次按键 · %@ 次触控板",
            KeyStatsFormatting.compactCount(todayStats.totalKeyPresses),
            KeyStatsFormatting.compactCount(todayStats.trackpadUses)
        )
    }

    var componentSubtitle: String {
        if !isTrackingEnabled {
            return localization.string("status.paused", defaultValue: "已暂停统计")
        }
        if monitor.status == .inputMonitoringDenied {
            return localization.string("status.permission", defaultValue: "需要输入监控授权")
        }

        return localization.format(
            "status.todayKeyPresses",
            defaultValue: "今日 %@ 次按键",
            KeyStatsFormatting.compactCount(todayStats.totalKeyPresses)
        )
    }

    var inputMonitoringFootnote: String? {
        guard monitor.status == .inputMonitoringDenied else {
            return nil
        }
        return localization.string(
            "permission.inputMonitoring.footnote",
            defaultValue: "请在系统设置中允许 MacTools 进行输入监控；若授权后仍无法统计，请重新启动 MacTools。"
        )
    }

    var trackpadFootnote: String? {
        guard !isTrackpadAvailable else {
            return nil
        }
        return localization.string(
            "status.trackpadUnavailable",
            defaultValue: "触控板数据不可用，按键统计仍会继续。"
        )
    }

    func activate() {
        isActivated = true
        observeDayChanges()
        scheduleMidnightTimer()

        if isTrackingEnabled {
            startRuntime()
        }
    }

    func deactivate() {
        isActivated = false
        stopRuntime()
        stopObservingDayChanges()
        statisticsNotificationTask?.cancel()
        statisticsNotificationTask = nil
        store.flushPendingChanges()
    }

    func refresh() {
        store.flushPendingChanges()

        if isTrackingEnabled {
            if monitor.status != .running, CGPreflightListenEventAccess() {
                monitor.start()
            }
            startTrackpadSubscriptionIfNeeded()
        }

        notifyChange()
    }

    @discardableResult
    func setTrackingEnabled(_ enabled: Bool) -> KeyStatsPersistenceMutationResult {
        let previousRawValue = storage.object(forKey: StorageKey.isTrackingEnabled)
        guard previousRawValue == nil || previousRawValue is Bool else {
            return .recoveryRequired
        }
        if let previous = previousRawValue as? Bool, previous == enabled {
            return .committed
        }

        storage.set(enabled, forKey: StorageKey.isTrackingEnabled)
        guard storage.object(forKey: StorageKey.isTrackingEnabled) as? Bool == enabled else {
            let restored = restoreTrackingValue(previousRawValue)
            return .rejected(rollbackSucceeded: restored)
        }

        isTrackingEnabled = enabled
        if enabled {
            startRuntime()
        } else {
            stopRuntime()
            store.flushPendingChanges()
        }
        notifyChange()
        return .committed
    }

    @discardableResult
    func resetToday() -> KeyStatsPersistenceMutationResult {
        let result = store.resetToday()
        if result == .committed {
            notifyChange()
        }
        return result
    }

    func setTrackpadInputService(_ service: any TrackpadInputService) {
        trackpadService = service
        trackpadSessionDetector.reset()
        if isActivated, isTrackingEnabled {
            startTrackpadSubscriptionIfNeeded()
        }
        notifyChange()
    }

    func trackpadInputPauseDidChange(_ isPaused: Bool) {
        trackpadSessionDetector.reset()
    }

    func openInputMonitoringSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func startRuntime() {
        monitor.start()
        startTrackpadSubscriptionIfNeeded()
    }

    private func stopRuntime() {
        monitor.stop()
        stopTrackpadSubscription()
        trackpadSessionDetector.reset()
    }

    private func startTrackpadSubscriptionIfNeeded() {
        guard trackpadSubscriptionID == nil, let trackpadService else {
            return
        }

        let detector = trackpadSessionDetector
        trackpadSubscriptionID = trackpadService.subscribe(purpose: .gestures) { [weak self] event in
            guard case let .frame(frame) = event, detector.observe(frame) else {
                return
            }

            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                self.store.recordTrackpadUse()
                self.scheduleStatisticsNotification()
            }
        }
    }

    private func stopTrackpadSubscription() {
        if let trackpadSubscriptionID, let trackpadService {
            trackpadService.unsubscribe(trackpadSubscriptionID)
        }
        trackpadSubscriptionID = nil
    }

    private func observeDayChanges() {
        guard dayChangeObserver == nil else {
            return
        }

        dayChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleDayChanged()
            }
        }
    }

    private func stopObservingDayChanges() {
        if let dayChangeObserver {
            NotificationCenter.default.removeObserver(dayChangeObserver)
        }
        dayChangeObserver = nil
        midnightTimer?.invalidate()
        midnightTimer = nil
    }

    private func scheduleMidnightTimer() {
        midnightTimer?.invalidate()

        let calendar = Calendar.autoupdatingCurrent
        let startOfToday = calendar.startOfDay(for: Date())
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: startOfToday) else {
            midnightTimer = nil
            return
        }

        let timer = Timer(fire: nextDay, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleDayChanged()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        midnightTimer = timer
    }

    private func handleDayChanged() {
        store.flushPendingChanges()
        scheduleMidnightTimer()
        notifyChange()
    }

    private func scheduleStatisticsNotification() {
        guard statisticsNotificationTask == nil else {
            return
        }

        statisticsNotificationTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            do {
                try await Task.sleep(for: self.notificationDelay)
            } catch {
                return
            }

            guard !Task.isCancelled else {
                return
            }

            self.statisticsNotificationTask = nil
            self.objectWillChange.send()
            self.onStatisticsChange?()
        }
    }

    private func notifyChange() {
        statisticsNotificationTask?.cancel()
        statisticsNotificationTask = nil
        objectWillChange.send()
        onStateChange?()
    }

    private func restoreTrackingValue(_ value: Any?) -> Bool {
        if let value {
            storage.set(value, forKey: StorageKey.isTrackingEnabled)
        } else {
            storage.removeObject(forKey: StorageKey.isTrackingEnabled)
        }

        switch (storage.object(forKey: StorageKey.isTrackingEnabled), value) {
        case (nil, nil):
            return true
        case let (stored as NSObject, expected as NSObject):
            return stored.isEqual(expected)
        default:
            return false
        }
    }
}
