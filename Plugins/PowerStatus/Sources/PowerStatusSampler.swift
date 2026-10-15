import Foundation
import IOKit

/// Reads battery and power telemetry from IOKit.
///
/// Adapted from PowerTop's PowerMonitor, simplified for plugin use.
/// All methods are `nonisolated` because IOKit calls are thread-safe.
enum PowerStatusSampler {

    // MARK: - Public API

    /// Reads the current power/battery snapshot from IOKit.
    /// Returns `.empty` with `isDataAvailable = false` when IOKit data is unavailable.
    static func readSnapshot() -> PowerStatusSnapshot {
        guard let props = getIOServiceProperties(className: "AppleSmartBattery") else {
            return .empty
        }

        let isOnAC = extractBool(from: props, key: "ExternalConnected") ?? false
        let isCharging = extractBool(from: props, key: "IsCharging") ?? false
        let fullyCharged = extractBool(from: props, key: "FullyCharged") ?? false
        let currentCapacity = extractInt(from: props, key: "CurrentCapacity") ?? 0
        let maxCapacity = extractInt(from: props, key: "MaxCapacity") ?? 100
        let batteryPercent = maxCapacity > 0 ? (currentCapacity * 100 / maxCapacity) : 0
        let voltage = extractInt(from: props, key: "Voltage")
        let amperage = extractInt(from: props, key: "Amperage")
        let cycleCount = extractInt(from: props, key: "CycleCount")

        // Battery health. On Apple Silicon the compensated capacity that System
        // Settings reports lives on the pack node rather than the battery node.
        let capacitySnapshot = readBatteryCapacitySnapshot(
            from: props,
            packProps: getIOServiceProperties(className: "AppleSmartBatteryPack")
        )
        let batteryHealthPercent = capacitySnapshot.healthPercent
        let designCapacity = capacitySnapshot.designCapacityMAH
        let fullChargeCapacity = capacitySnapshot.fullChargeCapacityMAH
        let temperature = capacitySnapshot.temperatureCentidegrees

        // Adapter details
        let adapterDetails = extractDict(from: props, key: "AdapterDetails")
        let acAdapterWattage = adapterDetails.flatMap { extractInt(from: $0, key: "Watts") } ?? 0

        // Charger data
        let chargerData = extractDict(from: props, key: "ChargerData")
        let chargingVoltage = chargerData.flatMap { extractInt(from: $0, key: "ChargingVoltage") }
        let chargingCurrent = chargerData.flatMap { extractInt(from: $0, key: "ChargingCurrent") }

        // Time estimates
        let batteryData = extractDict(from: props, key: "BatteryData")
        let avgTimeToEmpty = batteryData.flatMap { extractInt(from: $0, key: "AvgTimeToEmpty") }
            ?? extractInt(from: props, key: "AvgTimeToEmpty")
        let avgTimeToFull = batteryData.flatMap { extractInt(from: $0, key: "AvgTimeToFull") }
            ?? extractInt(from: props, key: "AvgTimeToFull")
        let remainingCapacity = batteryData.flatMap { extractInt(from: $0, key: "RemainingCapacity") }
            ?? extractInt(from: props, key: "RemainingCapacity")

        // Power telemetry
        let telemetry = extractDict(from: props, key: "PowerTelemetryData")

        let (systemPowerW, batteryPowerW, acInputW, flowState) = computePowerMetrics(
            telemetry: telemetry,
            isOnAC: isOnAC,
            isCharging: isCharging,
            amperage: amperage,
            voltage: voltage
        )

        return PowerStatusSnapshot(
            timestamp: Date(),
            systemPowerW: systemPowerW,
            batteryPowerW: batteryPowerW,
            acInputW: acInputW,
            acAdapterWattage: acAdapterWattage,
            batteryPercent: batteryPercent,
            isOnAC: isOnAC,
            isCharging: isCharging,
            fullyCharged: fullyCharged,
            batteryVoltageMV: voltage,
            batteryAmperageMA: amperage,
            batteryTemperatureC: temperature.map { Double($0) / 100.0 },
            cycleCount: cycleCount,
            batteryHealthPercent: batteryHealthPercent,
            designCapacityMAH: designCapacity,
            fullChargeCapacityMAH: fullChargeCapacity,
            chargingVoltageMV: chargingVoltage,
            chargingCurrentMA: chargingCurrent,
            avgTimeToEmptyMinutes: avgTimeToEmpty,
            avgTimeToFullMinutes: avgTimeToFull,
            remainingCapacityMAH: remainingCapacity,
            flowState: flowState,
            isDataAvailable: true
        )
    }

