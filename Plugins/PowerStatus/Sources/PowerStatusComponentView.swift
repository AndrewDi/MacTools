import SwiftUI
import MacToolsPluginKit

struct PowerStatusComponentView: View {
    @ObservedObject var viewModel: PowerStatusViewModel
    let localization: PluginLocalization
    var onContentHeightChange: (CGFloat) -> Void = { _ in }
    @Environment(\.pluginComponentTheme) private var theme

    var body: some View {
        PluginObservedContent(viewModel) { _ in
            content
        }
    }

    private var content: some View {
        card
            .fixedSize(horizontal: false, vertical: true)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: PowerStatusContentHeightPreferenceKey.self,
                        value: geometry.size.height
                    )
                }
            }
            .onPreferenceChange(PowerStatusContentHeightPreferenceKey.self) { height in
                onContentHeightChange(height)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var card: some View {
        Group {
            if !viewModel.snapshot.isDataAvailable {
                emptyState
            } else {
                mainContent
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bolt.slash.circle")
                .font(.system(size: 24, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(theme.text.secondary)

            Text(localization.string("empty.title", defaultValue: "暂无电源数据"))
                .font(PluginTypography.sectionTitle.font)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text(localization.string("empty.subtitle", defaultValue: "无法读取电池信息，请确认设备支持。"))
                .font(PluginTypography.detail.font)
                .foregroundStyle(theme.text.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(PluginComponentCardBackground(cornerRadius: PowerStatusLayout.cornerRadius))
    }

    // MARK: - Main content

    private var mainContent: some View {
        VStack(spacing: 0) {
            // Header: power source + main wattage
            headerSection

            // Animated power flow diagram
            flowDiagramSection

            // Power flow metrics
            powerFlowSection

            // Battery info
            batterySection
        }
        .padding(.vertical, PowerStatusLayout.cardVerticalPadding)
        .frame(maxWidth: .infinity)
        .background(PluginComponentCardBackground(cornerRadius: PowerStatusLayout.cornerRadius))
    }

    // MARK: - Power flow diagram

    private var flowDiagramSection: some View {
        PowerFlowDiagramSection(
            snapshot: viewModel.snapshot,
            localization: localization
        )
        .padding(.horizontal, PowerStatusLayout.horizontalPadding)
        .padding(.bottom, PowerStatusLayout.section)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: headerIconName)
                .font(.system(size: 14, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(headerIconTint)

            Text(viewModel.snapshot.powerSourceDescription)
                .font(PluginTypography.detail.font.weight(.medium))
                .foregroundStyle(theme.text.primary)
                .lineLimit(1)

            Spacer(minLength: 4)

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(String(format: "%.0f", viewModel.snapshot.headerPowerW))
                    .font(PluginTypography.sectionTitle.font.weight(.bold))
                    .foregroundStyle(theme.text.primary)
                    .monospacedDigit()
                Text("W")
                    .font(PluginTypography.caption.font)
                    .foregroundStyle(theme.text.secondary)
            }
        }
        .padding(.horizontal, PowerStatusLayout.horizontalPadding)
        .padding(.bottom, PowerStatusLayout.sectionHeaderContent)
    }

    private var headerIconName: String {
        switch viewModel.snapshot.flowState {
        case .onAC, .idle:
            return "powerplug.fill"
        case .charging:
            return "bolt.fill"
        case .discharging, .supplementalDischarge:
            return "battery.50percent"
        }
    }

    private var headerIconTint: Color {
        switch viewModel.snapshot.flowState {
        case .onAC, .idle:
            return theme.status.informational
        case .charging:
            return theme.status.success
        case .discharging, .supplementalDischarge:
            return theme.status.warning
        }
    }

    // MARK: - Power flow

    private var powerFlowSection: some View {
        VStack(spacing: PowerStatusLayout.rowVertical) {
            PowerStatusMetricRow(
                icon: "cpu",
                iconTint: theme.status.informational,
                title: localization.string("metric.systemPower", defaultValue: "系统功耗"),
                value: String(format: "%.1f W", viewModel.snapshot.systemPowerW),
                valueTint: theme.text.primary
            )

            PowerStatusMetricRow(
                icon: "powerplug.fill",
                iconTint: theme.status.informational,
                title: localization.string("metric.acInput", defaultValue: "交流输入"),
                value: String(format: "%.1f W", viewModel.snapshot.acInputW),
                valueTint: viewModel.snapshot.acInputW > 0 ? theme.text.primary : theme.text.tertiary
            )

            if viewModel.snapshot.batteryChargeRateW > 0 {
                PowerStatusMetricRow(
                    icon: "arrow.down.right.circle.fill",
                    iconTint: theme.status.success,
                    title: localization.string("metric.batteryCharging", defaultValue: "电池充电"),
                    value: String(format: "%.1f W", viewModel.snapshot.batteryChargeRateW),
                    valueTint: theme.status.success
                )
            }

            if viewModel.snapshot.batteryDischargeRateW > 0 {
                PowerStatusMetricRow(
                    icon: "arrow.up.right.circle.fill",
                    iconTint: theme.status.warning,
                    title: localization.string("metric.batteryDischarging", defaultValue: "电池放电"),
                    value: String(format: "%.1f W", viewModel.snapshot.batteryDischargeRateW),
                    valueTint: theme.status.warning
                )
            }

            if viewModel.snapshot.acAdapterWattage > 0 {
                PowerStatusMetricRow(
                    icon: "bolt.horizontal.circle",
                    iconTint: theme.text.secondary,
                    title: localization.string("metric.adapter", defaultValue: "适配器"),
                    value: "\(viewModel.snapshot.acAdapterWattage) W",
                    valueTint: theme.text.secondary
                )
            }
        }
        .padding(.horizontal, PowerStatusLayout.horizontalPadding)
        .padding(.bottom, PowerStatusLayout.section)
    }

    // MARK: - Battery section

    private var batterySection: some View {
        VStack(spacing: PowerStatusLayout.rowVertical) {
            // Battery level bar
            batteryLevelBar

            // Battery metrics grid
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: PowerStatusLayout.rowVertical) {
                if let health = viewModel.snapshot.healthText {
                    PowerStatusMiniMetric(
                        icon: "heart.fill",
                        iconTint: theme.status.success,
                        title: localization.string("metric.health", defaultValue: "健康度"),
                        value: health
                    )
                }

                if let temp = viewModel.snapshot.temperatureText {
                    PowerStatusMiniMetric(
                        icon: "thermometer.medium",
                        iconTint: tempTint,
                        title: localization.string("metric.temperature", defaultValue: "温度"),
                        value: temp
                    )
                }

                if let cycles = viewModel.snapshot.cycleCount {
                    PowerStatusMiniMetric(
                        icon: "arrow.triangle.2.circlepath",
                        iconTint: theme.text.secondary,
                        title: localization.string("metric.cycles", defaultValue: "循环次数"),
                        value: "\(cycles)"
                    )
                }

                if let timeText = viewModel.snapshot.estimatedTimeRemainingText {
                    PowerStatusMiniMetric(
                        icon: "clock",
                        iconTint: theme.status.informational,
                        title: viewModel.snapshot.estimatedTimeLabel,
                        value: timeText,
                        help: viewModel.snapshot.estimatedTimeIsComputed
                            ? localization.string(
                                "metric.timeEstimate.help",
                                defaultValue: "基于剩余电量与近期平均功耗估算"
                            )
                            : nil
                    )
                }
            }
        }
        .padding(.horizontal, PowerStatusLayout.horizontalPadding)
    }

    private var batteryLevelBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: batteryIconName)
                    .font(.system(size: 12, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(batteryIconTint)

                Text(localization.string("metric.battery", defaultValue: "电池"))
                    .font(PluginTypography.caption.font)
                    .foregroundStyle(theme.text.secondary)

                Spacer()

                Text("\(viewModel.snapshot.batteryPercent)%")
                    .font(PluginTypography.detail.font.weight(.semibold))
                    .foregroundStyle(batteryTint)
                    .monospacedDigit()
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(theme.surfaces.track)
                        .frame(height: 6)

                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(batteryTint)
                        .frame(width: max(0, geo.size.width * CGFloat(viewModel.snapshot.batteryPercent) / 100), height: 6)
                }
            }
            .frame(height: 6)
        }
    }

    private var batteryTint: Color {
        let pct = viewModel.snapshot.batteryPercent
        if pct <= 20 { return theme.status.critical }
        if pct <= 40 { return theme.status.warning }
        return theme.status.success
    }

    private var batteryIconName: String {
        if viewModel.snapshot.isCharging || viewModel.snapshot.fullyCharged {
            return "battery.100percent.bolt"
        }
        switch viewModel.snapshot.batteryPercent {
        case 76...100: return "battery.100percent"
        case 51...75: return "battery.75percent"
        case 26...50: return "battery.50percent"
        case 11...25: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    private var batteryIconTint: Color {
        if viewModel.snapshot.isCharging || viewModel.snapshot.fullyCharged {
            return theme.status.success
        }
        return batteryTint
    }

    private var tempTint: Color {
        guard let temp = viewModel.snapshot.batteryTemperatureC else { return theme.text.secondary }
        if temp >= 40 { return theme.status.critical }
        if temp >= 35 { return theme.status.warning }
        return theme.status.success
    }
}

// MARK: - Layout

enum PowerStatusLayout {
    static let cornerRadius: CGFloat = PluginPanelWidgetLayoutMetrics.cardCornerRadius
    static let horizontalPadding: CGFloat = 12
    static let cardVerticalPadding: CGFloat = 10
    static let section: CGFloat = 12
    static let sectionHeaderContent: CGFloat = 6
    static let rowVertical: CGFloat = 6

    static let headerRowHeight: CGFloat = 22
    static let metricRowHeight: CGFloat = 17
    static let batteryBarHeight: CGFloat = 26
    static let miniMetricRowHeight: CGFloat = 31
    static let emptyContentHeight: CGFloat = 122

    // Animated power-flow diagram
    static let flowRowHeight: CGFloat = 40
    static let flowRowSpacing: CGFloat = 6
    static let flowLineHeight: CGFloat = 20
    static let flowNodeSpacing: CGFloat = 8
    static let flowNodeWidth: CGFloat = 84
    /// Two diagram rows plus their spacing; the fork canvas spans both rows.
    static let forkHeight: CGFloat = flowRowHeight * 2 + flowRowSpacing

    /// Estimated intrinsic content height, used for the declared widget span.
    /// The host refines the span from the measured height reported by the view.
    static func contentHeight(
        flowRowCount: Int,
        miniMetricRowCount: Int,
        diagramRowCount: Int,
        isDataAvailable: Bool
    ) -> CGFloat {
        guard isDataAvailable else {
            return emptyContentHeight
        }

        let rows = max(flowRowCount, 1)
        let header = headerRowHeight + sectionHeaderContent
        let diagram = diagramHeight(diagramRowCount: diagramRowCount)
        let powerFlow = CGFloat(rows) * metricRowHeight
            + CGFloat(max(rows - 1, 0)) * rowVertical
            + section
        let miniRows = max(miniMetricRowCount, 1)
        let battery = batteryBarHeight + rowVertical
            + CGFloat(miniRows) * miniMetricRowHeight
            + CGFloat(max(miniRows - 1, 0)) * rowVertical
        let padding = cardVerticalPadding * 2
        return header + diagram + powerFlow + battery + padding
    }

    private static func diagramHeight(diagramRowCount: Int) -> CGFloat {
        guard diagramRowCount > 0 else { return 0 }
        return CGFloat(diagramRowCount) * flowRowHeight
            + CGFloat(max(diagramRowCount - 1, 0)) * flowRowSpacing
            + section
    }

    /// Mirrors the rows rendered by the animated power-flow diagram.
    static func flowDiagramRowCount(for snapshot: PowerStatusSnapshot) -> Int {
        guard snapshot.isDataAvailable else { return 0 }
        switch snapshot.flowState {
        case .charging, .supplementalDischarge:
            return 2
        case .onAC, .discharging, .idle:
            return 1
        }
    }

    /// Mirrors the rows rendered by `PowerStatusComponentView`.
    static func flowRowCount(for snapshot: PowerStatusSnapshot) -> Int {
        guard snapshot.isDataAvailable else { return 0 }
        var count = 2 // system power + AC input
        if snapshot.batteryChargeRateW > 0 || snapshot.batteryDischargeRateW > 0 {
            count += 1
        }
        if snapshot.acAdapterWattage > 0 {
            count += 1
        }
        return count
    }

    /// Mirrors the mini metric tiles rendered by `PowerStatusComponentView`.
    static func miniMetricRowCount(for snapshot: PowerStatusSnapshot) -> Int {
        guard snapshot.isDataAvailable else { return 0 }
        let count = (snapshot.batteryHealthPercent != nil ? 1 : 0)
            + (snapshot.batteryTemperatureC != nil ? 1 : 0)
            + (snapshot.cycleCount != nil ? 1 : 0)
            + (snapshot.estimatedTimeRemainingMinutes != nil ? 1 : 0)
        return (count + 1) / 2
    }
}

private struct PowerStatusContentHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Power flow diagram

/// Animated diagram showing how power flows between the AC adapter,
/// the system, and the battery for the current flow state.
private struct PowerFlowDiagramSection: View {
    let snapshot: PowerStatusSnapshot
    let localization: PluginLocalization

    @Environment(\.pluginComponentTheme) private var theme

    var body: some View {
        VStack(spacing: PowerStatusLayout.flowRowSpacing) {
            switch snapshot.flowState {
            case .onAC, .idle:
                flowRow(
                    source: acNode(value: snapshot.effectiveACOutputW),
                    destination: systemNode,
                    color: theme.status.informational
                )
            case .charging:
                chargingForkRow
            case .discharging:
                flowRow(
                    source: batteryNode,
                    destination: systemNode,
                    color: theme.status.warning
                )
            case .supplementalDischarge:
                supplementalMergeRow
            }
        }
    }

    private func flowRow(
        source: PowerFlowNodeModel,
        destination: PowerFlowNodeModel,
        color: Color
    ) -> some View {
        HStack(spacing: PowerStatusLayout.flowNodeSpacing) {
            PowerFlowNode(model: source)

            PowerFlowLine(color: color, powerW: source.powerW)
                .frame(height: PowerStatusLayout.flowLineHeight)

            PowerFlowNode(model: destination)
        }
    }

    private func acNode(value: Double) -> PowerFlowNodeModel {
        PowerFlowNodeModel(
            icon: "powerplug.fill",
            title: localization.string("flow.ac", defaultValue: "交流电"),
            value: Self.wattText(value),
            tint: theme.status.informational,
            powerW: value
        )
    }

    private var systemNode: PowerFlowNodeModel {
        PowerFlowNodeModel(
            icon: "desktopcomputer",
            title: localization.string("flow.system", defaultValue: "系统"),
            value: Self.wattText(snapshot.systemPowerW),
            tint: theme.text.primary,
            powerW: snapshot.systemPowerW
        )
    }

    private var batteryNode: PowerFlowNodeModel {
        PowerFlowNodeModel(
            icon: "battery.50percent",
            title: localization.string("flow.battery", defaultValue: "电池"),
            value: Self.wattText(snapshot.batteryDischargeRateW),
            tint: theme.status.warning,
            powerW: snapshot.batteryDischargeRateW
        )
    }

    private var chargingNode: PowerFlowNodeModel {
        PowerFlowNodeModel(
            icon: "battery.100percent.bolt",
            title: localization.string("flow.charging", defaultValue: "充电"),
            value: Self.wattText(snapshot.batteryChargeRateW),
            tint: theme.status.success,
            powerW: snapshot.batteryChargeRateW
        )
    }

    /// A single AC source forking into the system and the battery charger.
    private var chargingForkRow: some View {
        HStack(spacing: PowerStatusLayout.flowNodeSpacing) {
            PowerFlowNode(model: acNode(value: snapshot.effectiveACOutputW))

            PowerFlowJunctionLine(
                mode: .fork,
                trunkColor: theme.status.informational,
                trunkPowerW: snapshot.effectiveACOutputW,
                topColor: theme.status.informational,
                topPowerW: snapshot.systemPowerW,
                bottomColor: theme.status.success,
                bottomPowerW: snapshot.batteryChargeRateW
            )
            .frame(height: PowerStatusLayout.forkHeight)

            VStack(spacing: PowerStatusLayout.flowRowSpacing) {
                PowerFlowNode(model: systemNode)
                PowerFlowNode(model: chargingNode)
            }
        }
    }

    /// AC and battery sources merging into a single system feed.
    private var supplementalMergeRow: some View {
        HStack(spacing: PowerStatusLayout.flowNodeSpacing) {
            VStack(spacing: PowerStatusLayout.flowRowSpacing) {
                PowerFlowNode(model: acNode(value: snapshot.acInputW))
                PowerFlowNode(model: batteryNode)
            }

            PowerFlowJunctionLine(
                mode: .merge,
                trunkColor: theme.status.informational,
                trunkPowerW: snapshot.systemPowerW,
                topColor: theme.status.informational,
                topPowerW: snapshot.acInputW,
                bottomColor: theme.status.warning,
                bottomPowerW: snapshot.batteryDischargeRateW
            )
            .frame(height: PowerStatusLayout.forkHeight)

            PowerFlowNode(model: systemNode)
        }
    }

    private static func wattText(_ watts: Double) -> String {
        String(format: "%.1f W", max(0, watts))
    }
}

private struct PowerFlowNodeModel {
    let icon: String
    let title: String
    let value: String
    let tint: Color
    /// Watts behind this node; drives the flow line thickness.
    let powerW: Double
}

private struct PowerFlowNode: View {
    let model: PowerFlowNodeModel

    @Environment(\.pluginComponentTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: model.icon)
                .font(.system(size: 13, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(model.tint)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 0) {
                Text(model.title)
                    .font(PluginTypography.caption.font)
                    .foregroundStyle(theme.text.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text(model.value)
                    .font(PluginTypography.detail.font.weight(.semibold))
                    .foregroundStyle(theme.text.primary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(
            width: PowerStatusLayout.flowNodeWidth,
            height: PowerStatusLayout.flowRowHeight,
            alignment: .leading
        )
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(theme.surfaces.backplate)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(model.title) \(model.value)")
    }
}

/// A horizontal flow line with dashes animating toward the destination,
/// so the direction and share of power are visible at a glance.
private struct PowerFlowLine: View {
    let color: Color
    let powerW: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dashPhase: CGFloat = 0

    private static let dashPattern: [CGFloat] = [3, 5]
    private static let dashPeriod: CGFloat = 8

    var body: some View {
        Canvas { context, size in
            let midY = size.height / 2
            let endX = max(6, size.width - 9)
            var path = Path()
            path.move(to: CGPoint(x: 1, y: midY))
            path.addLine(to: CGPoint(x: endX, y: midY))

            let lineWidth = 2.5 + min(max(powerW, 0) / 60, 1) * 2

            // Base track.
            context.stroke(
                path,
                with: .color(color.opacity(0.22)),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )

            // Animated flow dashes.
            context.stroke(
                path,
                with: .color(color.opacity(0.9)),
                style: StrokeStyle(
                    lineWidth: lineWidth,
                    lineCap: .round,
                    dash: Self.dashPattern,
                    dashPhase: dashPhase
                )
            )

            // Arrow head pointing at the destination.
            var arrow = Path()
            arrow.move(to: CGPoint(x: endX - 6, y: midY - 4.5))
            arrow.addLine(to: CGPoint(x: endX + 1, y: midY))
            arrow.addLine(to: CGPoint(x: endX - 6, y: midY + 4.5))
            context.stroke(
                arrow,
                with: .color(color),
                style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
            )
        }
        .onAppear {
            guard !reduceMotion else { return }
            dashPhase = 0
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                // Decreasing the phase moves dashes toward the destination.
                dashPhase = -Self.dashPeriod
            }
        }
        .accessibilityHidden(true)
    }
}

/// A junction connector spanning two diagram rows: one trunk forking into
/// two branches, or two branches merging into one trunk. Dashes animate
/// along the flow direction on every segment.
private struct PowerFlowJunctionLine: View {
    enum Mode {
        /// Trunk on the left splits into top and bottom branches on the right.
        case fork
        /// Top and bottom branches on the left merge into a trunk on the right.
        case merge
    }

    let mode: Mode
    let trunkColor: Color
    let trunkPowerW: Double
    let topColor: Color
    let topPowerW: Double
    let bottomColor: Color
    let bottomPowerW: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dashPhase: CGFloat = 0

    private static let dashPattern: [CGFloat] = [3, 5]
    private static let dashPeriod: CGFloat = 8
    private static let cornerRadius: CGFloat = 6

    var body: some View {
        Canvas { context, size in
            let trunkY = size.height / 2
            let topY = PowerStatusLayout.flowRowHeight / 2
            let bottomY = size.height - PowerStatusLayout.flowRowHeight / 2
            let endX = max(8, size.width - 9)
            let splitX: CGFloat
            switch mode {
            case .fork:
                splitX = min(max(10, size.width * 0.35), max(10, endX - 16))
            case .merge:
                splitX = min(max(16, size.width * 0.55), max(16, endX))
            }
            let r = Self.cornerRadius

            switch mode {
            case .fork:
                var trunk = Path()
                trunk.move(to: CGPoint(x: 1, y: trunkY))
                trunk.addLine(to: CGPoint(x: splitX, y: trunkY))
                stroke(context, path: trunk, color: trunkColor, powerW: trunkPowerW)

                stroke(context, path: branch(from: .init(x: splitX, y: trunkY),
                                             to: topY, exitingRight: true, splitX: splitX, endX: endX, r: r),
                       color: topColor, powerW: topPowerW)
                stroke(context, path: branch(from: .init(x: splitX, y: trunkY),
                                             to: bottomY, exitingRight: true, splitX: splitX, endX: endX, r: r),
                       color: bottomColor, powerW: bottomPowerW)

                drawArrow(context, at: CGPoint(x: endX, y: topY), color: topColor)
                drawArrow(context, at: CGPoint(x: endX, y: bottomY), color: bottomColor)

            case .merge:
                stroke(context, path: branch(from: CGPoint(x: 1, y: topY),
                                             to: trunkY, exitingRight: false, splitX: splitX, endX: endX, r: r),
                       color: topColor, powerW: topPowerW)
                stroke(context, path: branch(from: CGPoint(x: 1, y: bottomY),
                                             to: trunkY, exitingRight: false, splitX: splitX, endX: endX, r: r),
                       color: bottomColor, powerW: bottomPowerW)

                var trunk = Path()
                trunk.move(to: CGPoint(x: splitX, y: trunkY))
                trunk.addLine(to: CGPoint(x: endX, y: trunkY))
                stroke(context, path: trunk, color: trunkColor, powerW: trunkPowerW)

                drawArrow(context, at: CGPoint(x: endX, y: trunkY), color: trunkColor)
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            dashPhase = 0
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                // Decreasing the phase moves dashes toward the destination.
                dashPhase = -Self.dashPeriod
            }
        }
        .accessibilityHidden(true)
    }

    /// Builds one branch: horizontal run, rounded corner, vertical run to the
    /// trunk line, either entering from the left or exiting to the right.
    private func branch(
        from start: CGPoint,
        to endY: CGFloat,
        exitingRight: Bool,
        splitX: CGFloat,
        endX: CGFloat,
        r: CGFloat
    ) -> Path {
        var path = Path()
        path.move(to: start)
        if exitingRight {
            path.addLine(to: CGPoint(x: splitX, y: endY + (endY < start.y ? r : -r)))
            path.addQuadCurve(
                to: CGPoint(x: splitX + r, y: endY),
                control: CGPoint(x: splitX, y: endY)
            )
            path.addLine(to: CGPoint(x: endX, y: endY))
        } else {
            let cornerX = min(max(splitX - r, start.x + r), endX - r)
            path.addLine(to: CGPoint(x: cornerX, y: start.y))
            path.addQuadCurve(
                to: CGPoint(x: cornerX + r, y: start.y + (endY > start.y ? r : -r)),
                control: CGPoint(x: cornerX + r, y: start.y)
            )
            path.addLine(to: CGPoint(x: cornerX + r, y: endY))
        }
        return path
    }

    private func stroke(_ context: GraphicsContext, path: Path, color: Color, powerW: Double) {
        let lineWidth = 2.5 + min(max(powerW, 0) / 60, 1) * 2
        context.stroke(
            path,
            with: .color(color.opacity(0.22)),
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        )
        context.stroke(
            path,
            with: .color(color.opacity(0.9)),
            style: StrokeStyle(
                lineWidth: lineWidth,
                lineCap: .round,
                lineJoin: .round,
                dash: Self.dashPattern,
                dashPhase: dashPhase
            )
        )
    }

    private func drawArrow(_ context: GraphicsContext, at tip: CGPoint, color: Color) {
        var arrow = Path()
        arrow.move(to: CGPoint(x: tip.x - 6, y: tip.y - 4.5))
        arrow.addLine(to: CGPoint(x: tip.x + 1, y: tip.y))
        arrow.addLine(to: CGPoint(x: tip.x - 6, y: tip.y + 4.5))
        context.stroke(
            arrow,
            with: .color(color),
            style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
        )
    }
}

private struct PowerStatusMetricRow: View {
    let icon: String
    let iconTint: Color
    let title: String
    let value: String
    let valueTint: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(iconTint)
                .frame(width: 18)

            Text(title)
                .font(PluginTypography.detail.font)
                .foregroundStyle(theme.text.primary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(value)
                .font(PluginTypography.detail.font.weight(.medium))
                .foregroundStyle(valueTint)
                .monospacedDigit()
                .lineLimit(1)
        }
    }

    @Environment(\.pluginComponentTheme) private var theme
}

private struct PowerStatusMiniMetric: View {
    let icon: String
    let iconTint: Color
    let title: String
    let value: String
    var help: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(iconTint)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(PluginTypography.caption.font)
                    .foregroundStyle(theme.text.secondary)
                    .lineLimit(1)

                Text(value)
                    .font(PluginTypography.detail.font.weight(.medium))
                    .foregroundStyle(theme.text.primary)
                    .monospacedDigit()
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .help(help ?? "")
    }

    @Environment(\.pluginComponentTheme) private var theme
}
