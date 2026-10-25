import Carbon
import MacToolsPluginKit
import XCTest
@testable import TranslatorPlugin

@MainActor
final class TranslatorPluginTests: XCTestCase {

    func testPrimaryPanelReflectsPermissionAndSetupState() {
        XCTAssertEqual(
            makePlugin(accessibilityTrustProvider: { false }).rowState.subtitle,
            "启用前需要辅助功能授权"
        )

        let storage = TranslatorInMemoryPluginStorage()
        let plugin = makePlugin(storage: storage, secretStore: CountingTranslatorSecretStore(apiKey: nil))
        let message = plugin.saveConfiguration(
            OpenAICompatibleConfiguration(
                baseURL: "https://gateway.example.com",
                model: "gpt-test",
                promptTemplate: "{{text}}"
            ),
            apiKey: "",
            languagePair: TranslatorLanguagePair(first: .english, second: .simplifiedChinese)
        )

        XCTAssertEqual(message, "API Key 不能为空。")
        XCTAssertEqual(plugin.rowState.subtitle, "需要配置翻译服务")
    }

    func testSavingBlankAPIKeyPreservesExistingKey() {
        let secretStore = CountingTranslatorSecretStore(apiKey: "sk-existing")
        let plugin = makePlugin(secretStore: secretStore)

        let message = plugin.saveConfiguration(
            OpenAICompatibleConfiguration(
                baseURL: TranslatorProviderProfile.defaultProfile().baseURL,
                model: "gpt-test",
                promptTemplate: "{{text}}"
            ),
            apiKey: "",
            languagePair: TranslatorLanguagePair(first: .english, second: .simplifiedChinese)
        )

        XCTAssertNil(message)
        XCTAssertEqual(secretStore.saveCount, 0)
        XCTAssertEqual(plugin.rowState.subtitle, "按 ⌥D 划词，⌥S 截图")
    }

    func testCredentialUpgradePreservesActiveServiceBesideIncompleteDisabledDraft() throws {
        for endpoint in ["https://gateway.example/v1", "HTTPS://gateway.example/v1?api-version=2026-01-01"] {
            let storage = TranslatorInMemoryPluginStorage()
            let secret = CountingTranslatorSecretStore(apiKey: "existing-local-key")
            var active = TranslatorProviderProfile.defaultProfile()
            active.baseURL = endpoint
            let draft = TranslatorProviderProfile(id: "draft", name: "Draft", isEnabled: false, baseURL: "")
            let profiles = [active, draft]
            storage.set(try JSONEncoder().encode(profiles), forKey: TranslatorConstants.StorageKey.providerProfiles)
            let plugin = makePlugin(storage: storage, secretStore: secret)

            let grants = PortableCredentialAuthorization(storage: storage)
            XCTAssertTrue(grants.isInitialized)
            XCTAssertTrue(grants.allows(profileID: active.id, baseURL: endpoint))
            XCTAssertFalse(grants.allows(profileID: draft.id, baseURL: draft.baseURL))
            XCTAssertNil(plugin.saveConfiguration(profiles: profiles, apiKeys: [:],
                languagePair: .init(first: .english, second: .simplifiedChinese)))
            XCTAssertEqual(try JSONDecoder().decode([TranslatorProviderProfile].self,
                from: XCTUnwrap(storage.data(forKey: TranslatorConstants.StorageKey.providerProfiles))), profiles)
            XCTAssertEqual(secret.loadCount, 0)
            XCTAssertEqual(secret.saveCount, 0)
        }
    }

