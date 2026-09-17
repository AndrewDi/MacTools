import AppKit
import SwiftUI
import MacToolsPluginKit

enum CalendarComponentLayout {
    static let contentPadding: CGFloat = 8
    static let sectionSpacing: CGFloat = 3
    static let gridSpacing: CGFloat = 6
    static let headerHeight: CGFloat = 20
    static let weekdayHeight: CGFloat = 10
    static let dayCellSize: CGFloat = 36
    static let cornerRadius: CGFloat = PluginComponentPanelLayoutMetrics.cardCornerRadius

    static let maximumAgendaListHeight: CGFloat = 256

    static func estimatedContentHeight(showsRecentAgenda: Bool, dayCount: Int, eventCount: Int) -> CGFloat {
        let monthHeight = contentPadding * 2 + headerHeight + weekdayHeight
            + sectionSpacing * 2 + dayCellSize * 6 + gridSpacing * 5
        guard showsRecentAgenda else { return monthHeight }

        // Start close to the intrinsic height until the rendered content is measured.
        let agendaHeaderHeight: CGFloat = 39
        let listHeight = eventCount > 0 ? min(CGFloat(dayCount) * 46 + CGFloat(eventCount) * 40, maximumAgendaListHeight) : 24
        return monthHeight + 1 + agendaHeaderHeight + listHeight
    }
}

private struct CalendarContentHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct CalendarComponentView: View {
    @ObservedObject private var viewModel: CalendarComponentViewModel
    @ObservedObject private var settingsStore: CalendarSettingsStore
    private let localization: PluginLocalization
    private let onContentHeightChange: (CGFloat) -> Void
    private let onRequestAccess: () -> Void
    @Environment(\.pluginComponentTheme) private var theme

    init(
        context: PluginComponentContext,
        viewModel: CalendarComponentViewModel,
        settingsStore: CalendarSettingsStore,
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        onRequestAccess: @escaping () -> Void = {},
        onContentHeightChange: @escaping (CGFloat) -> Void = { _ in }
    ) {
        self.viewModel = viewModel
        self.settingsStore = settingsStore
        self.localization = localization
        self.onContentHeightChange = onContentHeightChange
        self.onRequestAccess = onRequestAccess
    }

    var body: some View {
        VStack(spacing: 0) {
            monthContent
            if settingsStore.showsRecentAgenda && viewModel.hasAgendaContent {
                Rectangle()
                    .fill(theme.surfaces.track)
                    .frame(height: 1)
                    .padding(.horizontal, CalendarComponentLayout.contentPadding)
                recentAgenda
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(PluginComponentCardBackground(cornerRadius: CalendarComponentLayout.cornerRadius))
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: CalendarContentHeightPreferenceKey.self,
                    value: geometry.size.height
                )
            }
        }
        .onPreferenceChange(CalendarContentHeightPreferenceKey.self, perform: onContentHeightChange)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var monthContent: some View {
        VStack(spacing: CalendarComponentLayout.sectionSpacing) {
            CalendarHeaderView(
                title: viewModel.month.title,
                localization: localization,
                onPrevious: { viewModel.moveMonth(by: -1) },
                onToday: { viewModel.goToToday() },
                onNext: { viewModel.moveMonth(by: 1) }
            )

            CalendarWeekdayRow(
                symbols: viewModel.month.weekdaySymbols,
                dayCellSize: CalendarComponentLayout.dayCellSize,
                gridSpacing: CalendarComponentLayout.gridSpacing
            )

            CalendarMonthGrid(
                days: viewModel.month.days,
                dayCellSize: CalendarComponentLayout.dayCellSize,
                gridSpacing: CalendarComponentLayout.gridSpacing,
                localization: localization,
                onSelect: { viewModel.select($0) },
                onOpen: { viewModel.open($0) }
            )
        }
        .padding(CalendarComponentLayout.contentPadding)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var recentAgenda: some View {
        CalendarAgendaView(
            days: viewModel.agendaDays,
            dates: viewModel.agendaDates,
            today: viewModel.todayDay?.date ?? Date(),
            authorization: viewModel.authorization,
            errorMessage: viewModel.eventLoadingError,
            localization: localization,
            onOpenDay: { viewModel.open($0) },
            onRequestAccess: onRequestAccess,
            onRetry: { viewModel.refresh() }
        )
    }
}

private struct CalendarHeaderView: View {
    let title: String
    let localization: PluginLocalization
    let onPrevious: () -> Void
    let onToday: () -> Void
    let onNext: () -> Void
    @Environment(\.pluginComponentTheme) private var theme
    @State private var isTodayHovered = false

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.text.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)

