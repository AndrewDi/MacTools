import Foundation
import SwiftUI
import IOKit.ps
import MacToolsPluginKit

/// Observable view model that manages power status data collection.
@MainActor
final class PowerStatusViewModel: ObservableObject {
    @Published private(set) var snapshot: PowerStatusSnapshot = .empty
    @Published private(set) var isPanelVisible: Bool = false
    @Published private(set) var sensorSnapshot: PowerStatusSensorSnapshot = .empty
    @Published private(set) var isSensorsExpanded: Bool = false

    var onSnapshotChange: (() -> Void)?

    private nonisolated(unsafe) var timer: Timer?
    private nonisolated(unsafe) var powerSourceNotifier: CFRunLoopSource?
    private nonisolated(unsafe) var iopsRetainedContext: UnsafeMutableRawPointer?
    private let updateInterval: TimeInterval = 2.0

    /// ~60 s effective window at 2 s sampling, matching PowerTop's estimator
    /// so the locally computed remaining time does not jump between samples.
    private static let emaAlpha = 0.065
    private var dischargeEMA: Double?

    private let energyMonitor = PowerStatusAppEnergyMonitor()
    private let sensorMonitor = PowerStatusSensorMonitor()
    private nonisolated(unsafe) var sensorTask: Task<Void, Never>?
    private var sensorGeneration = 0

    // MARK: - Sensor section

    /// Expands or collapses the component temperature and power table. Sampling
    /// only runs while the section is open; collapsing drops the readings so a
    /// later expansion cannot show stale values.
    func setSensorsExpanded(_ expanded: Bool) {
        guard expanded != isSensorsExpanded else { return }
        isSensorsExpanded = expanded
        sensorGeneration += 1
        sensorTask?.cancel()
        sensorTask = nil

        if expanded {
            sampleSensors()
        } else {
            sensorSnapshot = .empty
        }
        onSnapshotChange?()
    }

    private func updateSensorsIfNeeded() {
        guard isSensorsExpanded else { return }
        sampleSensors()
    }

    private func sampleSensors() {
        guard isSensorsExpanded, sensorTask == nil else { return }

        let generation = sensorGeneration
        let batteryTemperature = snapshot.batteryTemperatureC
        let batteryPower = batteryPowerForSensors
        sensorTask = Task { [weak self] in
            guard let self else { return }
            let readings = await self.sensorMonitor.sample(
                batteryTemperatureC: batteryTemperature,
                batteryPowerW: batteryPower
            )
            guard self.sensorGeneration == generation else { return }
            self.sensorSnapshot = readings
            self.sensorTask = nil
        }
    }

    private var batteryPowerForSensors: Double? {
        if snapshot.batteryChargeRateW > 0 {
            return snapshot.batteryChargeRateW
        }
        if snapshot.batteryDischargeRateW > 0 {
            return snapshot.batteryDischargeRateW
        }
        return nil
    }

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
        energyMonitor.reset()
        updateData()
        scheduleTimer()
        setupPowerSourceNotification()
    }

    private func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        sensorGeneration += 1
        sensorTask?.cancel()
        sensorTask = nil
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
        var newSnapshot = PowerStatusSampler.readSnapshot()
        newSnapshot.smoothedDischargePowerW = updateSmoothedDischargePower(from: newSnapshot)
        if newSnapshot.isDataAvailable {
            newSnapshot.topEnergyApps = energyMonitor.sample(now: newSnapshot.timestamp)
        }
        if newSnapshot != snapshot {
            snapshot = newSnapshot
            onSnapshotChange?()
        }
        updateSensorsIfNeeded()
    }

    /// Smooths instantaneous discharge power for time estimates; resets when
    /// the machine stops running on battery so stale values are not reused.
    private func updateSmoothedDischargePower(from data: PowerStatusSnapshot) -> Double? {
        switch data.flowState {
        case .discharging, .supplementalDischarge:
            break
        default:
            dischargeEMA = nil
            return nil
        }

        let instant: Double
        if case .supplementalDischarge = data.flowState {
            instant = data.batteryDischargeRateW
        } else {
            // Only a measured system draw can raise the estimate; an
            // unavailable one leaves the pack rate to speak for itself.
            instant = max(data.systemPowerW ?? 0, data.batteryDischargeRateW)
        }
        guard instant >= 0.2 else { return dischargeEMA }

        if let previous = dischargeEMA {
            dischargeEMA = previous + Self.emaAlpha * (instant - previous)
        } else {
            dischargeEMA = instant
        }
        return dischargeEMA
    }

    deinit {
        timer?.invalidate()
        sensorTask?.cancel()
        if let notifier = powerSourceNotifier {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), notifier, .commonModes)
        }
        if let ctx = iopsRetainedContext {
            Unmanaged<PowerStatusViewModel>.fromOpaque(ctx).release()
        }
    }
}