    func testSavedIncompleteDisabledDraftTransfersWithoutCredentialAccess() throws {
        let source = makePlugin()
        let active = TranslatorProviderProfile.defaultProfile()
        let draft = TranslatorProviderProfile(id: "draft", name: "", isEnabled: false, baseURL: "https://", model: "")
        XCTAssertNil(source.saveConfiguration(profiles: [active, draft], apiKeys: [:],
            languagePair: .init(first: .english, second: .simplifiedChinese)))
        let data = try XCTUnwrap(source.makePortablePreferencesBackup())
        let storage = TranslatorInMemoryPluginStorage()
        let secret = CountingTranslatorSecretStore(apiKey: "local-secret")
        let destination = makePlugin(storage: storage, secretStore: secret)
        XCTAssertTrue(destination.restorePortablePreferencesReportingResult(from: data))
        let saved = try XCTUnwrap(storage.data(forKey: TranslatorConstants.StorageKey.providerProfiles))
        let profiles = try JSONDecoder().decode([TranslatorProviderProfile].self, from: saved)
        XCTAssertEqual(profiles.first { $0.id == draft.id }, draft)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var incoming = try XCTUnwrap(object["profiles"] as? [[String: Any]])
        incoming[1]["isEnabled"] = true
        object["profiles"] = incoming
        XCTAssertFalse(destination.restorePortablePreferencesReportingResult(from: try JSONSerialization.data(withJSONObject: object)))
        incoming[1]["isEnabled"] = false
        incoming[1]["baseURL"] = "https://user:secret@gateway.example/v1"
        object["profiles"] = incoming
        XCTAssertFalse(destination.restorePortablePreferencesReportingResult(from: try JSONSerialization.data(withJSONObject: object)))
        XCTAssertEqual(storage.data(forKey: TranslatorConstants.StorageKey.providerProfiles), saved)
        XCTAssertEqual(secret.loadCount, 0)
        XCTAssertEqual(secret.saveCount, 0)
    }

    func testPrimaryPanelTogglePersistsDisabledStateAndNotifies() {
        let storage = TranslatorInMemoryPluginStorage()
        let plugin = makePlugin(storage: storage)
        var didNotify = false
        plugin.onStateChange = { didNotify = true }

        plugin.handleAction(.setSwitch(false))

        XCTAssertEqual(storage.bool(forKey: "translator.shortcut.enabled"), false)
        XCTAssertTrue(didNotify)
        XCTAssertFalse(plugin.rowState.isOn)
    }

    func testActionsReuseTranslationStartersAndMigrateLegacyBindings() async throws {
        var selectStartCount = 0
        let plugin = makePlugin(selectTranslationStarter: { selectStartCount += 1 })
        plugin.shortcutBindingResolver = { shortcutID in
            shortcutID == "translator.select-translation"
                ? ShortcutBinding(keyCode: UInt16(kVK_ANSI_D), modifiers: [.option])
                : nil
        }
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        let result = try await plugin.beginAction(
            ActionInvocation(reference: reference, source: .test, mode: .foreground)
        ).result()

        XCTAssertEqual(plugin.actionDefinitions.map(\.key.actionID), [
            "select-translation",
            "screenshot-translation",
        ])
        XCTAssertEqual(plugin.legacyActionShortcutAssignments.count, 1)
        XCTAssertEqual(
            plugin.legacyActionShortcutAssignments.first?.legacyShortcutDefinitionID,
            "translator.select-translation"
        )
        XCTAssertEqual(result, .succeeded())
        XCTAssertEqual(selectStartCount, 1)
    }

