import SwiftUI
import MacToolsPluginKit

public final class PowerStatusPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        PowerStatusPluginProvider(context: context)
    }
}

@MainActor
private struct PowerStatusPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [PowerStatusPlugin(context: context, localization: PluginLocalization(bundle: context.resourceBundle))]
    }
}

@MainActor
final class PowerStatusPlugin: MacToolsPlugin {
    var panelItems: [PluginPanelItem] {
        [
            .widget(
                id: "widget",
                initialPlacement: .dashboard,
                descriptor: descriptor,
                state: widgetState,
                content: { [weak self] context in
                    self?.makeView(context: context) ?? AnyView(EmptyView())
                }
            )
            .onVisibilityChange { [weak self] visible in
                self?.viewModel.setPanelVisible(visible)
            },
        ]
    }

    var metadata: PluginMetadata {
        PluginMetadata(
            id: "power-status",
            title: localization.string("metadata.title", defaultValue: "电源状态"),
            iconName: "bolt.circle",
            iconTint: Color(nsColor: .systemYellow),
            order: 25,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "实时查看系统功耗、电池状态和充电信息"
            )
        )
    }

    var descriptor: PluginPanelWidgetDescriptor {
        let snapshot = viewModel.snapshot
        let spanHeight = PluginPanelWidgetLayoutMetrics.default.heightSpan(
            fittingContentHeight: PowerStatusLayout.contentHeight(
                flowRowCount: PowerStatusLayout.flowRowCount(for: snapshot),
                diagramRowCount: PowerStatusLayout.flowDiagramRowCount(for: snapshot),
                capacityTileCount: PowerStatusLayout.capacityTileCount(for: snapshot),
                voltageCurrentTileCount: PowerStatusLayout.voltageCurrentTileCount(for: snapshot),
                energyAppCount: snapshot.topEnergyApps.count,
                isEnergyAppsExpanded: viewModel.isEnergyAppsExpanded,
                sensorRowCount: viewModel.sensorSnapshot.components.count,
                isSensorsExpanded: viewModel.isSensorsExpanded,
                isDataAvailable: snapshot.isDataAvailable
            )
        )
        return PluginPanelWidgetDescriptor(
            span: PluginPanelWidgetSpan(width: 4, height: spanHeight)!
        )
    }

    private let viewModel: PowerStatusViewModel
    private let localization: PluginLocalization

    init(
        context: PluginRuntimeContext,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.viewModel = PowerStatusViewModel()
        self.localization = localization
        viewModel.onSnapshotChange = { [weak self] in
            self?.onStateChange?()
        }
    }

    var onStateChange: (() -> Void)? {
        didSet {
            viewModel.onSnapshotChange = { [weak self] in
                self?.onStateChange?()
            }
        }
    }
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    var widgetState: PluginPanelWidgetState {
        PluginPanelWidgetState(
            subtitle: subtitle,
            isActive: viewModel.snapshot.isDataAvailable,
            isEnabled: true,
            isAvailable: viewModel.snapshot.isDataAvailable,
            errorMessage: nil
        )
    }

    func activate(context: PluginRuntimeContext) {
        onStateChange?()
    }

    func deactivate(reason: PluginDeactivationReason) {
        viewModel.setPanelVisible(false)
        onStateChange?()
    }

    func refresh() {
        viewModel.refresh()
        onStateChange?()
    }

    func makeView(context: PluginPanelWidgetContext) -> AnyView {
        AnyView(
            PowerStatusComponentView(
                viewModel: viewModel,
                localization: localization,
                onContentHeightChange: context.reportContentHeight
            )
        )
    }

    // MARK: - Private

    private var subtitle: String {
        guard viewModel.snapshot.isDataAvailable else { return "" }
        let power = PowerStatusValueText.wholeWatts(viewModel.snapshot.headerPowerW)
        return "\(viewModel.snapshot.powerSourceText(localization)) · \(power)"
    }
}
