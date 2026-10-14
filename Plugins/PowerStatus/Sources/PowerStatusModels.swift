import Foundation

/// Power flow state describing the current energy direction.
enum PowerFlowState: Equatable {
    case onAC
    case charging(rateW: Double)
    case discharging(rateW: Double)
    case supplementalDischarge(rateW: Double)
    case idle

    var description: String {
        switch self {
        case .onAC: return "交流供电"
        case .charging: return "充电中"
        case .discharging: return "电池放电"
        case .supplementalDischarge: return "电池辅助供电"
        case .idle: return "空闲"
        }
    }
}

/// A snapshot of power and battery telemetry collected from IOKit.
struct PowerStatusSnapshot: Equatable {
    let timestamp: Date

    // Core power metrics (watts)
    let systemPowerW: Double
    let batteryPowerW: Double
    let acInputW: Double
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

    // Derived
    let flowState: PowerFlowState
    let isDataAvailable: Bool

    static let empty = PowerStatusSnapshot(
        timestamp: Date(),
        systemPowerW: 0,
        batteryPowerW: 0,
        acInputW: 0,
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
        flowState: .idle,
        isDataAvailable: false
    )

    // MARK: - Computed properties

    var effectiveIsOnAC: Bool {
        isOnAC || isCharging
    }

    var effectiveACOutputW: Double {
        guard effectiveIsOnAC else { return 0 }
        if acInputW > 0 { return acInputW }
        if case let .charging(rate) = flowState { return systemPowerW + rate }
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

    var headerPowerW: Double {
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
            return validAvgTimeToEmptyMinutes
        default:
            return nil
        }
    }

    var estimatedTimeRemainingText: String? {
        guard let minutes = estimatedTimeRemainingMinutes else { return nil }
        return Self.formatDuration(minutes: minutes)
    }

    var estimatedTimeLabel: String {
        switch flowState {
        case .charging:
            return "预计充满时间"
        case .discharging, .supplementalDischarge:
            return "预计剩余时间"
        default:
            return ""
        }
    }

    var powerSourceDescription: String {
        switch flowState {
        case .onAC: return "交流供电"
        case .charging: return "交流充电中"
        case .discharging: return "电池供电"
        case .supplementalDischarge: return "交流 + 电池辅助"
        case .idle: return "空闲"
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
}
