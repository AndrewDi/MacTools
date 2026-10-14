import XCTest
@testable import PowerStatusPlugin

final class PowerStatusPluginTests: XCTestCase {

    func testSnapshotEmptyDefaults() {
        let snapshot = PowerStatusSnapshot.empty

        XCTAssertEqual(snapshot.batteryPercent, 0)
        XCTAssertFalse(snapshot.isOnAC)
        XCTAssertFalse(snapshot.isCharging)
        XCTAssertFalse(snapshot.isDataAvailable)
        XCTAssertEqual(snapshot.systemPowerW, 0)
        XCTAssertEqual(snapshot.flowState, .idle)
    }

    func testPowerSourceLabelKeyMatchesFlowState() {
        XCTAssertEqual(makeSnapshot(flowState: .onAC).powerSourceLocalizationKey, "flow.source.ac")
        XCTAssertEqual(
            makeSnapshot(flowState: .charging(rateW: 10)).powerSourceLocalizationKey,
            "flow.source.charging"
        )
        XCTAssertEqual(
            makeSnapshot(flowState: .discharging(rateW: 15)).powerSourceLocalizationKey,
            "flow.source.battery"
        )
        XCTAssertEqual(
            makeSnapshot(flowState: .supplementalDischarge(rateW: 5)).powerSourceLocalizationKey,
            "flow.source.supplemental"
        )
        XCTAssertEqual(makeSnapshot(flowState: .idle).powerSourceLocalizationKey, "flow.source.idle")
    }

    func testChargingSnapshotComputedProperties() {
        let snapshot = makeSnapshot(
            systemPowerW: 25.0,
            batteryPowerW: -10.0,
            acInputW: 35.0,
            isOnAC: true,
            isCharging: true,
            flowState: .charging(rateW: 10)
        )

        XCTAssertTrue(snapshot.effectiveIsOnAC)
        XCTAssertEqual(snapshot.effectiveACOutputW, 35.0, accuracy: 0.01)
        XCTAssertEqual(snapshot.batteryChargeRateW, 10.0, accuracy: 0.01)
        XCTAssertEqual(snapshot.headerPowerW, 35.0, accuracy: 0.01)
        XCTAssertEqual(snapshot.batteryDischargeRateW, 0, accuracy: 0.01)
    }

    func testDischargeSnapshotComputedProperties() {
        let snapshot = makeSnapshot(
            systemPowerW: 20.0,
            batteryPowerW: 20.0,
            acInputW: 0,
            isOnAC: false,
            isCharging: false,
            avgTimeToEmptyMinutes: 120,
            flowState: .discharging(rateW: 20.0)
        )

        XCTAssertFalse(snapshot.effectiveIsOnAC)
        XCTAssertEqual(snapshot.batteryDischargeRateW, 20.0, accuracy: 0.01)
        XCTAssertEqual(snapshot.headerPowerW, 20.0, accuracy: 0.01)
        XCTAssertEqual(snapshot.estimatedTimeRemainingMinutes, 120)
        XCTAssertEqual(snapshot.estimatedTimeRemainingText, "2h 0m")
    }

    func testSupplementalDischargeFlowState() {
        let snapshot = makeSnapshot(
            systemPowerW: 80.0,
            batteryPowerW: 20.0,
            acInputW: 60.0,
            isOnAC: true,
            isCharging: false,
            flowState: .supplementalDischarge(rateW: 20.0)
        )

        XCTAssertTrue(snapshot.effectiveIsOnAC)
        XCTAssertEqual(snapshot.batteryDischargeRateW, 20.0, accuracy: 0.01)
        XCTAssertEqual(snapshot.headerPowerW, 80.0, accuracy: 0.01)
    }

