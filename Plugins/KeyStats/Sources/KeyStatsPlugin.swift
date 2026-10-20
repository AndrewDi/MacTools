import AppKit
import SwiftUI
import MacToolsPluginKit

public final class KeyStatsPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        KeyStatsPluginProvider(context: context)
    }
}

@MainActor
private struct KeyStatsPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [
            KeyStatsPlugin(
                context: context,
                localization: PluginLocalization(bundle: context.resourceBundle)
            ),
        ]
    }
}

@MainActor
final class KeyStatsPlugin: MacToolsPlugin, TrackpadInputServiceConsuming, PluginSettingsPresenting {
    private enum ControlID {
        static let trackingEnabled = "tracking-enabled"
        static let openSettings = "open-settings"
        static let openInputMonitoring = "open-input-monitoring"
    }

    private enum PermissionID {
        static let inputMonitoring = "inputMonitoring"
    }

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var requestSettingsPresentation: (() -> Void)?

    let localization: PluginLocalization
    let controller: KeyStatsController
    let rowDescriptor = PluginPanelRowDescriptor(
        controlStyle: .disclosure,
        menuActionBehavior: .keepPresented
    )
    let descriptor = PluginPanelWidgetDescriptor(
        span: PluginPanelWidgetSpan(
            width: 4,
            height: PluginPanelWidgetLayoutMetrics.default.heightSpan(
                fittingContentHeight: 280
            )
        )!
    )

    private var isExpanded = false
    private var visiblePanelItemIDs: Set<String> = []

    init(
        context: PluginRuntimeContext,
        controller: KeyStatsController? = nil,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.localization = localization
        let resolvedController = controller ?? KeyStatsController(
            context: context,
            localization: localization
        )
        self.controller = resolvedController
        resolvedController.onStateChange = { [weak self] in
            self?.onStateChange?()
        }
        resolvedController.onStatisticsChange = { [weak self] in
            guard let self,
                  self.visiblePanelItemIDs.contains("control")
                    || self.visiblePanelItemIDs.contains("weekly")
            else {
                return
            }
            self.onStateChange?()
        }
    }

