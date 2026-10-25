import AppKit
import FinderSync
import Foundation
import OSLog
import SwiftUI
import MacToolsPluginKit

public final class RightClickPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        RightClickPluginProvider(context: context)
    }
}

@MainActor
private struct RightClickPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [RightClickPlugin(localization: PluginLocalization(bundle: context.resourceBundle))]
    }
}

private enum RightClickPermissionID {
    static let finderExtension = "finder-extension"
}

@MainActor
final class RightClickPlugin: MacToolsPlugin {
    var metadata: PluginMetadata {
        PluginMetadata(
            id: "right-click",
            title: localization.string("metadata.title", defaultValue: "右键工具"),
            iconName: "contextualmenu.and.cursorarrow",
            iconTint: Color(nsColor: .systemTeal),
            order: 74,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "在 Finder 右键菜单中快速新建文件/文件夹、复制路径、在终端打开、用应用打开"
            )
        )
    }

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    private let configurationFileURL: URL
    private let settingsSession: RightClickSettingsSession
    var onPersistentPreferencesChange: (() -> Void)?
    private let localization: PluginLocalization
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "RightClickPlugin"
    )
    private var activationObserver: NSObjectProtocol?

    init(localization: PluginLocalization = PluginLocalization(bundle: .main), configurationFileURL: URL = RightClickConfigurationStore.configFileURL) {
        self.localization = localization
        self.configurationFileURL = configurationFileURL
        self.settingsSession = RightClickSettingsSession(fileURL: configurationFileURL)
        self.settingsSession.onCommit = { [weak self] in self?.onPersistentPreferencesChange?() }
    }

    func activate(context _: PluginRuntimeContext) {
        RightClickConfigurationStore.setMenuEnabled(true, fileURL: configurationFileURL)

        guard activationObserver == nil else {
            return
        }

        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.onStateChange?()
            }
        }
    }

    func deactivate(reason: PluginDeactivationReason) {
        if reason.requiresStateCleanup {
            RightClickConfigurationStore.setMenuEnabled(false, fileURL: configurationFileURL)
        }

        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }

    var permissionRequirements: [PluginPermissionRequirement] {
        [
            PluginPermissionRequirement(
                id: RightClickPermissionID.finderExtension,
                kind: .finderExtension,
                title: localization.string("permission.finderExtension.title", defaultValue: "Finder 扩展"),
                description: localization.string(
                    "permission.finderExtension.description",
                    defaultValue: "在系统设置中打开 MacTools 右键工具。"
                )
            )
        ]
    }

    var settingsPage: PluginSettingsPage? {
        let session = settingsSession
        return .form(
            description: localization.string(
                "configuration.description",
                defaultValue: "选择 Finder 右键菜单显示哪些项，并管理「用应用打开」的应用列表。"
            ),
            sections: [
                PluginSettingsSection(
                    id: "directory-actions",
                    title: localization.string("settings.directory.title", defaultValue: "目录操作"),
                    systemImage: "folder",
                    presentation: .edgeToEdge
                ) { [localization, session] _ in
                    RightClickMenuSettingsView(
                        session: session,
                        localization: localization,
                        section: .directory
                    )
                },
                PluginSettingsSection(
                    id: "copy-actions",
                    title: localization.string("settings.copy.title", defaultValue: "复制菜单项"),
                    systemImage: "doc.on.doc",
                    presentation: .edgeToEdge
                ) { [localization, session] _ in
                    RightClickMenuSettingsView(
                        session: session,
                        localization: localization,
                        section: .copy
                    )
                },
                PluginSettingsSection(
                    id: "open-with",
                    title: localization.string("settings.openWith.title", defaultValue: "用应用打开"),
                    systemImage: "app.badge",
                    footer: localization.string(
                        "settings.openWith.footnote",
                        defaultValue: "扩展名留空表示对所有文件显示，多个扩展名用逗号分隔。"
                    ),
                    presentation: .edgeToEdge
                ) { [localization, session] _ in
                    RightClickMenuSettingsView(
                        session: session,
                        localization: localization,
                        section: .openWith
                    )
                }
                .headerAccessory { [localization, session] _ in
                    Button {
                        RightClickMenuSettingsView.addApp(
                            to: session,
                            localization: localization
                        )
                    } label: {
                        Label(
                            localization.string("settings.addApp.button", defaultValue: "添加"),
                            systemImage: "plus"
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            ]
        )
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        guard permissionID == RightClickPermissionID.finderExtension else {
            return PluginPermissionState(isGranted: true, footnote: nil)
        }

        let enabled = FIFinderSyncController.isExtensionEnabled
        return PluginPermissionState(
            isGranted: enabled,
            footnote: localization.string(
                "permission.finderExtension.footnote",
                defaultValue: "入口：登录项与扩展 > Finder 扩展。"
            ),
            statusText: enabled
                ? localization.string("permission.finderExtension.status.enabled", defaultValue: "已启用")
                : localization.string("permission.finderExtension.status.disabled", defaultValue: "未启用"),
            statusSystemImage: enabled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
            statusTone: enabled ? .positive : .caution
        )
    }

    func handlePermissionAction(id permissionID: String) {
        guard permissionID == RightClickPermissionID.finderExtension else {
            return
        }

        openExtensionManagementInterface()
    }

    private func openExtensionManagementInterface() {
        logger.info("Opening Finder extension management interface")
        FIFinderSyncController.showExtensionManagementInterface()
        onStateChange?()
    }
}

extension RightClickPlugin: PluginPortablePreferencesProviding, PluginPortablePreferencesRestorationReporting,
    PluginPersistentPreferencesChangeSignaling {
    private struct PortableApp: Codable {
        let id: UUID
        let name: String
        let application: PortableApplicationReference
        let fileExtensions: [String]
    }
    private struct PortablePreferences: Codable {
        let formatVersion: Int
        let newFolder: Bool
        let copyFileName: Bool
        let copyAbsolutePath: Bool
        let copyRelativePath: Bool
        let copyShellEscapedPath: Bool
        let copyFileURL: Bool
        let newFile: Bool
        let openInTerminal: Bool
        let applications: [PortableApp]
    }
    private func decodedPortable(_ data: Data) -> PortablePreferences? {
        guard data.count <= 1_024 * 1_024,
              let payload = try? JSONDecoder().decode(PortablePreferences.self, from: data), payload.formatVersion == 1,
              payload.applications.count <= 512, Set(payload.applications.map(\.id)).count == payload.applications.count,
              payload.applications.allSatisfy({ entry in
                  entry.application.isValid && !entry.name.isEmpty && entry.name.utf8.count <= 256
                      && !entry.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                      && entry.fileExtensions.count <= 64 && Set(entry.fileExtensions).count == entry.fileExtensions.count
                      && entry.fileExtensions.allSatisfy { ext in
                          !ext.isEmpty && ext.utf8.count <= 64 && ext == ext.lowercased()
                              && ext.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_")).contains($0) }
                      }
              }) else { return nil }
        return payload
    }
    func makePortablePreferencesBackup() -> Data? {
        guard let current = RightClickConfigurationStore.loadForPreferencesBackup(from: configurationFileURL),
              current.openWithApps.count <= 512 else { return nil }
        var applications: [PortableApp] = []
        for entry in current.openWithApps {
            let application: PortableApplicationReference
            if let retainedData = entry.portableApplicationReference {
                guard let retained = try? JSONDecoder().decode(PortableApplicationReference.self, from: retainedData) else { return nil }
                application = retained
            } else {
                let url = entry.appPath.hasPrefix("/") ? URL(fileURLWithPath: entry.appPath) : nil
                application = PortableApplicationReference(url: url)
            }
            applications.append(PortableApp(id: entry.id, name: entry.name, application: application, fileExtensions: entry.fileExtensions))
        }
        let payload = PortablePreferences(formatVersion: 1, newFolder: current.newFolder, copyFileName: current.copyFileName,
            copyAbsolutePath: current.copyAbsolutePath, copyRelativePath: current.copyRelativePath,
            copyShellEscapedPath: current.copyShellEscapedPath, copyFileURL: current.copyFileURL,
            newFile: current.newFile, openInTerminal: current.openInTerminal, applications: applications)
        guard let data = try? JSONEncoder().encode(payload), decodedPortable(data) != nil else { return nil }
        return data
    }
    func restorePortablePreferences(from data: Data) { _ = restorePortablePreferencesReportingResult(from: data) }
    func restorePortablePreferencesReportingResult(from data: Data) -> Bool {
        guard let payload = decodedPortable(data),
              var candidate = RightClickConfigurationStore.loadForPreferencesBackup(from: configurationFileURL) else { return false }
        let previous = candidate
        candidate.newFolder = payload.newFolder
        candidate.copyFileName = payload.copyFileName
        candidate.copyAbsolutePath = payload.copyAbsolutePath
        candidate.copyRelativePath = payload.copyRelativePath
        candidate.copyShellEscapedPath = payload.copyShellEscapedPath
        candidate.copyFileURL = payload.copyFileURL
        candidate.newFile = payload.newFile
        candidate.openInTerminal = payload.openInTerminal
        var resolved = Set<String>()
        candidate.openWithApps = payload.applications.map { incoming in
            var url = incoming.application.resolvedURL()
            if let candidateURL = url, !resolved.insert(candidateURL.path).inserted { url = nil }
            var entry = RightClickOpenWithApp(id: incoming.id, name: incoming.name, appPath: url?.path ?? "", fileExtensions: incoming.fileExtensions)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            entry.portableApplicationReference = try? encoder.encode(incoming.application)
            return entry
        }
        guard candidate == previous || RightClickConfigurationStore.save(candidate, to: configurationFileURL) else { return false }
        settingsSession.reload()
        if candidate != previous { onPersistentPreferencesChange?() }
        onStateChange?()
        return true
    }
}
