import Charts
import SwiftUI
import MacToolsPluginKit

private struct KeyStatsContentHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct KeyStatsComponentView: View {
    @ObservedObject var controller: KeyStatsController
    let localization: PluginLocalization
    let openSettings: () -> Void
    let onContentHeightChange: (CGFloat) -> Void

    @Environment(\.pluginComponentTheme) private var theme
    @State private var hoveredKeyDate: String?
    @State private var hoveredTrackpadDate: String?

    private var today: KeyStatsDailyStats {
        controller.todayStats
    }

    private var days: [KeyStatsDailyStats] {
        controller.recentDays
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            metrics

            if controller.isTrackingEnabled, controller.monitorStatus == .inputMonitoringDenied {
                permissionHint
            } else {
                weeklyCharts
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: KeyStatsContentHeightPreferenceKey.self,
                    value: geometry.size.height
                )
            }
        }
        .onPreferenceChange(KeyStatsContentHeightPreferenceKey.self) { height in
            onContentHeightChange(height)
        }
        .background(PluginComponentCardBackground())
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "keyboard")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.dataSeries.primary)
                .frame(width: 24, height: 24)
                .background(theme.interaction.selection(theme.dataSeries.primary), in: Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(localization.string("widget.title", defaultValue: "按键统计"))
                    .font(PluginTypography.sectionTitle.font)
                    .lineLimit(1)

                Text(localization.string("widget.weekTitle", defaultValue: "近七天"))
                    .font(PluginTypography.caption.font)
                    .foregroundStyle(theme.text.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button(action: openSettings) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.text.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(localization.string("widget.openSettings", defaultValue: "打开设置"))
            .accessibilityLabel(localization.string("widget.openSettings", defaultValue: "打开设置"))
        }
    }

    private var metrics: some View {
        HStack(spacing: 8) {
            metricTile(
                icon: "keyboard",
                value: today.totalKeyPresses,
                label: localization.string("metric.keys", defaultValue: "按键"),
                tint: theme.dataSeries.primary
            )
            metricTile(
                icon: "hand.tap",
                value: today.trackpadUses,
                label: localization.string("metric.trackpad", defaultValue: "触控板"),
                tint: theme.dataSeries.secondary
            )
        }
    }

    private func metricTile(icon: String, value: Int, label: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(theme.interaction.selection(tint), in: Circle())

            VStack(alignment: .leading, spacing: 1) {
                PluginMetricValue(
                    KeyStatsFormatting.compactCount(value),
                    unit: localization.string("metric.unit.times", defaultValue: "次"),
                    isProminent: true,
                    unitColor: theme.text.secondary
                )
                .foregroundStyle(theme.text.primary)

                Text(label)
                    .font(PluginTypography.detail.font)
                    .foregroundStyle(theme.text.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            theme.surfaces.nested,
            in: RoundedRectangle(
                cornerRadius: PluginPanelWidgetLayoutMetrics.cardCornerRadius,
                style: .continuous
            )
        )
    }

    private var weeklyCharts: some View {
        VStack(alignment: .leading, spacing: 8) {
            miniChart(
                title: localization.string("chart.keys.title", defaultValue: "按键趋势"),
                value: \.totalKeyPresses,
                color: theme.dataSeries.primary,
                hoveredDate: $hoveredKeyDate
            )
            miniChart(
                title: localization.string("chart.trackpad.title", defaultValue: "触控板趋势"),
                value: \.trackpadUses,
                color: theme.dataSeries.secondary,
                hoveredDate: $hoveredTrackpadDate
            )
        }
    }

    private func miniChart(
        title: String,
        value: KeyPath<KeyStatsDailyStats, Int>,
        color: Color,
        hoveredDate: Binding<String?>
    ) -> some View {
        let hasData = days.contains { $0[keyPath: value] > 0 }
        let hoveredDay = days.first { $0.date == hoveredDate.wrappedValue }

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                Text(title)
                    .font(PluginTypography.caption.font)
                    .foregroundStyle(theme.text.secondary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if let hoveredDay,
                   let hoveredDateValue = date(from: hoveredDay.date) {
                    Text(
                        "\(KeyStatsFormatting.compactMonthDay(hoveredDateValue)) "
                            + KeyStatsFormatting.decimal(hoveredDay[keyPath: value])
                    )
                    .font(PluginTypography.caption.font.monospacedDigit())
                    .foregroundStyle(theme.text.primary)
                    .lineLimit(1)
                }
            }

            ZStack {
                Chart {
                    ForEach(hasData ? days : []) { day in
                        let count = day[keyPath: value]
                        let isHovered = hoveredDate.wrappedValue == day.date

                        BarMark(
                            x: .value("Day", day.date),
                            y: .value("Count", count)
                        )
                        .foregroundStyle(color)
                        .cornerRadius(2)

                        RuleMark(x: .value("Day", day.date))
                            .foregroundStyle(color.opacity(isHovered ? 0.45 : 0))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }
                .chartXAxis {
                    AxisMarks(values: days.map(\.date)) { mark in
                        AxisValueLabel {
                            if let label = mark.as(String.self),
                               let date = date(from: label) {
                                Text(KeyStatsFormatting.compactMonthDay(date))
                                    .font(PluginTypography.caption.font)
                                    .foregroundStyle(theme.text.tertiary)
                            }
                        }
                    }
                }
                .chartYAxis(.hidden)
                .chartOverlay { proxy in
                    if hasData {
                        chartHoverOverlay(proxy: proxy, hoveredDate: hoveredDate)
                    }
                }

                if !hasData {
                    Text(localization.string("chart.empty", defaultValue: "暂无数据"))
                        .font(PluginTypography.caption.font)
                        .foregroundStyle(theme.text.tertiary)
                }
            }
            .frame(height: 54)
        }
    }

    private func chartHoverOverlay(
        proxy: ChartProxy,
        hoveredDate: Binding<String?>
    ) -> some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case let .active(location):
                        guard let plotFrame = proxy.plotFrame else {
                            return
                        }

                        let frame = geometry[plotFrame]
                        let x = location.x - frame.origin.x
                        var closest: String?
                        var closestDistance = CGFloat.infinity

                        for day in days {
                            guard let position = proxy.position(forX: day.date) else {
                                continue
                            }
                            let distance = abs(position - x)
                            if distance < closestDistance {
                                closestDistance = distance
                                closest = day.date
                            }
                        }

                        hoveredDate.wrappedValue = closest
                    case .ended:
                        hoveredDate.wrappedValue = nil
                    }
                }
        }
    }

    private var permissionHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(PluginTypography.caption.font)
                .foregroundStyle(theme.status.warning)

            Text(localization.string("status.permission", defaultValue: "需要输入监控授权"))
                .font(PluginTypography.caption.font)
                .foregroundStyle(theme.text.secondary)
                .lineLimit(2)

            Spacer(minLength: 4)

            Button(localization.string("widget.openSettings", defaultValue: "打开设置"), action: openSettings)
                .buttonStyle(.bordered)
                .controlSize(.mini)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(
            theme.interaction.subtleTint(theme.status.warning),
            in: RoundedRectangle(
                cornerRadius: PluginPanelWidgetLayoutMetrics.cardCornerRadius,
                style: .continuous
            )
        )
    }

    private func date(from dateKey: String) -> Date? {
        let components = dateKey.split(separator: "-").compactMap { Int($0) }
        guard components.count == 3 else {
            return nil
        }

        var dateComponents = DateComponents()
        dateComponents.year = components[0]
        dateComponents.month = components[1]
        dateComponents.day = components[2]
        return Calendar.autoupdatingCurrent.date(from: dateComponents)
    }
}
