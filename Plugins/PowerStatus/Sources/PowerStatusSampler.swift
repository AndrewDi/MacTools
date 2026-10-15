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

    /// Battery power below this many watts is measurement noise rather than a
    /// real charge or discharge.
    static let powerThreshold = 0.3

    /// Pure power-path computation. Internal so the plugin tests can pin the
    /// no-telemetry fallback, which must not report charging as a discharge.
    static func computePowerMetrics(
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

        if let telem = telemetry, !telem.isEmpty {
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

        // Fallback: classify from signed Amperage x Voltage only, using the same
        // rule as the raw-current branch in resolveBatteryFlow.
        let raw = flowFromRawCurrent(
            amperagePowerW: amperagePowerW,
            isOnAC: isOnAC,
            isChargingFlag: isCharging
        )
        // Without telemetry the battery rate is the only measured quantity. For
        // charging it must not be echoed into the system draw, because
        // `effectiveACOutputW` would add it back and report double the real AC
        // input. Every other flow keeps its rate as the system draw so the
        // header does not drop to a false 0 W while the pack feeds the machine.
        let systemPowerW: Double = {
            if case .charging = raw.flow { return 0 }
            return abs(raw.batteryPowerW)
        }()
        // AC input is unknown without telemetry, so it reads zero.
        return (systemPowerW, raw.batteryPowerW, 0, raw.flow)
    }

    /// Classifies from signed Amperage x Voltage alone. IOKit reports that
    /// current positive while the pack takes charge and negative while it
    /// feeds the machine, so the two directions stay distinguishable instead of
    /// both collapsing into discharge.
    private static func flowFromRawCurrent(
        amperagePowerW: Double?,
        isOnAC: Bool,
        isChargingFlag: Bool
    ) -> (flow: PowerFlowState, batteryPowerW: Double) {
        guard let signedPower = amperagePowerW, abs(signedPower) > powerThreshold else {
            // Amperage is missing or too small to read; the charger flag is the
            // only remaining signal, so a charging pack is not reported as idle.
            if isOnAC, isChargingFlag {
                return (.charging(rateW: 0), 0)
            }
            return (isOnAC ? .onAC : .idle, 0)
        }

        if signedPower > 0 {
            return (isOnAC ? .charging(rateW: signedPower) : .idle, signedPower)
        }
        let rateW = abs(signedPower)
        return (isOnAC ? .supplementalDischarge(rateW: rateW) : .discharging(rateW: rateW), rateW)
    }

    /// Pure classification of the current power path. Internal so the plugin
    /// tests can pin down the off-power fallback that keeps the panel from
    /// reporting "idle" while the machine is actually running on the battery.
    ///
    /// `Amperage` and the telemetry `BatteryPower` are IOKit-signed: positive
    /// while the pack takes charge, negative while it feeds the machine. They
    /// are converted to `PowerFlowState` rates here, which use the opposite,
    /// discharging-positive convention that `computePowerFromFlow` expects.
    static func resolveBatteryFlow(
        isOnAC: Bool,
        isChargingFlag: Bool,
        acInputW: Double,
        systemLoadW: Double,
        amperagePowerW: Double?,
        batteryPowerFromTelemetry: Double
    ) -> PowerFlowState {
        // Energy balance on AC: input > load -> surplus charges battery.
        if isOnAC, acInputW > systemLoadW + powerThreshold {
            if let ampPower = amperagePowerW, ampPower > powerThreshold {
                return .charging(rateW: ampPower)
            }
            if batteryPowerFromTelemetry > powerThreshold {
                return .charging(rateW: batteryPowerFromTelemetry)
            }
            return .charging(rateW: acInputW - systemLoadW)
        }

        // Energy balance on AC: load > input -> battery may supplement.
        if isOnAC, systemLoadW > acInputW + powerThreshold {
            if let ampPower = amperagePowerW, ampPower < -powerThreshold {
                let rate = batteryPowerFromTelemetry < -powerThreshold
                    ? abs(batteryPowerFromTelemetry)
                    : abs(ampPower)
                return .supplementalDischarge(rateW: rate)
            }
            if batteryPowerFromTelemetry < -powerThreshold {
                return .supplementalDischarge(rateW: abs(batteryPowerFromTelemetry))
            }
        }

        // Raw current, used directly when the energy balance above could not
        // classify: both current directions stay distinguishable here.
        let raw = flowFromRawCurrent(
            amperagePowerW: amperagePowerW,
            isOnAC: isOnAC,
            isChargingFlag: isChargingFlag
        )
        if abs(raw.batteryPowerW) > powerThreshold || isChargingFlag {
            return raw.flow
        }

        // On AC with no battery current the pack is neither charging nor
        // supplementing: the adapter is carrying the system alone. This happens
        // when the battery is full or charging is paused, so it must not fall
        // through to `.idle`, which the diagram renders as battery-powered.
        if isOnAC {
            return .onAC
        }

        // Current is missing or too small to classify; off power the pack is the
        // only source, so a real system load still means the machine is running
        // on the battery even while Amperage reads zero for a moment after
        // unplugging.
        if !isOnAC, abs(systemLoadW) > powerThreshold {
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