    func testUnpluggedWithSystemLoadResolvesToDischarging() {
        // Right after unplugging, BatteryPower and Amperage can still read zero
        // for one sample while the pack is already carrying the system.
        let flow = PowerStatusSampler.resolveBatteryFlow(
            isOnAC: false,
            isChargingFlag: false,
            acInputW: 0,
            systemLoadW: 14.3,
            amperagePowerW: nil,
            batteryPowerFromTelemetry: 0
        )

        guard case .discharging(let rateW) = flow else {
            return XCTFail("expected discharging, got \(flow)")
        }
        XCTAssertEqual(rateW, 14.3, accuracy: 0.01)
    }

    func testUnpluggedPrefersBatteryTelemetryForDischargeRate() {
        let flow = PowerStatusSampler.resolveBatteryFlow(
            isOnAC: false,
            isChargingFlag: false,
            acInputW: 0,
            systemLoadW: 14.3,
            amperagePowerW: nil,
            batteryPowerFromTelemetry: -14.3
        )

        guard case .discharging(let rateW) = flow else {
            return XCTFail("expected discharging, got \(flow)")
        }
        XCTAssertEqual(rateW, 14.3, accuracy: 0.01)
    }

    func testIdleOnlyWhenOffPowerAndDrawingNothing() {
        let flow = PowerStatusSampler.resolveBatteryFlow(
            isOnAC: false,
            isChargingFlag: false,
            acInputW: 0,
            systemLoadW: 0,
            amperagePowerW: nil,
            batteryPowerFromTelemetry: 0
        )

        XCTAssertEqual(flow, .idle)
    }

    func testBatteryHealthUsesDesignCapacityNotPercentage() {
        // Top-level MaxCapacity is a normalized 0-100 percentage on Apple
        // silicon; reading it as milliamps collapses health to a rounding error.
        let props: [String: Any] = [
            "MaxCapacity": 100,
            "BatteryData": [
                "DesignCapacity": 6075,
                "FullChargeCapacity": 5155,
                "RemainingCapacity": 4967,
            ] as [String: Any],
        ]

        let snapshot = PowerStatusSampler.readBatteryCapacitySnapshot(from: props)

        XCTAssertEqual(snapshot.healthPercent, 84)
        XCTAssertEqual(snapshot.designCapacityMAH, 6075)
        XCTAssertEqual(snapshot.fullChargeCapacityMAH, 5155)
        XCTAssertNil(snapshot.rawMaxCapacityMAH)
    }

    func testBatteryHealthReportsNinetyPercentFromRawMaxCapacity() {
        let props: [String: Any] = [
            "MaxCapacity": 100,
            "BatteryData": [
                "DesignCapacity": 5000,
                "AppleRawMaxCapacity": 4500,
            ] as [String: Any],
        ]

        let snapshot = PowerStatusSampler.readBatteryCapacitySnapshot(from: props)

        XCTAssertEqual(snapshot.healthPercent, 90)
        XCTAssertEqual(snapshot.rawMaxCapacityMAH, 4500)
    }

    func testBatteryHealthFallsBackToNominalChargeCapacity() {
        // Some machines report neither AppleRawMaxCapacity nor
        // FullChargeCapacity; NominalChargeCapacity is still a real mAh value.
        let props: [String: Any] = [
            "BatteryData": [
                "DesignCapacity": 5000,
                "NominalChargeCapacity": 4000,
            ] as [String: Any],
        ]

        let snapshot = PowerStatusSampler.readBatteryCapacitySnapshot(from: props)

        XCTAssertEqual(snapshot.healthPercent, 80)
        XCTAssertEqual(snapshot.fullChargeCapacityMAH, 4000)
    }

    func testBatteryCapacityReadsTopLevelWhenBatteryDataAbsent() {
        let props: [String: Any] = [
            "MaxCapacity": 100,
            "DesignCapacity": 5000,
            "FullChargeCapacity": 4800,
            "Temperature": 3150,
        ]

        let snapshot = PowerStatusSampler.readBatteryCapacitySnapshot(from: props)

        XCTAssertEqual(snapshot.designCapacityMAH, 5000)
        XCTAssertEqual(snapshot.fullChargeCapacityMAH, 4800)
        XCTAssertEqual(snapshot.healthPercent, 96)
        XCTAssertEqual(snapshot.temperatureCentidegrees, 3150)
    }

