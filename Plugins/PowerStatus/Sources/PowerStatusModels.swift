import Foundation
import MacToolsPluginKit

/// Power flow state describing the current energy direction.
enum PowerFlowState: Equatable {
    case onAC
    case charging(rateW: Double)
    case discharging(rateW: Double)
    case supplementalDischarge(rateW: Double)
    case idle
}

/// Formats power readings for display. A reading that could not be established
/// is printed as an em dash: a measured zero and an unavailable value are not
/// interchangeable, and showing `0 W` for the latter contradicts the readings
/// drawn beside it.
enum PowerStatusValueText {
    static let unavailable = "—"

    /// One decimal place, for metric rows and diagram nodes.
    static func watts(_ watts: Double?) -> String {
        guard let watts else { return unavailable }
        return String(format: "%.1f W", max(0, watts))
    }

    /// Whole watts, for the compact panel subtitle.
    static func wholeWatts(_ watts: Double?) -> String {
        guard let watts else { return unavailable }
        return String(format: "%.0fW", max(0, watts))
    }
}

/// A snapshot of power and battery telemetry collected from IOKit.
struct PowerStatusSnapshot: Equatable {
    let timestamp: Date

    // Core power metrics (watts). A `nil` reading was not established, which is
    // deliberately distinct from a measured `0`.
    let systemPowerW: Double?
    let acInputW: Double?
    let acAdapterWattage: Int

    // Battery basics
    let batteryPercent: Int
    let isOnAC: Bool
    let isCharging: Bool
    let fullyCharged: Bool
    let batteryVoltageMV: Int?
    let batteryAmperageMA: Int?
    let batteryTemperatureC: Double?
    let cycleCount: Int?

    // Battery health
    let batteryHealthPercent: Int?
    let designCapacityMAH: Int?
    let fullChargeCapacityMAH: Int?

    // Charging details
    let chargingVoltageMV: Int?
    let chargingCurrentMA: Int?

    // Time estimates
    let avgTimeToEmptyMinutes: Int?
    let avgTimeToFullMinutes: Int?
    let remainingCapacityMAH: Int?

    // Derived
    let flowState: PowerFlowState
    let isDataAvailable: Bool

    /// EMA-smoothed discharge power set by the view model for stable time estimates.
    var smoothedDischargePowerW: Double?

    static let empty = PowerStatusSnapshot(
        timestamp: Date(),
        systemPowerW: nil,
        acInputW: nil,
        acAdapterWattage: 0,
        batteryPercent: 0,
        isOnAC: false,
        isCharging: false,
        fullyCharged: false,
        batteryVoltageMV: nil,
        batteryAmperageMA: nil,
        batteryTemperatureC: nil,
        cycleCount: nil,
        batteryHealthPercent: nil,
        designCapacityMAH: nil,
        fullChargeCapacityMAH: nil,
        chargingVoltageMV: nil,
        chargingCurrentMA: nil,
        avgTimeToEmptyMinutes: nil,
        avgTimeToFullMinutes: nil,
        remainingCapacityMAH: nil,
        flowState: .idle,
        isDataAvailable: false,
        smoothedDischargePowerW: nil
    )

    // MARK: - Computed properties

    var effectiveIsOnAC: Bool {
        isOnAC || isCharging
    }

    /// Total power the adapter supplies, or `nil` when its share is not
    /// established. The adapter is the AC source, so the reading is unavailable
    /// whenever the machine is off power.
    var effectiveACOutputW: Double? {
        guard effectiveIsOnAC else { return nil }
        if let acInputW, acInputW > 0 { return acInputW }
        if case let .charging(rate) = flowState {
            // Without AC-input telemetry only the pack's intake is measured,
            // which does not establish the adapter's total output.
            return systemPowerW.map { $0 + rate }
        }
        return systemPowerW
    }

    var batteryChargeRateW: Double {
        guard case let .charging(rate) = flowState else { return 0 }
        return rate
    }

    var batteryDischargeRateW: Double {
        switch flowState {
        case .discharging(let rate): return rate
        case .supplementalDischarge(let rate): return rate
        default: return 0
        }
    }

    /// Wattage shown in the header, or `nil` when nothing establishes the
    /// current draw.
    var headerPowerW: Double? {
        switch flowState {
        case .onAC, .idle:
            return effectiveIsOnAC ? effectiveACOutputW : systemPowerW
        case .charging:
            return effectiveACOutputW
        case .discharging, .supplementalDischarge:
            return systemPowerW
        }
    }

    var estimatedTimeRemainingMinutes: Int? {
        switch flowState {
        case .charging:
            return validAvgTimeToFullMinutes
        case .discharging, .supplementalDischarge:
            return validAvgTimeToEmptyMinutes ?? computedTimeToEmptyMinutes
        default:
            return nil
        }
    }

    /// Whether the displayed remaining time was computed locally because
    /// macOS no longer reports a valid AvgTimeToEmpty.
    var estimatedTimeIsComputed: Bool {
        guard estimatedTimeRemainingMinutes != nil else { return false }
        switch flowState {
        case .discharging, .supplementalDischarge:
            return validAvgTimeToEmptyMinutes == nil
        default:
            return false
        }
    }