    /// Reads only the AC connection status (lightweight, for power source notifications).
    static func readExternalConnected() -> Bool? {
        guard let props = getIOServiceProperties(className: "AppleSmartBattery") else { return nil }
        return extractBool(from: props, key: "ExternalConnected")
    }

    // MARK: - Power computation

    private static func computePowerMetrics(
        telemetry: [String: Any]?,
        isOnAC: Bool,
        isCharging: Bool,
        amperage: Int?,
        voltage: Int?
    ) -> (systemPowerW: Double, batteryPowerW: Double, acInputW: Double, flowState: PowerFlowState) {

        let amperagePowerW: Double? = {
            guard let a = amperage, let v = voltage, a != 0, v > 0 else { return nil }
            return Double(a) * Double(v) / 1_000_000.0
        }()

        if let telem = telemetry {
            let systemLoad = extractInt(from: telem, key: "SystemLoad") ?? 0
            let systemPowerIn = extractInt(from: telem, key: "SystemPowerIn") ?? 0
            let batteryPower = extractInt(from: telem, key: "BatteryPower") ?? 0

            let reportedACInputW = Double(systemPowerIn) / 1000.0
            let acInputW = isOnAC ? reportedACInputW : 0
            let systemLoadW = Double(systemLoad) / 1000.0
            let batteryPowerFromTelemetry = Double(batteryPower) / 1000.0

            let flow = resolveBatteryFlow(
                isOnAC: isOnAC,
                isChargingFlag: isCharging,
                acInputW: acInputW,
                systemLoadW: systemLoadW,
                amperagePowerW: amperagePowerW,
                batteryPowerFromTelemetry: batteryPowerFromTelemetry
            )

            let (systemPowerW, batteryPowerW) = computePowerFromFlow(
                flow: flow,
                isOnAC: isOnAC,
                acInputW: acInputW,
                systemLoadW: systemLoadW,
                batteryPowerFromTelemetry: batteryPowerFromTelemetry
            )

            return (systemPowerW, batteryPowerW, acInputW, flow)
        }

        // Fallback: calculate from signed Amperage x Voltage
        var systemPowerW: Double = 0
        var batteryPowerW: Double = 0
        if let signedPower = amperagePowerW {
            batteryPowerW = signedPower
            if !isOnAC {
                systemPowerW = abs(signedPower)
            } else if signedPower < 0 {
                systemPowerW = 0
            } else {
                systemPowerW = signedPower
            }
        }

        let flow: PowerFlowState
        if batteryPowerW > 0.3 {
            flow = isOnAC ? .supplementalDischarge(rateW: batteryPowerW) : .discharging(rateW: batteryPowerW)
        } else if batteryPowerW < -0.3 {
            flow = isOnAC ? .supplementalDischarge(rateW: abs(batteryPowerW)) : .discharging(rateW: abs(batteryPowerW))
        } else if isOnAC {
            flow = .onAC
        } else {
            flow = .idle
        }

        return (systemPowerW, batteryPowerW, 0, flow)
    }

