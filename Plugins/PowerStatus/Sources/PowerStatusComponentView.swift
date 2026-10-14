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

            // Power flow metrics
            powerFlowSection

            // Battery info
            batterySection
        }
        .padding(.vertical, PowerStatusLayout.cardVerticalPadding)
        .frame(maxWidth: .infinity)
        .background(PluginComponentCardBackground(cornerRadius: PowerStatusLayout.cornerRadius))
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
                        value: timeText
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

    /// Estimated intrinsic content height, used for the declared widget span.
    /// The host refines the span from the measured height reported by the view.
    static func contentHeight(
        flowRowCount: Int,
        miniMetricRowCount: Int,
        isDataAvailable: Bool
    ) -> CGFloat {
        guard isDataAvailable else {
            return emptyContentHeight
        }

        let rows = max(flowRowCount, 1)
        let header = headerRowHeight + sectionHeaderContent
        let powerFlow = CGFloat(rows) * metricRowHeight
            + CGFloat(max(rows - 1, 0)) * rowVertical
            + section
        let miniRows = max(miniMetricRowCount, 1)
        let battery = batteryBarHeight + rowVertical
            + CGFloat(miniRows) * miniMetricRowHeight
            + CGFloat(max(miniRows - 1, 0)) * rowVertical
        let padding = cardVerticalPadding * 2
        return header + powerFlow + battery + padding
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

// MARK: - Subviews

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
    }

    @Environment(\.pluginComponentTheme) private var theme
}