            CalendarIconButton(
                systemName: "chevron.left",
                help: localization.string("header.previous.help", defaultValue: "上个月"),
                action: onPrevious
            )
            Button(action: onToday) {
                Text(localization.string("header.today.button", defaultValue: "今天"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isTodayHovered ? theme.text.primary : theme.text.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 4)
                    .frame(minWidth: 32, maxWidth: 48, minHeight: 20, maxHeight: 20)
                    .background(isTodayHovered ? theme.surfaces.nested : .clear,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { isTodayHovered = $0 }
            .help(localization.string("header.today.help", defaultValue: "回到今天"))
            CalendarIconButton(
                systemName: "chevron.right",
                help: localization.string("header.next.help", defaultValue: "下个月"),
                action: onNext
            )
        }
        .frame(height: CalendarComponentLayout.headerHeight)
    }
}

private struct CalendarIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @Environment(\.pluginComponentTheme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isHovered ? theme.text.primary : theme.text.secondary)
                .frame(width: 24, height: 20)
                .background(isHovered ? theme.surfaces.nested : .clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(help)
        .help(help)
    }
}

private struct CalendarWeekdayRow: View {
    let symbols: [String]
    let dayCellSize: CGFloat
    let gridSpacing: CGFloat
    @Environment(\.pluginComponentTheme) private var theme

    var body: some View {
        HStack(spacing: gridSpacing) {
            ForEach(Array(symbols.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.text.secondary)
                    .frame(width: dayCellSize)
            }
        }
        .frame(height: CalendarComponentLayout.weekdayHeight)
    }
}

private struct CalendarMonthGrid: View {
    let days: [CalendarDayModel]
    let dayCellSize: CGFloat
    let gridSpacing: CGFloat
    let localization: PluginLocalization
    let onSelect: (CalendarDayModel) -> Void
    let onOpen: (CalendarDayModel) -> Void

