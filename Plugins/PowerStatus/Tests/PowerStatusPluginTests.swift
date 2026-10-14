import XCTest
@testable import PowerStatusPlugin

final class PowerStatusPluginTests: XCTestCase {

    @MainActor
    func testPluginMetadata() {
        let plugin = makePlugin()
        let metadata = plugin.metadata

        XCTAssertEqual(metadata.id, "power-status")
        XCTAssertFalse(metadata.title.isEmpty)
        XCTAssertFalse(metadata.iconName.isEmpty)
        XCTAssertFalse(metadata.defaultDescription.isEmpty)
    }

    @MainActor
    func testPanelItemsContainSingleWidget() {
        let plugin = makePlugin()
        let items = plugin.panelItems

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.kind, .widget)
    }

    @MainActor
    func testWidgetStateReflectsDataAvailability() {
        let plugin = makePlugin()

        // Initially no data
        XCTAssertFalse(plugin.widgetState.isAvailable)
        XCTAssertFalse(plugin.widgetState.isActive)
    }

    @MainActor
    func testSnapshotEmptyDefaults() {
        let snapshot = PowerStatusSnapshot.empty

        XCTAssertEqual(snapshot.batteryPercent, 0)
        XCTAssertFalse(snapshot.isOnAC)
        XCTAssertFalse(snapshot.isCharging)
        XCTAssertFalse(snapshot.isDataAvailable)
        XCTAssertEqual(snapshot.systemPowerW, 0)
        XCTAssertEqual(snapshot.flowState, .idle)
    }

    @MainActor
    func testFlowStateDescription() {
        XCTAssertEqual(PowerFlowState.onAC.description, "交流供电")
        XCTAssertEqual(PowerFlowState.charging(rateW: 30).description, "充电中")
        XCTAssertEqual(PowerFlowState.discharging(rateW: 15).description, "电池放电")
    }

    @MainActor
    func testSnapshotComputedProperties() {
        var snapshot = PowerStatusSnapshot.empty
        snapshot = PowerStatusSnapshot(
            timestamp: Date(),
            systemPowerW: 25.0,
            batteryPowerW: -10.0,
            acInputW: 35.0,
            acAdapterWattage: 61,
            batteryPercent: 80,
            isOnAC: true,
            isCharging: true,
            fullyCharged: false,
            batteryVoltageMV: 12000,
            batteryAmperageMA: -833,
            batteryTemperatureC: 28.5,
            cycleCount: 350,
            batteryHealthPercent: 95,
            designCapacityMAH: 4383,
            fullChargeCapacityMAH: 4164,
            chargingVoltageMV: 12600,
            chargingCurrentMA: 2000,
            avgTimeToEmptyMinutes: nil,
            avgTimeToFullMinutes: 75,
            flowState: .charging(rateW: 10),
            isDataAvailable: true
        )

        XCTAssertTrue(snapshot.effectiveIsOnAC)
        XCTAssertEqual(snapshot.effectiveACOutputW, 35.0, accuracy: 0.01)
        XCTAssertEqual(snapshot.batteryChargeRateW, 10.0, accuracy: 0.01)
        XCTAssertEqual(snapshot.headerPowerW, 35.0, accuracy: 0.01)
        XCTAssertEqual(snapshot.batteryDischargeRateW, 0, accuracy: 0.01)
    }

    @MainActor
    func testDischargeFlowState() {
        let snapshot = PowerStatusSnapshot(
            timestamp: Date(),
            systemPowerW: 20.0,
            batteryPowerW: 20.0,
            acInputW: 0,
            acAdapterWattage: 0,
            batteryPercent: 50,
            isOnAC: false,
            isCharging: false,
            fullyCharged: false,
            batteryVoltageMV: 12000,
            batteryAmperageMA: 1667,
            batteryTemperatureC: 30.0,
            cycleCount: 200,
            batteryHealthPercent: 90,
            designCapacityMAH: 5000,
            fullChargeCapacityMAH: 4500,
            chargingVoltageMV: nil,
            chargingCurrentMA: nil,
            avgTimeToEmptyMinutes: 120,
            avgTimeToFullMinutes: nil,
            flowState: .discharging(rateW: 20.0),
            isDataAvailable: true
        )

        XCTAssertFalse(snapshot.effectiveIsOnAC)
        XCTAssertEqual(snapshot.batteryDischargeRateW, 20.0, accuracy: 0.01)
        XCTAssertEqual(snapshot.headerPowerW, 20.0, accuracy: 0.01)
        XCTAssertEqual(snapshot.estimatedTimeRemainingMinutes, 120)
        XCTAssertEqual(snapshot.estimatedTimeRemainingText, "2h 0m")
    }

    // MARK: - Helpers

    @MainActor
    private func makePlugin() -> PowerStatusPlugin {
        let context = PluginRuntimeContext(
            pluginID: "power-status",
            resourceBundle: .main,
            storage: PluginStorage(storage: UserDefaults(suiteName: "test-power-status")!),
            supportDirectory: FileManager.default.temporaryDirectory,
            cacheDirectory: FileManager.default.temporaryDirectory,
            temporaryDirectory: FileManager.default.temporaryDirectory
        )
        return PowerStatusPlugin(context: context)
    }
}