    func testEstimatedTimeFormatting() {
        let snapshot1 = makeSnapshot(
            avgTimeToEmptyMinutes: 45,
            flowState: .discharging(rateW: 10)
        )
        XCTAssertEqual(snapshot1.estimatedTimeRemainingText, "45m")

        let snapshot2 = makeSnapshot(
            avgTimeToEmptyMinutes: 125,
            flowState: .discharging(rateW: 10)
        )
        XCTAssertEqual(snapshot2.estimatedTimeRemainingText, "2h 5m")

        let snapshot3 = makeSnapshot(
            avgTimeToEmptyMinutes: 0,
            flowState: .discharging(rateW: 10)
        )
        XCTAssertNil(snapshot3.estimatedTimeRemainingText)
    }

    func testEstimatedTimeLabelKeyMatchesFlowState() {
        // Charging always reports time to full.
        XCTAssertEqual(
            makeSnapshot(flowState: .charging(rateW: 5)).estimatedTimeLabelKey,
            "metric.timeToFull"
        )

        // A valid macOS average is reported as remaining time.
        XCTAssertEqual(
            makeSnapshot(avgTimeToEmptyMinutes: 120, flowState: .discharging(rateW: 12)).estimatedTimeLabelKey,
            "metric.timeEstimate.remaining"
        )

        // Without one, the estimate is computed locally and labelled as such.
        XCTAssertEqual(
            makeSnapshot(
                batteryPowerW: 12,
                batteryVoltageMV: 12_000,
                remainingCapacityMAH: 3_000,
                flowState: .discharging(rateW: 12)
            ).estimatedTimeLabelKey,
            "metric.timeEstimate.computed"
        )

        // No time estimate applies on AC or while idle.
        XCTAssertNil(makeSnapshot(flowState: .onAC).estimatedTimeLabelKey)
        XCTAssertNil(makeSnapshot(flowState: .idle).estimatedTimeLabelKey)
    }

    func testComputedTimeToEmptyFallsBackWhenMacOSSilent() {
        // macOS reports no AvgTimeToEmpty; estimate from remaining energy.
        let snapshot = makeSnapshot(
            batteryPercent: 50,
            batteryVoltageMV: 12_000,
            fullChargeCapacityMAH: 4_000,
            avgTimeToEmptyMinutes: nil,
            remainingCapacityMAH: 2_000,
            flowState: .discharging(rateW: 20.0)
        )

        // 2000 mAh × 12 V = 24 Wh; 24 Wh / 20 W = 1.2 h = 72 min.
        XCTAssertEqual(snapshot.remainingEnergyWh ?? 0, 24.0, accuracy: 0.01)
        XCTAssertNotNil(snapshot.estimatedTimeRemainingMinutes)
        XCTAssertEqual(snapshot.estimatedTimeRemainingMinutes ?? 0, 72, accuracy: 1)
        XCTAssertEqual(snapshot.estimatedTimeRemainingText, "1h 12m")
        XCTAssertTrue(snapshot.estimatedTimeIsComputed)
        XCTAssertEqual(snapshot.estimatedTimeLabelKey, "metric.timeEstimate.computed")
    }

    func testEstimatedTimeUsesMacOSValueWhenAvailable() {
        let snapshot = makeSnapshot(
            batteryPercent: 50,
            batteryVoltageMV: 12_000,
            avgTimeToEmptyMinutes: 90,
            remainingCapacityMAH: 2_000,
            flowState: .discharging(rateW: 20.0)
        )

        XCTAssertEqual(snapshot.estimatedTimeRemainingMinutes, 90)
        XCTAssertFalse(snapshot.estimatedTimeIsComputed)
        XCTAssertEqual(snapshot.estimatedTimeLabelKey, "metric.timeEstimate.remaining")
    }

