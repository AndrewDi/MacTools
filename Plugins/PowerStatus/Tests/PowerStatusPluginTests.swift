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

    func testFlowStateDescription() {
        XCTAssertEqual(PowerFlowState.onAC.description, "交流供电")
        XCTAssertEqual(PowerFlowState.charging(rateW: 30).description, "充电中")
        XCTAssertEqual(PowerFlowState.discharging(rateW: 15).description, "电池放电")
        XCTAssertEqual(PowerFlowState.supplementalDischarge(rateW: 5).description, "电池辅助供电")
        XCTAssertEqual(PowerFlowState.idle.description, "空闲")
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

    func testPowerSourceDescription() {
        let acSnapshot = makeSnapshot(isOnAC: true, flowState: .onAC)
        XCTAssertEqual(acSnapshot.powerSourceDescription, "交流供电")

        let chargingSnapshot = makeSnapshot(isOnAC: true, isCharging: true, flowState: .charging(rateW: 10))
        XCTAssertEqual(chargingSnapshot.powerSourceDescription, "交流充电中")

        let batterySnapshot = makeSnapshot(isOnAC: false, flowState: .discharging(rateW: 15))
        XCTAssertEqual(batterySnapshot.powerSourceDescription, "电池供电")
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
        XCTAssertEqual(snapshot.estimatedTimeLabel, "预计可用时间")
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
        XCTAssertEqual(snapshot.estimatedTimeLabel, "预计剩余时间")
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
            miniMetricRowCount: 2,
            diagramRowCount: 1,
            telemetryRowCount: 4,
            telemetryGroupCount: 2,
            isDataAvailable: true
        )
        let twoRows = PowerStatusLayout.contentHeight(
            flowRowCount: 3,
            miniMetricRowCount: 2,
            diagramRowCount: 2,
            telemetryRowCount: 4,
            telemetryGroupCount: 2,
            isDataAvailable: true
        )

        let expectedDelta = PowerStatusLayout.flowRowHeight + PowerStatusLayout.flowRowSpacing
        XCTAssertEqual(twoRows - oneRow, expectedDelta, accuracy: 0.5)
        XCTAssertGreaterThan(oneRow, 0)
    }

    func testContentHeightGrowsWithTelemetryGroups() {
        let withoutTelemetry = PowerStatusLayout.contentHeight(
            flowRowCount: 3,
            miniMetricRowCount: 2,
            diagramRowCount: 1,
            telemetryRowCount: 0,
            telemetryGroupCount: 0,
            isDataAvailable: true
        )
        let withTelemetry = PowerStatusLayout.contentHeight(
            flowRowCount: 3,
            miniMetricRowCount: 2,
            diagramRowCount: 1,
            telemetryRowCount: 4,
            telemetryGroupCount: 2,
            isDataAvailable: true
        )

        XCTAssertGreaterThan(withTelemetry, withoutTelemetry)
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

    func testTelemetryGroupsAppearOnlyWhenDataExists() {
        let bare = makeSnapshot(flowState: .onAC)
        XCTAssertFalse(bare.hasVoltageCurrentDetail)
        XCTAssertFalse(bare.hasCapacityDetail)
        XCTAssertEqual(PowerStatusLayout.telemetryRowCount(for: bare), 0)
        XCTAssertEqual(PowerStatusLayout.telemetryGroupCount(for: bare), 0)

        let full = makeSnapshot(
            batteryVoltageMV: 12_000,
            batteryAmperageMA: -800,
            remainingCapacityMAH: 3_000,
            flowState: .discharging(rateW: 12)
        )
        XCTAssertTrue(full.hasVoltageCurrentDetail)
        XCTAssertTrue(full.hasCapacityDetail)
        XCTAssertEqual(PowerStatusLayout.telemetryRowCount(for: full), 2)
        XCTAssertEqual(PowerStatusLayout.telemetryGroupCount(for: full), 2)
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