    /// Pure classification of the current power path. Internal so the plugin
    /// tests can pin down the off-power fallback that keeps the panel from
    /// reporting "idle" while the machine is actually running on the battery.
    static func resolveBatteryFlow(
        isOnAC: Bool,
        isChargingFlag: Bool,
        acInputW: Double,
        systemLoadW: Double,
        amperagePowerW: Double?,
        batteryPowerFromTelemetry: Double
    ) -> PowerFlowState {
        let powerThreshold = 0.3

        // Energy balance on AC: input > load -> surplus charges battery.
        if isOnAC, acInputW > systemLoadW + powerThreshold {
            if let ampPower = amperagePowerW, ampPower < -powerThreshold {
                return .charging(rateW: abs(ampPower))
            }
            if batteryPowerFromTelemetry < -powerThreshold {
                return .charging(rateW: abs(batteryPowerFromTelemetry))
            }
            return .charging(rateW: acInputW - systemLoadW)
        }

        // Energy balance on AC: load > input -> battery may supplement.
        if isOnAC, systemLoadW > acInputW + powerThreshold {
            if let ampPower = amperagePowerW, ampPower > powerThreshold {
                let rate = batteryPowerFromTelemetry > powerThreshold
                    ? batteryPowerFromTelemetry
                    : ampPower
                return .supplementalDischarge(rateW: rate)
            }
            if batteryPowerFromTelemetry > powerThreshold {
                return .supplementalDischarge(rateW: batteryPowerFromTelemetry)
            }
        }

        if let ampPower = amperagePowerW {
            if ampPower > powerThreshold {
                return isOnAC
                    ? .supplementalDischarge(rateW: ampPower)
                    : .discharging(rateW: ampPower)
            }
            if isOnAC, ampPower < -powerThreshold {
                return .charging(rateW: abs(ampPower))
            }
        }

        if batteryPowerFromTelemetry > powerThreshold {
            return isOnAC
                ? .supplementalDischarge(rateW: batteryPowerFromTelemetry)
                : .discharging(rateW: batteryPowerFromTelemetry)
        }
        if batteryPowerFromTelemetry < -powerThreshold {
            return isOnAC ? .charging(rateW: abs(batteryPowerFromTelemetry)) : .discharging(rateW: abs(batteryPowerFromTelemetry))
        }

        if isOnAC {
            if isChargingFlag {
                if let ampPower = amperagePowerW, ampPower < 0 {
                    return .charging(rateW: abs(ampPower))
                }
            }
            return .onAC
        }

        // Off power the pack is the only source, so a real discharge current or
        // system load means the machine is running on battery even while
        // BatteryPower and Amperage still read zero for a moment after
        // unplugging.
        if let ampPower = amperagePowerW, abs(ampPower) > powerThreshold {
            return .discharging(rateW: abs(ampPower))
        }

        if abs(systemLoadW) > powerThreshold {
            return .discharging(rateW: abs(systemLoadW))
        }

        return .idle
    }

    private static func computePowerFromFlow(
        flow: PowerFlowState,
        isOnAC: Bool,
        acInputW: Double,
        systemLoadW: Double,
        batteryPowerFromTelemetry: Double
    ) -> (systemPowerW: Double, batteryPowerW: Double) {
        var systemPowerW: Double = 0
        var batteryPowerW: Double = 0

        switch flow {
        case .charging(let rateW):
            batteryPowerW = -rateW
            if isOnAC, acInputW > rateW {
                systemPowerW = acInputW - rateW
            } else if systemLoadW > 0 {
                systemPowerW = systemLoadW
            } else if isOnAC {
                systemPowerW = max(0, acInputW - rateW)
            }

        case .discharging(let rateW):
            batteryPowerW = rateW
            if isOnAC {
                systemPowerW = systemLoadW > 0 ? systemLoadW : acInputW + rateW
            } else if systemLoadW < 0 {
                systemPowerW = abs(systemLoadW)
            } else {
                systemPowerW = rateW
            }

        case .supplementalDischarge(let rateW):
            batteryPowerW = rateW
            if isOnAC {
                systemPowerW = systemLoadW > 0 ? systemLoadW : acInputW + rateW
            } else {
                systemPowerW = rateW
            }

        case .onAC:
            batteryPowerW = batteryPowerFromTelemetry
            if systemLoadW > 0 {
                systemPowerW = systemLoadW
            } else {
                systemPowerW = acInputW
            }

        case .idle:
            batteryPowerW = batteryPowerFromTelemetry
            if !isOnAC {
                if systemLoadW > 0 {
                    systemPowerW = systemLoadW
                } else if systemLoadW < 0 {
                    systemPowerW = abs(systemLoadW)
                } else if batteryPowerFromTelemetry > 0 {
                    systemPowerW = batteryPowerFromTelemetry
                } else if batteryPowerFromTelemetry < 0 {
                    systemPowerW = abs(batteryPowerFromTelemetry)
                }
            } else if systemLoadW > 0 {
                systemPowerW = systemLoadW
            } else {
                systemPowerW = acInputW
            }
        }

        return (systemPowerW, batteryPowerW)
    }

    // MARK: - IOKit helpers

