import XCTest
import MacToolsPluginKit
@testable import MacTools
@testable import DisplayVolumePlugin

@MainActor
final class DisplayVolumePluginTests: XCTestCase {
    func testParseDisplayIDExtractsNumericIdentifier() {
        XCTAssertEqual(
            DisplayVolumePlugin.parseDisplayID(from: "display.42.volume"),
            42
        )
    }

    func testParseDisplayIDRejectsUnexpectedControlID() {
        XCTAssertNil(DisplayVolumePlugin.parseDisplayID(from: "display.42"))
        XCTAssertNil(DisplayVolumePlugin.parseDisplayID(from: "volume.42"))
        XCTAssertNil(DisplayVolumePlugin.parseDisplayID(from: "display.foo.volume"))
    }

    func testEmptySnapshotDisablesPluginAndSuppressesDetail() {
        let controller = MockDisplayVolumeController()
        controller.snapshotValue = DisplayVolumeSnapshot(displays: [], errorMessage: nil)

        let plugin = DisplayVolumePlugin(controller: controller)
        plugin.handleAction(.setDisclosureExpanded(true))

        let state = plugin.primaryPanelState

        XCTAssertEqual(state.subtitle, "未检测到可调节音量的显示器")
        XCTAssertFalse(state.isEnabled)
        XCTAssertFalse(state.isExpanded)
        XCTAssertNil(state.detail)
    }

    func testSingleDisplaySummaryIncludesDisplayNameAndVolume() {
        let controller = MockDisplayVolumeController()
        controller.snapshotValue = DisplayVolumeSnapshot(
            displays: [
                makeVolumeDisplay(id: 7, name: "Studio Display", volume: 0.72)
            ],
            errorMessage: nil
        )

        let plugin = DisplayVolumePlugin(controller: controller)

        XCTAssertEqual(plugin.primaryPanelState.subtitle, "Studio Display 72%")
    }

    func testMultipleDisplaysSummaryUsesDisplayCount() {
        let controller = MockDisplayVolumeController()
        controller.snapshotValue = DisplayVolumeSnapshot(
            displays: [
                makeVolumeDisplay(id: 7, name: "Studio Display", volume: 0.72),
                makeVolumeDisplay(id: 9, name: "LG UltraFine", volume: 0.41)
            ],
            errorMessage: nil
        )

        let plugin = DisplayVolumePlugin(controller: controller)

        XCTAssertEqual(plugin.primaryPanelState.subtitle, "2 个显示器")
    }

    func testExpandedStateBuildsOneSliderPerDisplay() throws {
        let controller = MockDisplayVolumeController()
        controller.snapshotValue = DisplayVolumeSnapshot(
            displays: [
                makeVolumeDisplay(id: 7, name: "Studio Display", volume: 0.72),
                makeVolumeDisplay(id: 9, name: "LG UltraFine", volume: 0.41)
            ],
            errorMessage: nil
        )

        let plugin = DisplayVolumePlugin(controller: controller)
        plugin.handleAction(.setDisclosureExpanded(true))

        let controls = try XCTUnwrap(plugin.primaryPanelState.detail?.primaryControls)
        let sliders = controls.filter { $0.kind == .slider }

        XCTAssertEqual(sliders.count, 2)
        XCTAssertEqual(sliders.map(\.id), ["display.7.volume", "display.9.volume"])
        XCTAssertEqual(sliders.map(\.sectionTitle), ["Studio Display", "LG UltraFine"])
        XCTAssertEqual(sliders.map(\.valueLabel), ["72%", "41%"])
        XCTAssertEqual(sliders.first?.sliderBounds, 0...1)
        XCTAssertEqual(sliders.first?.sliderStep, 0.01)
    }

    func testShortcutDefinitionsIncludeDecreaseAndIncreaseOnly() {
        let controller = MockDisplayVolumeController()
        controller.snapshotValue = DisplayVolumeSnapshot(
            displays: [
                makeVolumeDisplay(
                    id: 7,
                    name: "Studio Display",
                    volume: 0.72,
                    vendorNumber: 0x610,
                    modelNumber: 32,
                    serialNumber: 9001
                )
            ],
            errorMessage: nil
        )

        let plugin = DisplayVolumePlugin(controller: controller)

        XCTAssertEqual(plugin.shortcutDefinitions.count, 2)
        XCTAssertEqual(
            plugin.shortcutDefinitions.map(\.id),
            ["display-volume.decrease", "display-volume.increase"]
        )
        XCTAssertEqual(
            plugin.shortcutDefinitions.map(\.actionID),
            ["display-volume.decrease", "display-volume.increase"]
        )
        XCTAssertFalse(plugin.shortcutDefinitions.contains { $0.isRequired })
        XCTAssertEqual(plugin.shortcutDefinitions.first?.scope, .global)
    }

    func testSettingsPageContainsShortcutTargetSection() {
        let controller = MockDisplayVolumeController()
        let storage = DisplayVolumeMemoryStorage()
        let preferences = DisplayVolumeShortcutPreferences(storage: storage)

        let plugin = DisplayVolumePlugin(
            controller: controller,
            shortcutPreferences: preferences
        )

        guard case let .form(sections) = plugin.settingsPage?.body else {
            XCTFail("Expected form settings page")
            return
        }

        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections.first?.id, "shortcut-target")