    func testNoTimeEstimateWhileOnAC() {
        let snapshot = makeSnapshot(
            isOnAC: true,
            batteryVoltageMV: 12_000,
            avgTimeToEmptyMinutes: nil,
            remainingCapacityMAH: 2_000,
            flowState: .onAC
        )

        XCTAssertNil(snapshot.estimatedTimeRemainingMinutes)
        XCTAssertFalse(snapshot.estimatedTimeIsComputed)
    }

    func testRemainingEnergyFallsBackToCapacityScaledByPercent() {
        let snapshot = makeSnapshot(
            batteryPercent: 40,
            batteryVoltageMV: 11_000,
            fullChargeCapacityMAH: 5_000,
            flowState: .discharging(rateW: 10.0)
        )

        // 5000 mAh × 40% × 11 V = 22 Wh
        XCTAssertEqual(snapshot.remainingEnergyWh ?? 0, 22.0, accuracy: 0.01)
    }

    func testSmoothedDischargePowersLocalEstimate() {
        let snapshot = makeSnapshot(
            batteryVoltageMV: 12_000,
            remainingCapacityMAH: 3_000,
            flowState: .discharging(rateW: 20.0)
        )
        var smoothed = snapshot
        smoothed.smoothedDischargePowerW = 15.0

        // 36 Wh / 15 W = 2.4 h = 144 min — the smoothed value drives the estimate.
        XCTAssertEqual(smoothed.estimatedTimeRemainingMinutes ?? 0, 144, accuracy: 1)
    }

    func testFlowDiagramRowCountMatchesFlowState() {
        XCTAssertEqual(
            PowerStatusLayout.flowDiagramRowCount(for: makeSnapshot(flowState: .onAC)),
            1
        )
        XCTAssertEqual(
            PowerStatusLayout.flowDiagramRowCount(for: makeSnapshot(flowState: .discharging(rateW: 15))),
            1
        )
        XCTAssertEqual(
            PowerStatusLayout.flowDiagramRowCount(
                for: makeSnapshot(isOnAC: true, isCharging: true, flowState: .charging(rateW: 12))
            ),
            2
        )
        XCTAssertEqual(
            PowerStatusLayout.flowDiagramRowCount(for: makeSnapshot(flowState: .supplementalDischarge(rateW: 8))),
            2
        )
        XCTAssertEqual(
            PowerStatusLayout.flowDiagramRowCount(for: makeSnapshot(isDataAvailable: false)),
            0
        )
    }

    func testContentHeightGrowsWithDiagramRows() {
        let oneRow = PowerStatusLayout.contentHeight(
            flowRowCount: 3,
            diagramRowCount: 1,
            capacityTileCount: 7,
            voltageCurrentTileCount: 4,
            isDataAvailable: true
        )
        let twoRows = PowerStatusLayout.contentHeight(
            flowRowCount: 3,
            diagramRowCount: 2,
            capacityTileCount: 7,
            voltageCurrentTileCount: 4,
            isDataAvailable: true
        )

        let expectedDelta = PowerStatusLayout.flowRowHeight + PowerStatusLayout.flowRowSpacing
        XCTAssertEqual(twoRows - oneRow, expectedDelta, accuracy: 0.5)
        XCTAssertGreaterThan(oneRow, 0)
    }

    func testContentHeightGrowsWithCapacityTiles() {
        let fewTiles = PowerStatusLayout.contentHeight(
            flowRowCount: 3,
            diagramRowCount: 1,
            capacityTileCount: 1,
            voltageCurrentTileCount: 0,
            isDataAvailable: true
        )
        let manyTiles = PowerStatusLayout.contentHeight(
            flowRowCount: 3,
            diagramRowCount: 1,
            capacityTileCount: 8,
            voltageCurrentTileCount: 0,
            isDataAvailable: true
        )

        XCTAssertGreaterThan(manyTiles, fewTiles)
    }