    func testImportedEndpointRemainsQuarantinedWithoutChangingLocalConsentOrKeys() throws {
        let storage = TranslatorInMemoryPluginStorage()
        let secret = CountingTranslatorSecretStore(apiKey: "local-secret")
        let plugin = makePlugin(storage: storage, secretStore: secret)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(plugin.makePortablePreferencesBackup())) as? [String: Any])
        var profiles = try XCTUnwrap(object["profiles"] as? [[String: Any]])
        profiles[0]["baseURL"] = "https://imported.example/v1"
        object["profiles"] = profiles
        let incoming = try JSONSerialization.data(withJSONObject: object)
        XCTAssertTrue(plugin.restorePortablePreferencesReportingResult(from: incoming))
        XCTAssertTrue(plugin.restorePortablePreferencesReportingResult(from: incoming))
        let reloaded = makePlugin(storage: storage, secretStore: secret)
        let id = try XCTUnwrap(profiles[0]["id"] as? String)
        XCTAssertFalse(PortableCredentialAuthorization(storage: storage).allows(profileID: id, baseURL: "https://imported.example/v1"))
        XCTAssertEqual(secret.loadCount, 0)
        XCTAssertEqual(secret.saveCount, 0)
        XCTAssertFalse(storage.bool(forKey: "preferences-backup.include-prompt-text"))
        XCTAssertNotNil(reloaded.saveConfiguration(OpenAICompatibleConfiguration(baseURL: "https://imported.example/v1", model: "test", promptTemplate: "{{text}}"), apiKey: "", languagePair: .init(first: .english, second: .simplifiedChinese)))
    }

    func testDisabledImportedProfileCannotAuthorizeUnsavedReplacementKey() throws {
        let storage = TranslatorInMemoryPluginStorage()
        let secret = CountingTranslatorSecretStore(apiKey: "existing-destination-secret")
        var local = TranslatorProviderProfile.defaultProfile()
        local.isEnabled = false
        let other = TranslatorProviderProfile(id: "other", name: "Other", baseURL: "https://other.example/v1")
        storage.set(try JSONEncoder().encode([local, other]), forKey: TranslatorConstants.StorageKey.providerProfiles)
        let plugin = makePlugin(storage: storage, secretStore: secret)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(plugin.makePortablePreferencesBackup())) as? [String: Any])
        var profiles = try XCTUnwrap(object["profiles"] as? [[String: Any]])
        local.baseURL = "https://imported.example/v1"
        profiles[0]["baseURL"] = local.baseURL
        object["profiles"] = profiles
        let incoming = try JSONSerialization.data(withJSONObject: object)
        XCTAssertTrue(plugin.restorePortablePreferencesReportingResult(from: incoming))

        XCTAssertNil(plugin.saveConfiguration(profiles: [local, other], apiKeys: [local.id: "replacement-key"],
            languagePair: .init(first: .english, second: .simplifiedChinese)))
        XCTAssertEqual(secret.saveCount, 0)
        XCTAssertFalse(PortableCredentialAuthorization(storage: storage).allows(profileID: local.id, baseURL: local.baseURL))

        let reopened = makePlugin(storage: storage, secretStore: secret)
        local.isEnabled = true
        XCTAssertNotNil(reopened.saveConfiguration(profiles: [local, other], apiKeys: [:],
            languagePair: .init(first: .english, second: .simplifiedChinese)))
        XCTAssertEqual(secret.loadCount, 0)
        XCTAssertEqual(secret.saveCount, 0)
        XCTAssertFalse(PortableCredentialAuthorization(storage: storage).allows(profileID: local.id, baseURL: local.baseURL))

        XCTAssertNil(reopened.saveConfiguration(profiles: [local, other], apiKeys: [local.id: "replacement-key"],
            languagePair: .init(first: .english, second: .simplifiedChinese)))
        XCTAssertEqual(secret.saveCount, 1)
        XCTAssertTrue(PortableCredentialAuthorization(storage: storage).allows(profileID: local.id, baseURL: local.baseURL))
    }

    private func makePlugin(
        storage: TranslatorInMemoryPluginStorage? = nil,
        accessibilityTrustProvider: @escaping () -> Bool = { true },
        secretStore: (any TranslatorSecretStoring)? = nil,
        selectTranslationStarter: (() -> Void)? = nil
    ) -> TranslatorPlugin {
        let storage = storage ?? TranslatorInMemoryPluginStorage()
        return TranslatorPlugin(
            context: PluginRuntimeContext(pluginID: "translator", storage: storage),
            accessibilityTrustProvider: accessibilityTrustProvider,
            accessibilityTrustRequester: { _ in true },
            screenRecordingPermissionProvider: { true },
            selectTranslationStarter: selectTranslationStarter,
            secretStore: secretStore ?? CountingTranslatorSecretStore(apiKey: "sk-test"),
            panelController: RecordingTranslatorPanelController(),
            selectedTextCapturePipeline: SelectedTextCapturePipeline(strategies: [])
        )
    }
}

private final class CountingTranslatorSecretStore: TranslatorSecretStoring, @unchecked Sendable {
    private var apiKey: String?
    private(set) var saveCount = 0
    private(set) var loadCount = 0

    init(apiKey: String?) {
        self.apiKey = apiKey
    }

    func containsAPIKey() throws -> Bool {
        apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    func containsAPIKey(forProfileID _: String) throws -> Bool {
        try containsAPIKey()
    }

    func loadAPIKey() throws -> String? {
        loadCount += 1
        return apiKey
    }

    func loadAPIKey(forProfileID _: String) throws -> String? {
        loadCount += 1
        return apiKey
    }

    func saveAPIKey(_ apiKey: String) throws {
        saveCount += 1
        self.apiKey = apiKey
    }

    func saveAPIKey(_ apiKey: String, forProfileID _: String) throws {
        try saveAPIKey(apiKey)
    }

    func deleteAPIKey() throws {
        apiKey = nil
    }

    func deleteAPIKey(forProfileID _: String) throws {
        try deleteAPIKey()
    }
}

@MainActor
private final class RecordingTranslatorPanelController: TranslatorPanelControlling {
    var onAction: ((TranslatorPanelAction) -> Void)?

    func show(snapshot _: TranslatorPanelSnapshot) {}
    func update(snapshot _: TranslatorPanelSnapshot) {}
    func close() {}
}
