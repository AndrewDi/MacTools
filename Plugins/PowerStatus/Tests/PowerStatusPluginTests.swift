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
            flowState: flowState,
            isDataAvailable: isDataAvailable
        )
    }
}
