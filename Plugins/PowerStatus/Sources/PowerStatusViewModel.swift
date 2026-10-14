import Foundation
import SwiftUI
import MacToolsPluginKit

/// Observable view model that manages power status data collection.
@MainActor
final class PowerStatusViewModel: ObservableObject {
    @Published private(set) var snapshot: PowerStatusSnapshot = .empty
    @Published private(set) var isPanelVisible: Bool = false

    var onSnapshotChange: (() -> Void)?

    private var timer: Timer?
    private var powerSourceNotifier: CFRunLoopSource?
    private var iopsRetainedContext: UnsafeMutableRawPointer?
    private let updateInterval: TimeInterval = 2.0

    // MARK: - Panel visibility

    func setPanelVisible(_ visible: Bool) {
        guard visible != isPanelVisible else { return }
        isPanelVisible = visible
        if visible {
            startMonitoring()
        } else {
            stopMonitoring()
        }
    }

    // MARK: - Manual refresh

    func refresh() {
        updateData()
    }

    // MARK: - Monitoring control

    private func startMonitoring() {
        guard timer == nil else { return }
        updateData()
        scheduleTimer()
        setupPowerSourceNotification()
    }

    private func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        if let notifier = powerSourceNotifier {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), notifier, .commonModes)
            powerSourceNotifier = nil
        }
        if let ctx = iopsRetainedContext {
            Unmanaged<PowerStatusViewModel>.fromOpaque(ctx).release()
            iopsRetainedContext = nil
        }
    }

    // MARK: - Timer

    private func scheduleTimer() {
        timer?.invalidate()
        let newTimer = Timer(timeInterval: updateInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateData()
            }
        }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    // MARK: - Power source notification

    private func setupPowerSourceNotification() {
        let retained = Unmanaged.passRetained(self)
        iopsRetainedContext = retained.toOpaque()
        let context = retained.toOpaque()

        let callback: IOPowerSourceCallbackType = { ctx in
            guard let ctx = ctx else { return }
            let vm = Unmanaged<PowerStatusViewModel>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async {
                vm.handlePowerSourceEvent()
            }
        }
        powerSourceNotifier = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue()
        if let notifier = powerSourceNotifier {
            CFRunLoopAddSource(CFRunLoopGetMain(), notifier, .commonModes)
        }
    }

    private func handlePowerSourceEvent() {
        updateData()
    }

    // MARK: - Data update

    private func updateData() {
        let newSnapshot = PowerStatusSampler.readSnapshot()
        guard newSnapshot != snapshot else { return }
        snapshot = newSnapshot
        onSnapshotChange?()
    }

    deinit {
        timer?.invalidate()
        if let notifier = powerSourceNotifier {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), notifier, .commonModes)
        }
        if let ctx = iopsRetainedContext {
            Unmanaged<PowerStatusViewModel>.fromOpaque(ctx).release()
        }
    }
}
