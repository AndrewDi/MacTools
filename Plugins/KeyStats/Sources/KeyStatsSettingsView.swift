import Charts
import SwiftUI
import MacToolsPluginKit

struct KeyStatsSettingsView: View {
    @ObservedObject var controller: KeyStatsController
    let localization: PluginLocalization

    @State private var showsResetConfirmation = false

    private var today: KeyStatsDailyStats {
        controller.todayStats
    }

    private var days: [KeyStatsDailyStats] {
        controller.recentDays
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            overviewCard
            historyCard
            keysCard
            footerCard
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var overviewCard: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                Label(
                    localization.string("settings.tracking.title", defaultValue: "启用统计"),
                    systemImage: "keyboard"
                )
                .font(PluginSettingsTheme.Typography.sectionTitle)
                .foregroundStyle(.secondary)

                Spacer(minLength: PluginSettingsTheme.Spacing.controlCluster)

                Toggle(
                    "",
                    isOn: Binding(
                        get: { controller.isTrackingEnabled },
                        set: { controller.setTrackingEnabled($0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(
                    localization.string("settings.tracking.title", defaultValue: "启用统计")
                )
            }

            HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                metricTile(
                    icon: "keyboard",
                    value: today.totalKeyPresses,
                    label: localization.string("metric.keyPresses", defaultValue: "按键次数"),
                    tint: .accentColor
                )
                metricTile(
                    icon: "hand.tap",
                    value: today.trackpadUses,
                    label: localization.string("metric.trackpadUses", defaultValue: "触控板次数"),
                    tint: Color(nsColor: .systemTeal)
                )
            }

            statusRow

            Text(
                localization.string(
                    "settings.tracking.description",
                    defaultValue: "统计每个按键和触控板使用次数，数据只保存在本机。"
                )
            )
            .font(PluginSettingsTheme.Typography.rowDescription)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if let trackpadFootnote = controller.trackpadFootnote {
                Label(trackpadFootnote, systemImage: "exclamationmark.triangle")
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(PluginSettingsTheme.Spacing.cardContent)
        .pluginSettingsCardBackground()
    }

    private func metricTile(
        icon: String,
        value: Int,
        label: String,
        tint: Color
    ) -> some View {
        HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
            Image(systemName: icon)
                .font(PluginSettingsTheme.Typography.rowIcon)
                .foregroundStyle(tint)
                .frame(width: PluginSettingsTheme.Size.metricIcon, height: PluginSettingsTheme.Size.metricIcon)
                .background(tint.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                PluginMetricValue(
                    KeyStatsFormatting.decimal(value),
                    unit: localization.string("metric.unit.times", defaultValue: "次"),
                    isProminent: true
                )

                Text(label)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
        .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)
        .background(
            PluginSettingsTheme.Palette.recessedControlBackground,
            in: RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.card, style: .continuous)
        )
    }

    @ViewBuilder
    private var statusRow: some View {
        switch (controller.isTrackingEnabled, controller.monitorStatus) {
        case (false, _):
            statusLabel(
                text: localization.string("status.paused", defaultValue: "已暂停统计"),
                systemImage: "pause.circle",
                color: .secondary
            )
        case (true, .inputMonitoringDenied):
            HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                statusLabel(
                    text: localization.string("status.permission", defaultValue: "需要输入监控授权"),
                    systemImage: "exclamationmark.triangle.fill",
                    color: Color(nsColor: .systemOrange)
                )

                Button(localization.string("action.openSystemSettings", defaultValue: "打开系统设置")) {
                    controller.openInputMonitoringSettings()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        case (true, .idle):
            statusLabel(
                text: localization.string("status.idle", defaultValue: "尚未开始统计"),
                systemImage: "circle.dashed",
                color: .secondary
            )
        case (true, .running):
            statusLabel(
                text: localization.string("status.running", defaultValue: "统计中"),
                systemImage: "checkmark.circle.fill",
                color: Color(nsColor: .systemGreen)
            )
        }
    }

    private func statusLabel(text: String, systemImage: String, color: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(PluginSettingsTheme.Typography.secondaryLabel)
            .foregroundStyle(color)
    }

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            Label(
                localization.string("settings.history.title", defaultValue: "近七天"),
                systemImage: "chart.bar.xaxis"
            )
            .font(PluginSettingsTheme.Typography.sectionTitle)
            .foregroundStyle(.secondary)

            historyChart(
                title: localization.string("chart.keys.title", defaultValue: "按键趋势"),
                value: \.totalKeyPresses,
                color: .accentColor
            )

            historyChart(
                title: localization.string("chart.trackpad.title", defaultValue: "触控板趋势"),
                value: \.trackpadUses,
                color: Color(nsColor: .systemTeal)
            )
        }
        .padding(PluginSettingsTheme.Spacing.cardContent)
        .pluginSettingsCardBackground()
    }

    private func historyChart(
        title: String,
        value: KeyPath<KeyStatsDailyStats, Int>,
        color: Color
    ) -> some View {
        let hasData = days.contains { $0[keyPath: value] > 0 }

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                Text(title)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
            }

            ZStack {
                Chart {
                    ForEach(hasData ? days : []) { day in
                        BarMark(
                            x: .value("Day", day.date),
                            y: .value("Count", day[keyPath: value])
                        )
                        .foregroundStyle(color)
                        .cornerRadius(2)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { mark in
                        AxisGridLine()
                            .foregroundStyle(.quaternary)
                        AxisValueLabel {
                            if let count = mark.as(Double.self) {
                                Text(KeyStatsFormatting.compactCount(Int(count)))
                                    .font(PluginSettingsTheme.Typography.rowDescription)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: days.map(\.date)) { mark in
                        AxisValueLabel {
                            if let label = mark.as(String.self) {
                                Text(KeyStatsFormatting.monthDay(date(from: label)))
                                    .font(PluginSettingsTheme.Typography.rowDescription)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if !hasData {
                    Text(localization.string("chart.empty", defaultValue: "暂无数据"))
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(height: 120)
        }
    }

    private var keysCard: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                Label(
                    localization.string("settings.keys.title", defaultValue: "今日按键"),
                    systemImage: "square.grid.3x3"
                )
                .font(PluginSettingsTheme.Typography.sectionTitle)
                .foregroundStyle(.secondary)

                Spacer(minLength: PluginSettingsTheme.Spacing.controlCluster)

                Text(
                    localization.format(
                        "settings.keys.hint",
                        defaultValue: "共 %@ 个按键",
                        KeyStatsFormatting.decimal(today.sortedKeys.count)
                    )
                )
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
            }

            if today.sortedKeys.isEmpty {
                Text(
                    localization.string(
                        "settings.keys.empty",
                        defaultValue: "开始使用键盘后，这里会显示每个按键的次数。"
                    )
                )
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            } else {
                keyCloud
            }

            Text(
                localization.string(
                    "settings.trackpad.hint",
                    defaultValue: "触控板按每次手指接触计数。"
                )
            )
            .font(PluginSettingsTheme.Typography.rowDescription)
            .foregroundStyle(.tertiary)
        }
        .padding(PluginSettingsTheme.Spacing.cardContent)
        .pluginSettingsCardBackground()
    }

    private var keyCloud: some View {
        let keys = today.sortedKeys
        let maxCount = max(keys.first?.count ?? 1, 1)

        return LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 78), spacing: 8)],
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(keys, id: \.name) { key in
                let ratio = Double(key.count) / Double(maxCount)

                VStack(spacing: 3) {
                    Text(key.name)
                        .font(PluginSettingsTheme.Typography.rowTitle)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)

                    Text(KeyStatsFormatting.decimal(key.count))
                        .font(PluginSettingsTheme.Typography.rowDescription.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(
                    Color.accentColor.opacity(0.06 + 0.20 * ratio),
                    in: RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.control, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.control, style: .continuous)
                        .strokeBorder(PluginSettingsTheme.Palette.cardBorder, lineWidth: PluginSettingsTheme.Stroke.hairline)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(key.name)
                .accessibilityValue(KeyStatsFormatting.decimal(key.count))
            }
        }
    }

    private var footerCard: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
            Label(
                localization.string(
                    "settings.retention",
                    defaultValue: "数据只保存在本机，最多保留七天。"
                ),
                systemImage: "lock"
            )
            .font(PluginSettingsTheme.Typography.rowDescription)
            .foregroundStyle(.secondary)

            Spacer(minLength: PluginSettingsTheme.Spacing.controlCluster)

            Button(
                localization.string("settings.reset.title", defaultValue: "清空今日统计"),
                role: .destructive
            ) {
                showsResetConfirmation = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(PluginSettingsTheme.Spacing.cardContent)
        .pluginSettingsCardBackground()
        .alert(
            localization.string("settings.reset.confirmTitle", defaultValue: "清空今日统计？"),
            isPresented: $showsResetConfirmation
        ) {
            Button(
                localization.string("settings.reset.cancelButton", defaultValue: "取消"),
                role: .cancel
            ) {}
            Button(
                localization.string("settings.reset.confirmButton", defaultValue: "清空"),
                role: .destructive
            ) {
                controller.resetToday()
            }
        } message: {
            Text(
                localization.string(
                    "settings.reset.confirmMessage",
                    defaultValue: "今天的按键和触控板记录将被清除，且无法恢复。"
                )
            )
        }
    }

    private func date(from dateKey: String) -> Date {
        let components = dateKey.split(separator: "-").compactMap { Int($0) }
        guard components.count == 3 else {
            return Date()
        }

        var dateComponents = DateComponents()
        dateComponents.year = components[0]
        dateComponents.month = components[1]
        dateComponents.day = components[2]
        return Calendar.autoupdatingCurrent.date(from: dateComponents) ?? Date()
    }
}