    /// Remaining stored energy (Wh) from coulomb count × pack voltage,
    /// falling back to full-charge capacity scaled by the state of charge.
    var remainingEnergyWh: Double? {
        if let remaining = remainingCapacityMAH, let voltage = batteryVoltageMV,
           remaining > 0, voltage > 0 {
            return Double(remaining) * Double(voltage) / 1_000_000.0
        }
        guard let capacity = fullChargeCapacityMAH, capacity > 0,
              let voltage = batteryVoltageMV, voltage > 0,
              batteryPercent > 0 else { return nil }
        return Double(capacity) * Double(batteryPercent) / 100.0 * Double(voltage) / 1_000_000.0
    }

    /// Battery-only discharge power used for the local time estimate.
    private var dischargePowerForEstimateW: Double? {
        if let smoothed = smoothedDischargePowerW, smoothed >= 0.2 { return smoothed }
        let rate = batteryDischargeRateW
        if rate >= 0.2 { return rate }
        if case .discharging = flowState, let systemPower = systemPowerW, systemPower >= 0.2 {
            return systemPower
        }
        return nil
    }

    /// Local fallback when macOS does not report AvgTimeToEmpty:
    /// remaining energy divided by smoothed discharge power.
    private var computedTimeToEmptyMinutes: Int? {
        guard isBatteryDischargingFlow,
              let energyWh = remainingEnergyWh,
              let powerW = dischargePowerForEstimateW else { return nil }
        return Self.minutesFromEnergy(energyWh: energyWh, powerW: powerW)
    }

    private var isBatteryDischargingFlow: Bool {
        switch flowState {
        case .discharging, .supplementalDischarge: return true
        default: return false
        }
    }

    var estimatedTimeRemainingText: String? {
        guard let minutes = estimatedTimeRemainingMinutes else { return nil }
        return Self.formatDuration(minutes: minutes)
    }

    /// Catalog key for the remaining-time tile, or `nil` when no time applies.
    /// The localized text is resolved by the caller, which owns the catalog.
    var estimatedTimeLabelKey: String? {
        switch flowState {
        case .charging:
            return "metric.timeToFull"
        case .discharging, .supplementalDischarge:
            return estimatedTimeIsComputed ? "metric.timeEstimate.computed" : "metric.timeEstimate.remaining"
        default:
            return nil
        }
    }

    /// Catalog key describing where the machine is drawing power from.
    var powerSourceLocalizationKey: String {
        switch flowState {
        case .onAC: return "flow.source.ac"
        case .charging: return "flow.source.charging"
        case .discharging: return "flow.source.battery"
        case .supplementalDischarge: return "flow.source.supplemental"
        case .idle: return "flow.source.idle"
        }
    }

    var temperatureText: String? {
        guard let temp = batteryTemperatureC else { return nil }
        return String(format: "%.1f°C", temp)
    }

    var healthText: String? {
        guard let health = batteryHealthPercent else { return nil }
        return "\(health)%"
    }

    /// Whether the pack is full while still on power, so the charging-time
    /// slot can show "fully charged" instead of an empty estimate.
    var showFullyCharged: Bool {
        guard fullyCharged || batteryPercent >= 100 else { return false }
        switch flowState {
        case .discharging, .supplementalDischarge:
            return false
        default:
            return true
        }
    }

    /// Whether any battery voltage or current value is reported.
    var hasVoltageCurrentDetail: Bool {
        batteryVoltageMV != nil || batteryAmperageMA != nil
            || chargingVoltageMV != nil || chargingCurrentMA != nil
    }

    // MARK: - Localized labels

    /// Localized power-source caption, falling back to Simplified Chinese when
    /// a catalog is missing the entry.
    func powerSourceText(_ localization: PluginLocalization) -> String {
        localization.string(powerSourceLocalizationKey, defaultValue: "交流供电")
    }

    /// Localized label for the remaining-time tile, or `nil` when no time
    /// estimate applies to the current flow.
    func estimatedTimeLabelText(_ localization: PluginLocalization) -> String? {
        guard let key = estimatedTimeLabelKey else { return nil }
        return localization.string(key, defaultValue: "预计剩余时间")
    }

    // MARK: - Private helpers

    private var validAvgTimeToEmptyMinutes: Int? {
        guard let t = avgTimeToEmptyMinutes, t > 0, t < 10000 else { return nil }
        return t
    }

    private var validAvgTimeToFullMinutes: Int? {
        guard let t = avgTimeToFullMinutes, t > 0, t < 10000 else { return nil }
        return t
    }

    private static func formatDuration(minutes: Int) -> String {
        let hours = minutes / 60
        let mins = minutes % 60
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(mins)m"
    }

    private static func minutesFromEnergy(energyWh: Double, powerW: Double) -> Int? {
        guard powerW >= 0.2, energyWh > 0 else { return nil }
        return cappedMinutes(Int((energyWh / powerW) * 60.0))
    }

    /// Keeps estimates within a sane range instead of showing absurd values
    /// when power momentarily drops near zero.
    private static func cappedMinutes(_ minutes: Int) -> Int {
        min(max(0, minutes), 99 * 60 + 59)
    }
}