    var metadata: PluginMetadata {
        PluginMetadata(
            id: KeyStatsConstants.pluginID,
            title: localization.string("metadata.title", defaultValue: "按键统计"),
            iconName: "keyboard",
            iconTint: Color(nsColor: .systemIndigo),
            order: 19,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "统计每个按键与触控板的使用次数，保留近七天数据"
            )
        )
    }

    var panelItems: [PluginPanelItem] {
        [
            .row(
                id: "control",
                initialPlacement: .featurePanel,
                descriptor: rowDescriptor,
                state: rowState,
                action: { [weak self] action in
                    self?.handleAction(action)
                }
            )
            .onVisibilityChange { [weak self] visible in
                self?.panelItemDidBecomeVisible("control", visible: visible)
            },
            .widget(
                id: "weekly",
                initialPlacement: .dashboard,
                descriptor: descriptor,
                state: widgetState,
                content: { [weak self] context in
                    self?.makeView(context: context) ?? AnyView(EmptyView())
                }
            )
            .onVisibilityChange { [weak self] visible in
                self?.panelItemDidBecomeVisible("weekly", visible: visible)
            },
        ]
    }

    var rowState: PluginPanelRowState {
        PluginPanelRowState(
            subtitle: controller.panelSubtitle,
            isOn: controller.isTrackingEnabled,
            isEnabled: true,
            isAvailable: true,
            detail: isExpanded ? panelDetail : nil,
            errorMessage: nil
        )
    }

    var widgetState: PluginPanelWidgetState {
        PluginPanelWidgetState(
            subtitle: controller.componentSubtitle,
            isActive: controller.isTrackingEnabled && controller.monitorStatus != .inputMonitoringDenied,
            isEnabled: true,
            isAvailable: true,
            errorMessage: nil
        )
    }

    var settingsPage: PluginSettingsPage? {
        .workspace(description: metadata.defaultDescription, scrolling: .host) { [controller, localization] _ in
            KeyStatsSettingsView(controller: controller, localization: localization)
        }
    }

    var permissionRequirements: [PluginPermissionRequirement] {
        [
            PluginPermissionRequirement(
                id: PermissionID.inputMonitoring,
                kind: .inputMonitoring,
                title: localization.string("permission.inputMonitoring.title", defaultValue: "输入监控"),
                description: localization.string(
                    "permission.inputMonitoring.description",
                    defaultValue: "用于统计每次按键。"
                )
            ),
        ]
    }

    func activate(context: PluginRuntimeContext) {
        controller.activate()
    }

    func deactivate(reason: PluginDeactivationReason) {
        visiblePanelItemIDs.removeAll()
        controller.deactivate()
    }

    func refresh() {
        controller.refresh()
    }

    func setTrackpadInputService(_ service: any TrackpadInputService) {
        controller.setTrackpadInputService(service)
    }

    func trackpadInputPauseDidChange(_ isPaused: Bool) {
        controller.trackpadInputPauseDidChange(isPaused)
    }

    func panelItemDidBecomeVisible(_ itemID: String, visible: Bool) {
        if visible {
            guard visiblePanelItemIDs.insert(itemID).inserted else {
                return
            }
            controller.refresh()
        } else {
            visiblePanelItemIDs.remove(itemID)
        }
    }

    func makeView(context: PluginPanelWidgetContext) -> AnyView {
        AnyView(
            KeyStatsComponentView(
                controller: controller,
                localization: localization,
                openSettings: { [weak self] in
                    self?.requestSettingsPresentation?()
                },
                onContentHeightChange: context.reportContentHeight
            )
        )
    }

    func handleAction(_ action: PluginPanelAction) {
        switch action {
        case let .setSwitch(isEnabled):
            controller.setTrackingEnabled(isEnabled)
        case let .setDisclosureExpanded(expanded):
            isExpanded = expanded
            onStateChange?()
        case let .invokeAction(controlID):
            handleInvoke(controlID: controlID)
        case .setSelection, .setNavigationSelection,
             .clearNavigationSelection, .setDate, .setSlider:
            break
        }
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        guard permissionID == PermissionID.inputMonitoring else {
            return PluginPermissionState(isGranted: true, footnote: nil)
        }

        return PluginPermissionState(
            isGranted: CGPreflightListenEventAccess(),
            footnote: controller.inputMonitoringFootnote
        )
    }

    func handlePermissionAction(id: String) {
        guard id == PermissionID.inputMonitoring else {
            return
        }
        controller.openInputMonitoringSettings()
    }

    private var panelDetail: PluginPanelDetail {
        var controls: [PluginPanelControl] = [
            PluginPanelControl(
                id: ControlID.trackingEnabled,
                kind: .switchRow,
                options: [],
                selectedOptionID: nil,
                dateValue: nil,
                minimumDate: nil,
                displayedComponents: nil,
                datePickerStyle: nil,
                sectionTitle: nil,
                actionTitle: localization.string("settings.tracking.title", defaultValue: "启用统计"),
                actionIconSystemName: "keyboard",
                isEnabled: true
            ),
            PluginPanelControl(
                id: ControlID.openSettings,
                kind: .actionRow,
                options: [],
                selectedOptionID: nil,
                dateValue: nil,
                minimumDate: nil,
                displayedComponents: nil,
                datePickerStyle: nil,
                sectionTitle: nil,
                actionTitle: localization.string("panel.openSettings", defaultValue: "打开统计详情"),
                actionIconSystemName: "chart.bar.xaxis",
                isEnabled: true
            ),
        ]

        if controller.monitorStatus == .inputMonitoringDenied, controller.isTrackingEnabled {
            controls.append(
                PluginPanelControl(
                    id: ControlID.openInputMonitoring,
                    kind: .actionRow,
                    options: [],
                    selectedOptionID: nil,
                    dateValue: nil,
                    minimumDate: nil,
                    displayedComponents: nil,
                    datePickerStyle: nil,
                    sectionTitle: nil,
                    actionTitle: localization.string(
                        "action.openInputMonitoring",
                        defaultValue: "打开输入监控设置"
                    ),
                    actionIconSystemName: "keyboard.badge.eye",
                    isEnabled: true
                )
            )
        }

        return PluginPanelDetail(primaryControls: controls, secondaryPanel: nil)
    }

    private func handleInvoke(controlID: String) {
        switch controlID {
        case ControlID.openSettings:
            requestSettingsPresentation?()
        case ControlID.openInputMonitoring:
            controller.openInputMonitoringSettings()
        default:
            break
        }
    }
}