    @State private var hoveredDayID: String?

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.fixed(dayCellSize), spacing: gridSpacing),
            count: 7
        )
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: gridSpacing) {
            ForEach(days) { day in
                CalendarDayCell(
                    day: day,
                    isHovered: hoveredDayID == day.id,
                    localization: localization,
                    onOpen: { onOpen(day) }
                )
                .frame(width: dayCellSize, height: dayCellSize)
                .background(
                    CalendarEventPopoverPresenter(
                        title: CalendarDayPresentation.dateTitle(for: day),
                        subtitle: CalendarDayPresentation.dateSubtitle(for: day, localization: localization),
                        events: day.events,
                        localization: localization,
                        isPresented: hoveredDayID == day.id && !day.events.isEmpty
                    )
                )
                .onHover { isHovered in
                    if isHovered {
                        hoveredDayID = day.id
                        onSelect(day)
                    } else if hoveredDayID == day.id {
                        hoveredDayID = nil
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct CalendarDayCell: View {
    let day: CalendarDayModel
    let isHovered: Bool
    let localization: PluginLocalization
    let onOpen: () -> Void

    @Environment(\.pluginComponentTheme) private var theme

    var body: some View {
        Button(action: onOpen) {
            ZStack {
                VStack(spacing: 0) {
                    Text(day.dayNumber)
                        .font(.system(size: day.alternateCalendarText.isEmpty ? 15 : 14,
                                      weight: day.isToday ? .bold : .semibold, design: .rounded))
                        .foregroundStyle(primaryTextStyle)
                        .lineLimit(1)

                    if !day.alternateCalendarText.isEmpty {
                        Text(day.alternateCalendarText)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(secondaryTextStyle)
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                    }
                }
                .padding(.horizontal, 2)
                // Dots never participate in centering the date, including when no alternate calendar is shown.
                .offset(y: day.alternateCalendarText.isEmpty ? 0 : -3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                CalendarEventDots(events: day.visibleEvents)
                    .opacity(day.isInDisplayedMonth ? 1 : 0.45)
                    .padding(.bottom, 2)
            }
            .background(isHovered ? theme.surfaces.nested : .clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                if day.isToday {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(theme.dataSeries.primary, lineWidth: 1.5)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let holidayKind = day.holidayKind {
                    CalendarHolidayBadge(kind: holidayKind, localization: localization)
                        .offset(x: 2, y: -2)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var primaryTextStyle: Color {
        if day.isInDisplayedMonth {
            return day.isWeekend ? theme.text.secondary : theme.text.primary
        }

        return theme.text.tertiary
    }

    private var secondaryTextStyle: Color {
        day.isInDisplayedMonth ? theme.text.secondary : theme.text.tertiary
    }

    private var accessibilityLabel: String {
        var parts = [day.dayNumber]
        if !day.alternateCalendarText.isEmpty {
            parts.append(day.alternateCalendarText)
        }
        if day.isToday {
            parts.append(localization.string("accessibility.today", defaultValue: "今天"))
        }
        if let holidayKind = day.holidayKind {
            parts.append(CalendarDayPresentation.holidayText(for: holidayKind, localization: localization))
        }
        if !day.events.isEmpty {
            parts.append(
                localization.format(
                    "accessibility.eventCount",
                    defaultValue: "%d 个日程",
                    day.events.count
                )
            )
        }
        return parts.joined(
            separator: localization.string("list.separator.comma", defaultValue: "，")
        )
    }
}

private struct CalendarHolidayBadge: View {
    let kind: CalendarHolidayKind
    let localization: PluginLocalization
    @Environment(\.pluginComponentTheme) private var theme

    var body: some View {
        Text(kind.badgeText(localization: localization))
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(theme.text.primary)
            .frame(width: 12, height: 12)
            .background(
                Circle()
                    .fill(
                        theme.interaction.selection(
                            kind == .holiday ? theme.dataSeries.tertiary : theme.dataSeries.secondary
                        )
                    )
            )
    }
}

private struct CalendarEventDots: View {
    private static let dotSize: CGFloat = 3

    let events: [CalendarEventSummary]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(events) { event in
                Circle()
                    .fill(Color(calendarEventColor: event.color))
                    .frame(width: Self.dotSize, height: Self.dotSize)
            }
        }
        .accessibilityHidden(true)
    }
}

struct CalendarEventPopoverPresenter: NSViewRepresentable {
    let title: String
    let subtitle: String
    let events: [CalendarEventSummary]
    let localization: PluginLocalization
    let isPresented: Bool
    @Environment(\.pluginComponentTheme) private var theme

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(
            title: title,
            subtitle: subtitle,
            events: events,
            localization: localization,
            theme: theme,
            isPresented: isPresented,
            sourceView: nsView
        )
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.close()
    }

    final class Coordinator {
        private(set) var popover: NSPopover?

        @MainActor
        func update(
            title: String,
            subtitle: String,
            events: [CalendarEventSummary],
            localization: PluginLocalization,
            theme: PluginComponentTheme,
            isPresented: Bool,
            sourceView: NSView
        ) {
            guard isPresented, !events.isEmpty, sourceView.window != nil else {
                close()
                return
            }

            let popover = popover ?? makePopover()
            let content = CalendarFloatingEventPopoverContent(
                title: title,
                subtitle: subtitle,
                events: events,
                localization: localization
            )
            .foregroundStyle(theme.text.primary)
            .environment(\.pluginComponentTheme, theme)
            let controller = CalendarEventPopoverController(content: content, theme: theme)
            CalendarAppearancePreference.stored().apply(to: controller.view)
            popover.contentViewController = controller
            popover.contentSize = controller.popoverSize
            CalendarAppearancePreference.stored().apply(to: popover)

            if !popover.isShown {
                PluginPresentationSafety.prepareForWindowOrdering()
                popover.show(relativeTo: sourceView.bounds, of: sourceView, preferredEdge: .maxY)
                CalendarAppearancePreference.stored().apply(to: popover)
            }

            controller.view.layoutSubtreeIfNeeded()
            popover.contentSize = controller.popoverSize
            self.popover = popover
        }

        @MainActor
        func close() {
            popover?.performClose(nil)
            popover = nil
        }

        @MainActor
        private func makePopover() -> NSPopover {
            let popover = NSPopover()
            popover.behavior = .applicationDefined
            popover.animates = false
            popover.hasFullSizeContent = true
            return popover
        }
    }
}

private struct CalendarFloatingEventPopoverContent: View {
    let title: String
    let subtitle: String
    let events: [CalendarEventSummary]
    let localization: PluginLocalization
    @Environment(\.pluginComponentTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)

                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.text.secondary)
                        .lineLimit(1)
                }
            }

            Rectangle()
                .fill(theme.surfaces.track)
                .frame(height: 1)

            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(events.prefix(6))) { event in
                    CalendarEventRow(event: event)
                }

                if events.count > 6 {
                    Text(
                        localization.format(
                            "event.moreCount",
                            defaultValue: "还有 %d 个日程",
                            events.count - 6
                        )
                    )
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.text.secondary)
                }
            }
        }
        .padding(10)
        .frame(width: 230, alignment: .leading)
    }
}