    func testFullyChargedTileShownOnlyWhileStillOnPower() {
        let charged = makeSnapshot(batteryPercent: 100, isOnAC: true, fullyCharged: true, flowState: .onAC)
        XCTAssertTrue(charged.showFullyCharged)

        let charging = makeSnapshot(
            batteryPercent: 100,
            isOnAC: true,
            isCharging: true,
            fullyCharged: true,
            flowState: .charging(rateW: 2)
        )
        XCTAssertTrue(charging.showFullyCharged)

        // A full pack on battery power still wants the discharge estimate.
        let discharging = makeSnapshot(batteryPercent: 100, flowState: .discharging(rateW: 12))
        XCTAssertFalse(discharging.showFullyCharged)

        let partial = makeSnapshot(batteryPercent: 80, isOnAC: true, flowState: .charging(rateW: 15))
        XCTAssertFalse(partial.showFullyCharged)
    }

    func testTelemetryTileCountsMatchAvailableData() {
        let bare = makeSnapshot(flowState: .onAC)
        XCTAssertFalse(bare.hasVoltageCurrentDetail)
        XCTAssertEqual(PowerStatusLayout.capacityTileCount(for: bare), 0)
        XCTAssertEqual(PowerStatusLayout.voltageCurrentTileCount(for: bare), 0)

        let full = makeSnapshot(
            batteryVoltageMV: 12_000,
            batteryAmperageMA: -800,
            batteryTemperatureC: 31.5,
            cycleCount: 240,
            batteryHealthPercent: 84,
            remainingCapacityMAH: 3_000,
            flowState: .discharging(rateW: 12)
        )
        XCTAssertTrue(full.hasVoltageCurrentDetail)
        // Voltage and current only; no charging readings off power.
        XCTAssertEqual(PowerStatusLayout.voltageCurrentTileCount(for: full), 2)
        // Remaining capacity, health, cycles, temperature, and the discharge
        // time estimate, which resolves from 36 Wh of remaining energy.
        XCTAssertEqual(PowerStatusLayout.capacityTileCount(for: full), 5)
    }

    // MARK: - Helpers

    private func makeSnapshot(
        systemPowerW: Double = 0,
        batteryPowerW: Double = 0,
        acInputW: Double = 0,
        acAdapterWattage: Int = 0,
        batteryPercent: Int = 0,
        isOnAC: Bool = false,
        isCharging: Bool = false,
        fullyCharged: Bool = false,
        batteryVoltageMV: Int? = nil,
        batteryAmperageMA: Int? = nil,
        batteryTemperatureC: Double? = nil,
        cycleCount: Int? = nil,
        batteryHealthPercent: Int? = nil,
        designCapacityMAH: Int? = nil,
        fullChargeCapacityMAH: Int? = nil,
        chargingVoltageMV: Int? = nil,
        chargingCurrentMA: Int? = nil,
        avgTimeToEmptyMinutes: Int? = nil,
        avgTimeToFullMinutes: Int? = nil,
        remainingCapacityMAH: Int? = nil,
        flowState: PowerFlowState = .idle,
        isDataAvailable: Bool = true
    ) -> PowerStatusSnapshot {
        PowerStatusSnapshot(
            timestamp: Date(),
            systemPowerW: systemPowerW,
            batteryPowerW: batteryPowerW,
            acInputW: acInputW,
            acAdapterWattage: acAdapterWattage,
            batteryPercent: batteryPercent,
            isOnAC: isOnAC,
            isCharging: isCharging,
            fullyCharged: fullyCharged,
            batteryVoltageMV: batteryVoltageMV,
            batteryAmperageMA: batteryAmperageMA,
            batteryTemperatureC: batteryTemperatureC,
            cycleCount: cycleCount,
            batteryHealthPercent: batteryHealthPercent,
            designCapacityMAH: designCapacityMAH,
            fullChargeCapacityMAH: fullChargeCapacityMAH,
            chargingVoltageMV: chargingVoltageMV,
            chargingCurrentMA: chargingCurrentMA,
            avgTimeToEmptyMinutes: avgTimeToEmptyMinutes,
            avgTimeToFullMinutes: avgTimeToFullMinutes,
            remainingCapacityMAH: remainingCapacityMAH,
            flowState: flowState,
            isDataAvailable: isDataAvailable,
            smoothedDischargePowerW: nil
        )
    }
}
