import AppKit
import MacToolsPluginKit
import SwiftUI

public final class ContainerIndicatorPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        ContainerIndicatorPluginProvider(context: context)
    }
}

@MainActor
private struct ContainerIndicatorPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        let localization = PluginLocalization(bundle: context.resourceBundle)
        let controller = ContainerIndicatorController(localization: localization)
        return [ContainerIndicatorPlugin(controller: controller, localization: localization)]
    }
}

/// Panel-only entry point for Apple's `container` CLI: a single dashboard card
/// shows the container service status with start/stop controls, plus the
/// container and machine lists with their own lifecycle buttons.
@MainActor
final class ContainerIndicatorPlugin: MacToolsPlugin {
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var requestSettingsPresentation: (() -> Void)?

    let metadata: PluginMetadata
    let controller: ContainerIndicatorController
    let localization: PluginLocalization

    private var visibleItemIDs = Set<String>()

    private enum ItemID {
        static let widget = "overview"
    }

    init(controller: ContainerIndicatorController, localization: PluginLocalization) {
        self.controller = controller
        self.localization = localization
        self.metadata = PluginMetadata(
            id: "container-indicator",
            title: localization.string("metadata.title", defaultValue: "Apple Container状态"),
            iconName: "shippingbox",
            iconTint: Color(nsColor: .systemBlue),
            order: 75,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "监控并管理 container 服务、容器与虚拟机"
            )
        )
        controller.onStateChange = { [weak self] in
            self?.onStateChange?()
        }
    }

    // MARK: - Panel

    var panelItems: [PluginPanelItem] {
        [
            .widget(
                id: ItemID.widget,
                initialPlacement: .dashboard,
                descriptor: widgetDescriptor,
                state: widgetState,
                content: { [weak self] context in
                    guard let self else { return AnyView(EmptyView()) }
                    return AnyView(
                        ContainerIndicatorWidgetCard(
                            controller: controller,
                            localization: localization,
                            pluginTitle: metadata.title,
                            reportContentHeight: context.reportContentHeight
                        )
                    )
                }
            )
            .onVisibilityChange { [weak self] isVisible in
                self?.updateVisibility(of: ItemID.widget, isVisible: isVisible)
            },
        ]
    }

    private var widgetDescriptor: PluginPanelWidgetDescriptor {
        // Fallback span before the first height report; the host then resizes
        // the card from the intrinsic height reported by the widget content.
        PluginPanelWidgetDescriptor(
            span: PluginPanelWidgetSpan(
                width: 4,
                height: PluginPanelWidgetLayoutMetrics.default.heightSpan(
                    fittingContentHeight: ContainerIndicatorWidgetLayout.cardContentHeight
                )
            )!
        )
    }

    private var widgetState: PluginPanelWidgetState {
        PluginPanelWidgetState(
            subtitle: controller.statusText,
            isActive: controller.snapshot.status == .running,
            isEnabled: controller.isCommandAvailable,
            isAvailable: true,
            errorMessage: controller.lastErrorMessage
        )
    }

    private func updateVisibility(of itemID: String, isVisible: Bool) {
        if isVisible {
            let wasHidden = visibleItemIDs.isEmpty
            visibleItemIDs.insert(itemID)
            if wasHidden {
                controller.startMonitoring()
            }
        } else if visibleItemIDs.remove(itemID) != nil, visibleItemIDs.isEmpty {
            controller.stopMonitoring()
        }
    }

    // MARK: - Lifecycle

    func activate(context: PluginRuntimeContext) {
        controller.refreshNow()
    }

    func deactivate(reason: PluginDeactivationReason) {
        controller.stopMonitoring()
    }

    func refresh() {
        controller.refreshNow()
    }
}