enum CalendarDayPresentation {
    static func dateTitle(for day: CalendarDayModel) -> String {
        let formatter = DateFormatter()
        formatter.locale = PluginRuntimeLocalization.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: day.date)
    }

    static func dateSubtitle(
        for day: CalendarDayModel,
        includesOverflowCount: Bool = true,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) -> String {
        var parts: [String] = []
        if !day.alternateCalendarDateText.isEmpty {
            parts.append(day.alternateCalendarDateText)
            if !day.alternateCalendarText.isEmpty && !day.alternateCalendarDateText.contains(day.alternateCalendarText) {
                parts.append(day.alternateCalendarText)
            }
        } else if !day.alternateCalendarText.isEmpty {
            parts.append(day.alternateCalendarText)
        }
        if let holidayKind = day.holidayKind {
            parts.append(holidayText(for: holidayKind, localization: localization))
        } else if day.isWeekend {
            parts.append(localization.string("day.weekend", defaultValue: "周末"))
        }
        if includesOverflowCount && day.events.count > CalendarDayModel.maximumVisibleEvents {
            parts.append(
                localization.format(
                    "event.moreCount",
                    defaultValue: "还有 %d 个日程",
                    day.events.count - CalendarDayModel.maximumVisibleEvents
                )
            )
        }
        return parts.joined(separator: localization.string("list.separator.dot", defaultValue: " · "))
    }

    static func holidayText(
        for holidayKind: CalendarHolidayKind,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) -> String {
        switch holidayKind {
        case .holiday:
            return localization.string("day.holiday", defaultValue: "休息日")
        case .workday:
            return localization.string("day.workday", defaultValue: "调休工作日")
        }
    }
}

private struct CalendarEventRow: View {
    let event: CalendarEventSummary
    @Environment(\.pluginComponentTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color(calendarEventColor: event.color))
                .frame(width: 6, height: 6)

            Text(event.title)
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(event.timeText)
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .foregroundStyle(theme.text.secondary)
                .lineLimit(1)
        }
    }
}

private extension Color {
    init(calendarEventColor color: CalendarEventColor) {
        self.init(
            red: color.red,
            green: color.green,
            blue: color.blue,
            opacity: color.alpha
        )
    }
}