        guard case let .rows(rows) = sections.first?.content else {
            XCTFail("Expected rows content")
            return
        }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.id, "shortcut-target")

        guard case .picker(let selectionID, _, _) = rows.first?.control else {
            XCTFail("Expected picker control")
            return
        }

        XCTAssertEqual(selectionID, "followsMouse")
    }

    func testSettingsSelectionUpdatesShortcutPreferences() {
        let controller = MockDisplayVolumeController()
        let storage = DisplayVolumeMemoryStorage()
        let preferences = DisplayVolumeShortcutPreferences(storage: storage)

        let plugin = DisplayVolumePlugin(
            controller: controller,
            shortcutPreferences: preferences
        )

        var didNotify = false
        plugin.onStateChange = { didNotify = true }

        plugin.handleSettingsAction(.setSelection(controlID: "shortcut-target", optionID: "allDisplays"))

        XCTAssertEqual(preferences.targetMode, .allDisplays)
        XCTAssertTrue(didNotify)
    }

    func testActionAvailabilityRequiresDisplays() {
        let controller = MockDisplayVolumeController()
        controller.snapshotValue = DisplayVolumeSnapshot(displays: [], errorMessage: nil)

        let plugin = DisplayVolumePlugin(controller: controller)

        let reference = ActionReference(
            key: ActionKey(providerID: "display-volume", actionID: "display-volume.increase")
        )
        let availability = plugin.actionAvailability(for: reference)

        XCTAssertFalse(availability.isAvailable)
        XCTAssertEqual(availability.reason, "未检测到可调节音量的显示器。")
    }

    func testBeginActionIncreasesVolumeByOnePercent() async throws {
        let controller = MockDisplayVolumeController()
        controller.snapshotValue = DisplayVolumeSnapshot(
            displays: [
                makeVolumeDisplay(id: 7, name: "Studio Display", volume: 0.50)
            ],
            errorMessage: nil
        )

        let plugin = DisplayVolumePlugin(controller: controller)

        let invocation = ActionInvocation(
            reference: ActionReference(
                key: ActionKey(providerID: "display-volume", actionID: "display-volume.increase")
            ),
            source: .test,
            mode: .background
        )
        let handle = try plugin.beginAction(invocation)
        let result = await handle.result()

        XCTAssertEqual(result, .succeeded())
        XCTAssertEqual(controller.volumeWrites.last?.value ?? 0, 0.51, accuracy: 0.001)
    }

    func testBeginActionDecreasesVolumeByOnePercent() async throws {
        let controller = MockDisplayVolumeController()
        controller.snapshotValue = DisplayVolumeSnapshot(
            displays: [
                makeVolumeDisplay(id: 7, name: "Studio Display", volume: 0.50)
            ],
            errorMessage: nil
        )

        let plugin = DisplayVolumePlugin(controller: controller)

        let invocation = ActionInvocation(
            reference: ActionReference(
                key: ActionKey(providerID: "display-volume", actionID: "display-volume.decrease")
            ),
            source: .test,
            mode: .background
        )
        let handle = try plugin.beginAction(invocation)
        let result = await handle.result()

        XCTAssertEqual(result, .succeeded())
        XCTAssertEqual(controller.volumeWrites.last?.value ?? 0, 0.49, accuracy: 0.001)
    }

    func testDeactivateCancelsOutstandingWrites() {
        let controller = MockDisplayVolumeController()
        let plugin = DisplayVolumePlugin(controller: controller)

        plugin.deactivate(reason: .updating)

        XCTAssertEqual(controller.cancelOutstandingWritesCount, 1)
    }

    func testSettingsSearchEntriesContainShortcutTarget() {
        let controller = MockDisplayVolumeController()
        let plugin = DisplayVolumePlugin(controller: controller)

        XCTAssertEqual(plugin.settingsSearchEntries.count, 1)
        XCTAssertEqual(plugin.settingsSearchEntries.first?.id, "shortcut-target")
        XCTAssertEqual(plugin.settingsSearchEntries.first?.systemImage, "display.2")
    }

    func testActionDefinitionsHaveCorrectKeys() {
        let controller = MockDisplayVolumeController()
        let plugin = DisplayVolumePlugin(controller: controller)

        XCTAssertEqual(plugin.actionDefinitions.count, 2)
        XCTAssertEqual(
            plugin.actionDefinitions.map(\.key.actionID),
            ["display-volume.decrease", "display-volume.increase"]
        )
    }

    func testShortcutDirectionMapping() {
        XCTAssertEqual(
            DisplayVolumePlugin.shortcutDirection(for: "display-volume.decrease"),
            .decrease
        )
        XCTAssertEqual(
            DisplayVolumePlugin.shortcutDirection(for: "display-volume.increase"),
            .increase
        )
        XCTAssertNil(
            DisplayVolumePlugin.shortcutDirection(for: "unknown")
        )
    }
}