    private static func getIOServiceProperties(className: String) -> [String: Any]? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching(className)
        )
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        let result = IORegistryEntryCreateCFProperties(
            service,
            &properties,
            kCFAllocatorDefault,
            0
        )
        guard result == KERN_SUCCESS, let props = properties?.takeRetainedValue() else {
            return nil
        }
        return props as? [String: Any]
    }

    private static func extractBool(from dict: [String: Any], key: String) -> Bool? {
        guard let value = dict[key] else { return nil }
        if let boolVal = value as? Bool { return boolVal }
        if let intVal = value as? Int { return intVal != 0 }
        if let numVal = value as? NSNumber { return numVal.boolValue }
        return nil
    }

    private static func extractInt(from dict: [String: Any], key: String) -> Int? {
        guard let value = dict[key] else { return nil }
        if let intVal = value as? Int { return intVal }
        if let numVal = value as? NSNumber { return numVal.intValue }
        if let doubleVal = value as? Double { return Int(doubleVal) }
        return nil
    }

    private static func extractString(from dict: [String: Any], key: String) -> String? {
        guard let value = dict[key] else { return nil }
        if let strVal = value as? String { return strVal }
        if let numVal = value as? NSNumber { return numVal.stringValue }
        return nil
    }

    private static func extractDict(from dict: [String: Any], key: String) -> [String: Any]? {
        guard let value = dict[key] else { return nil }
        return value as? [String: Any]
    }

    // MARK: - Battery capacity snapshot

    struct BatteryCapacitySnapshot {
        var designCapacityMAH: Int?
        var rawMaxCapacityMAH: Int?
        var fullChargeCapacityMAH: Int?
        var healthPercent: Int?
        var temperatureCentidegrees: Int?
    }

    /// Reads pack capacity telemetry. Internal so tests can pin the milliamp
    /// sources apart from the normalized percentage keys on the same node.
    ///
    /// - Parameter packProps: the sibling `AppleSmartBatteryPack` node, where
    ///   Apple Silicon reports the compensated full-charge capacity.
    static func readBatteryCapacitySnapshot(
        from props: [String: Any],
        packProps: [String: Any]? = nil
    ) -> BatteryCapacitySnapshot {
        let batteryData = extractDict(from: props, key: "BatteryData")
        let packBatteryData = packProps.flatMap { extractDict(from: $0, key: "BatteryData") }

        // Depending on the machine and macOS version these fields appear either
        // at the top level or nested under BatteryData, so read both. The pack
        // node is consulted last because the battery node owns DesignCapacity.
        func capacityValue(_ key: String) -> Int? {
            batteryData.flatMap { extractInt(from: $0, key: key) }
                ?? extractInt(from: props, key: key)
                ?? packBatteryData.flatMap { extractInt(from: $0, key: key) }
                ?? packProps.flatMap { extractInt(from: $0, key: key) }
        }

        // Top-level MaxCapacity is a normalized 0-100 percentage on modern Macs,
        // so it must never be read as a milliamp capacity.
        let designCapacity = capacityValue("DesignCapacity")
        let compensatedCapacity = capacityValue("FccComp1")
        let rawMaxCapacity = capacityValue("AppleRawMaxCapacity")
        let fullChargeCapacity = capacityValue("FullChargeCapacity")
        let nominalChargeCapacity = capacityValue("NominalChargeCapacity")

        // Temperature is in centidegrees
        let temperature = capacityValue("Temperature")

        // FccComp1 is the gas gauge's temperature- and age-compensated reading,
        // the same figure macOS shows as System Settings' "Maximum Capacity".
        // The remaining keys are raw milliamp fallbacks for machines without it.
        let displayedCapacity = compensatedCapacity
            ?? rawMaxCapacity
            ?? fullChargeCapacity
            ?? nominalChargeCapacity

        // Rounded up, not truncated or rounded to nearest: System Settings shows
        // 89% for 88.49%, where both of those report 88%. Capped because a fresh
        // pack can report slightly more than its design capacity.
        var healthPercent: Int?
        if let design = designCapacity, design > 0,
           let measured = displayedCapacity, measured > 0 {
            let ratio = Double(measured) * 100.0 / Double(design)
            healthPercent = min(100, Int(ratio.rounded(.up)))
        }

        return BatteryCapacitySnapshot(
            designCapacityMAH: designCapacity,
            rawMaxCapacityMAH: rawMaxCapacity,
            fullChargeCapacityMAH: displayedCapacity,
            healthPercent: healthPercent,
            temperatureCentidegrees: temperature
        )
    }
}
