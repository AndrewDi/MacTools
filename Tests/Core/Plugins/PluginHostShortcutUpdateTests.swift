import Combine
import MacToolsPluginKit
import XCTest
@testable import MacTools

@MainActor
final class PluginHostShortcutUpdateTests: XCTestCase {
    func testPhaseShortcutsReadDefinitionsOncePerHostPhase() async {
        let plugin = ShortcutPlugin(scope: .whilePluginActive)
        let host = makePluginHostForTests(plugins: [plugin])
        plugin.definitionReads = 0
        plugin.onStateChange?()
        await host.waitForScheduledPluginStateRebuildForTests()
        XCTAssertLessThanOrEqual(plugin.definitionReads, 4)
        XCTAssertEqual(host.shortcutItems.filter { $0.pluginID == plugin.metadata.id }.count, 16)
    }

    func testBatchResetUnregistersEveryBindingBeforeReturningAndPublishesOnce() {
        let plugin = ShortcutPlugin(scope: .global)
        let suite = "PluginHostShortcutUpdateTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ShortcutStore(userDefaults: defaults)
        let bindings = (0..<16).map { ShortcutBinding(keyCode: UInt16($0), modifiers: [.command, .option, .control]) }
        for (index, binding) in bindings.enumerated() {
            store.setCustomization(.custom(binding), for: "batch.shortcut.\(index)")
        }
        let registrar = FakeCarbonHotKeyRegistrar()
        let manager = GlobalShortcutManager(registrar: registrar)
        let host = PluginHost(plugins: [plugin], shortcutStore: store,
                              pluginDisplayPreferencesStore: PluginDisplayPreferencesStore(userDefaults: defaults),
                              preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
                              globalShortcutManager: manager)
        XCTAssertTrue(Set(bindings).isSubset(of: Set(registrar.registeredBindings)))
        var publications = 0
        let unregisteredBeforeReset = registrar.unregisteredCount
        let subscription = host.menuBarPanelContentDidChange.sink { publications += 1 }
        plugin.resetShortcutCustomizations?((0..<16).map(String.init) + ["unknown", "0"])
        XCTAssertEqual(publications, 1)
        XCTAssertEqual(registrar.unregisteredCount - unregisteredBeforeReset, 16)
        XCTAssertFalse(manager.registrationStatuses.keys.contains { $0.hasPrefix("batch.shortcut.") })
        for index in 0..<16 {
            XCTAssertEqual(store.customization(for: "batch.shortcut.\(index)"), .inheritDefault)
        }
        withExtendedLifetime(subscription) {}
    }
}

@MainActor
private final class ShortcutPlugin: MacToolsPlugin, PluginShortcutEventHandling, PluginShortcutResetRequesting {
    let metadata = PluginMetadata(id: "batch", title: "Batch", iconName: "keyboard", iconTint: .blue,
                                  order: 0, defaultDescription: "")
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var resetShortcutCustomizations: (([String]) -> Void)?
    var definitionReads = 0
    let scope: ShortcutScope
    init(scope: ShortcutScope) { self.scope = scope }
    var shortcutDefinitions: [PluginShortcutDefinition] {
        definitionReads += 1
        return (0..<16).map {
            PluginShortcutDefinition(id: String($0), title: "Shortcut \($0)", description: "", actionID: String($0),
                                     scope: scope, defaultBinding: nil, isRequired: false)
        }
    }
    func handleShortcutEvent(id: String, phase: PluginShortcutEventPhase) {}
}
