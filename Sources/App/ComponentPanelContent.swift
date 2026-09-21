import AppKit
import SwiftUI
import MacToolsPluginKit

struct ComponentGridPlacement: Identifiable, Equatable {
    let id: String
    let row: Int
    let column: Int
    let gridColumns: Int
    let gridSpacing: CGFloat
    let span: PluginPanelWidgetSpan
    let yOffset: CGFloat

    init(id: String, row: Int, column: Int, span: PluginPanelWidgetSpan, yOffset: CGFloat,
         gridColumns: Int = ComponentPanelLayout.columns,
         gridSpacing: CGFloat = ComponentPanelLayout.horizontalSpacing) {
        self.id = id
        self.row = row
        self.column = column
        self.gridColumns = gridColumns
        self.gridSpacing = gridSpacing
        self.span = span
        self.yOffset = yOffset
    }
}

enum ComponentPanelLayout {
    static let metrics = PluginPanelWidgetLayoutMetrics.default
    static let columns = metrics.columns
    static let cellWidth = metrics.cellWidth
    static let horizontalSpacing = metrics.horizontalSpacing
    static let originalCellHeight = metrics.originalCellHeight
    static let cellHeight = metrics.cellHeight
    static let spacing = horizontalSpacing
    static let horizontalPadding = MenuBarPanelLayout.outerPadding
    static let topPadding = MenuBarPanelLayout.contentTopPadding
    static let bottomPadding = MenuBarPanelLayout.contentBottomPadding
    static let verticalPadding = MenuBarPanelLayout.outerPadding
    static let verticalSpacing = horizontalPadding
    static let compactRowSpacing = metrics.compactRowSpacing
    static let emptyContentHeight: CGFloat = 164
    static let maximumPanelHeight = MenuBarPanelLayout.maximumPanelHeight
    static let minimumPanelHeight = MenuBarPanelLayout.minimumPanelHeight

    static var gridWidth: CGFloat {
        metrics.gridWidth
    }

    static var panelWidth: CGFloat {
        gridWidth + horizontalPadding * 2
    }

    static var contentVerticalPadding: CGFloat {
        topPadding + bottomPadding
    }

    static var scrollClipCornerRadius: CGFloat {
        MenuBarPanelLayout.cornerRadius
    }

    static func itemWidth(for span: PluginPanelWidgetSpan) -> CGFloat {
        metrics.itemWidth(for: span)
    }

    static func itemHeight(for span: PluginPanelWidgetSpan) -> CGFloat {
        metrics.itemHeight(forSpanHeight: span.height)
    }

    static func xOffset(for placement: ComponentGridPlacement) -> CGFloat {
        CGFloat(placement.column) * (gridWidth + placement.gridSpacing) / CGFloat(placement.gridColumns)
    }

    static func yOffset(for placement: ComponentGridPlacement) -> CGFloat {
        placement.yOffset
    }

    static func gridContentHeight(for placements: [ComponentGridPlacement]) -> CGFloat {
        guard let maximumBottom = placements.map({
            $0.yOffset + itemHeight(for: $0.span)
        }).max() else {
            return emptyContentHeight
        }

        return maximumBottom
    }

    static func preferredContentHeight(for items: [PluginPanelWidgetSnapshot], screen: NSScreen?) -> CGFloat {
        let rawContentHeight: CGFloat

        if items.isEmpty {
            rawContentHeight = emptyContentHeight
        } else {
            let placements = ComponentGridPlacementEngine.placements(for: items)
            rawContentHeight = gridContentHeight(for: placements)
        }

        let contentHeight = rawContentHeight + contentVerticalPadding
        let minimumHeight = items.isEmpty ? MenuBarPanelLayout.minimumContentHeight : contentHeight
        return min(
            max(contentHeight, minimumHeight),
            MenuBarPanelLayout.maximumContentHeight(for: screen)
        )
    }

    static func preferredPanelHeight(for items: [PluginPanelWidgetSnapshot], screen: NSScreen?) -> CGFloat {
        MenuBarPanelLayout.panelHeight(
            forContentHeight: preferredContentHeight(for: items, screen: screen)
        )
    }
}

enum ComponentGridPlacementEngine {
    static func placements(for items: [PluginPanelWidgetSnapshot]) -> [ComponentGridPlacement] {
        placements(for: items.map { (id: $0.id, span: $0.span) })
    }

    static func placements(for items: [(id: String, span: PluginPanelWidgetSpan)]) -> [ComponentGridPlacement] {
        // A common subdivision packs quarters and fifths together without changing
        // card widths or adding a separate row for each control style.
        let hasCompactItems = items.contains { $0.span.grid == .compact }
        let columns = hasCompactItems
            ? PluginPanelWidgetGrid.standard.rawValue * PluginPanelWidgetGrid.compact.rawValue
            : ComponentPanelLayout.columns
        let gridSpacing = hasCompactItems
            ? PluginPanelWidgetLayoutMetrics.compactSpacing : ComponentPanelLayout.horizontalSpacing
        var occupiedRows: [Int: UInt32] = [:]
        var placements: [ComponentGridPlacement] = []
        var columnBottoms = Array<ColumnBottom?>(repeating: nil, count: columns)
        var firstCandidateRows: [PluginPanelWidgetSpan: Int] = [:]

        for item in items {
            let span = item.span
            let width = span.width * columns / span.grid.rawValue
            // Occupancy only grows. Rows rejected for this span cannot become free.
            // Keep first-fit packing without scanning those rows for every copy.
            var row = firstCandidateRows[span, default: 0]

            while true {
                var didPlace = false

                for column in 0..<columns where canPlace(
                    width: width,
                    height: span.height,
                    row: row,
                    column: column,
                    columns: columns,
                    occupiedRows: occupiedRows
                ) {
                    placements.append(
                        ComponentGridPlacement(
                            id: item.id,
                            row: row,
                            column: column,
                            span: span,
                            yOffset: yOffset(
                                column: column,
                                width: width,
                                grid: span.grid,
                                columnBottoms: columnBottoms
                            ),
                            gridColumns: columns,
                            gridSpacing: gridSpacing
                        )
                    )
                    markOccupied(
                        width: width,
                        height: span.height,
                        row: row,
                        column: column,
                        occupiedRows: &occupiedRows
                    )
                    updateColumnBottoms(
                        span: span,
                        width: width,
                        column: column,
                        yOffset: placements[placements.count - 1].yOffset,
                        columnBottoms: &columnBottoms
                    )
                    didPlace = true
                    break
                }

                if didPlace {
                    firstCandidateRows[span] = row
                    break
                }

                row += 1
            }
        }

        return placements
    }

    private static func yOffset(
        column: Int,
        width: Int,
        grid: PluginPanelWidgetGrid,
        columnBottoms: [ColumnBottom?]
    ) -> CGFloat {
        let coveredColumns = column..<(column + width)
        return coveredColumns.reduce(CGFloat.zero) { offset, column in
            guard let previous = columnBottoms[column] else { return offset }
            let spacing = grid == .compact && previous.grid == .compact
                ? ComponentPanelLayout.compactRowSpacing : ComponentPanelLayout.verticalSpacing
            return max(offset, previous.height + spacing)
        }
    }

    private static func updateColumnBottoms(
        span: PluginPanelWidgetSpan,
        width: Int,
        column: Int,
        yOffset: CGFloat,
        columnBottoms: inout [ColumnBottom?]
    ) {
        let bottom = yOffset + ComponentPanelLayout.itemHeight(for: span)
        for occupiedColumn in column..<(column + width) {
            columnBottoms[occupiedColumn] = ColumnBottom(height: bottom, grid: span.grid)
        }
    }

    private static func canPlace(
        width: Int,
        height: Int,
        row: Int,
        column: Int,
        columns: Int,
        occupiedRows: [Int: UInt32]
    ) -> Bool {
        guard column + width <= columns else {
            return false
        }

        let mask = columnMask(width: width, column: column)
        for occupiedRow in row..<(row + height) {
            if occupiedRows[occupiedRow, default: 0] & mask != 0 { return false }
        }

        return true
    }

    private static func markOccupied(
        width: Int,
        height: Int,
        row: Int,
        column: Int,
        occupiedRows: inout [Int: UInt32]
    ) {
        let mask = columnMask(width: width, column: column)
        for occupiedRow in row..<(row + height) {
            occupiedRows[occupiedRow, default: 0] |= mask
        }
    }

    private static func columnMask(width: Int, column: Int) -> UInt32 {
        ((1 << width) - 1) << column
    }

    private struct ColumnBottom {
        let height: CGFloat
        let grid: PluginPanelWidgetGrid
    }
}

struct ComponentPanelContent: View {
    private enum DetailLayout {
        static let width: CGFloat = 360
        static let minimumHeight: CGFloat = 300
    }

    @StateObject private var detailCoordinator = ComponentDetailCoordinator()
    @StateObject private var layoutCache = ComponentGridLayoutCache()
    @StateObject private var secondaryPanelController = SecondaryPanelController()
    let pluginHost: PluginHost
    @EnvironmentObject private var presentation: MenuBarPanelPresentationModel
    let contentBodyHeight: CGFloat
    let isPanelVisible: Bool
    let onDismiss: () -> Void
    var panelID: String = MenuBarPanelDefinition.componentsID
    var suppliedItems: [PluginPanelWidgetSnapshot]? = nil
    var embedded = false
    var suppliedPlacements: [ComponentGridPlacement]? = nil
    var suppliedGridHeight: CGFloat? = nil
    var onInlinePresentationChange: (Bool) -> Void = { _ in }

    private var items: [PluginPanelWidgetSnapshot] { suppliedItems ?? pluginHost.componentItems }
    @Environment(\.menuBarPanelTheme) private var theme

    private var placements: [ComponentGridPlacement] {
        suppliedPlacements ?? layoutCache.placements(for: items)
    }

    var body: some View {
        let _ = presentation.revision
        ZStack(alignment: .topLeading) {
            dashboardContent
                .environment(\.pluginPresentationIsVisible,
                             isPanelVisible && !secondaryPanelController.isPresentingInline)
                .opacity(secondaryPanelController.isPresentingInline ? 0 : 1)
                .allowsHitTesting(!secondaryPanelController.isPresentingInline)

            if secondaryPanelController.isPresentingInline, let detailContent {
                ComponentDetailPanelView(
                    title: detailContent.title,
                    content: detailContent.content,
                    onDismiss: dismissDetail
                )
                .frame(
                    width: ComponentPanelLayout.gridWidth,
                    height: contentBodyHeight,
                    alignment: .topLeading
                )
            }
        }
        .frame(
            width: ComponentPanelLayout.gridWidth,
            height: contentBodyHeight,
            alignment: .topLeading
        )
        .background(
            MenuWindowAccessor { window in
                let didChangeHostWindow = secondaryPanelController.setHostWindow(
                    isPanelVisible ? window : nil
                )
                if didChangeHostWindow, isPanelVisible, detailCoordinator.state.selection != nil {
                    syncDetailPanel()
                }
            }
            .allowsHitTesting(false)
        )
        .onAppear { [detailCoordinator] in
            pluginHost.componentDetailHandlersByPanelID[panelID] = { [weak detailCoordinator] placementID, detailID in
                detailCoordinator?.toggle(placementID: placementID, detailID: detailID)
            }
            secondaryPanelController.onHostWindowDismissRequest = { [weak detailCoordinator] in
                detailCoordinator?.dismiss()
            }
        }
        .onChange(of: items.map(\.id)) { _, ids in
            if let selectedID = detailCoordinator.state.selection?.placementID, !ids.contains(selectedID) { dismissDetail() }
        }
        .onChange(of: secondaryPanelController.isPresentingInline) { _, inline in
            onInlinePresentationChange(inline)
        }
        .onChange(of: detailCoordinator.state) {
            syncDetailPanel()
        }
        .onChange(of: isPanelVisible) { _, visible in
            if visible {
                if detailCoordinator.state.selection != nil {
                    syncDetailPanel()
                }
            } else {
                dismissDetail()
                secondaryPanelController.setHostWindow(nil)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AppAppearancePreference.didChangeNotification)) { _ in
            secondaryPanelController.applyCurrentAppearance()
        }
        .onDisappear {
            onInlinePresentationChange(false)
            pluginHost.componentDetailHandlersByPanelID.removeValue(forKey: panelID)
            secondaryPanelController.onHostWindowDismissRequest = nil
            dismissDetail()
            secondaryPanelController.setHostWindow(nil)
        }
    }

    @ViewBuilder
    private var dashboardContent: some View {
        if items.isEmpty {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            if embedded {
                grid
            } else {
                ScrollView(.vertical, showsIndicators: false) { grid }
                    .background(ScrollViewScrollerVisibilityConfigurator())
                    .clipShape(RoundedRectangle(cornerRadius: ComponentPanelLayout.scrollClipCornerRadius, style: .continuous))
            }
        }
    }

    private var grid: some View {
        ComponentGridView(
            pluginHost: pluginHost, items: items, placements: placements, contentHeight: suppliedGridHeight,
            detailAnchorID: detailCoordinator.state.selection?.placementID,
            onDismiss: onDismiss, onCardFrameChange: { id, frame in
                detailCoordinator.updatePresentationFrame(id: id, frame: frame)
            }
        )
    }

    private var detailContent: PluginPanelDetailContent? {
        guard let selection = detailCoordinator.state.selection else {
            return nil
        }
        return pluginHost.componentDetailContent(
            placementID: selection.placementID,
            detailID: selection.detailID,
            dismiss: dismissDetail
        )
    }

    private func syncDetailPanel() {
        guard
            isPanelVisible,
            detailCoordinator.state.selection != nil,
            let anchorRect = detailCoordinator.state.selectedCardFrame,
            let detailContent
        else {
            secondaryPanelController.hide()
            return
        }

        let rootView = AnyView(
            ComponentDetailPanelView(
                title: detailContent.title,
                content: detailContent.content,
                onDismiss: dismissDetail
            )
            .frame(width: DetailLayout.width)
            .foregroundStyle(theme.text.primary)
            .tint(theme.accent)
            .environment(\.menuBarPanelTheme, theme)
            .environment(\.pluginComponentTheme, theme.componentTheme)
        )
        secondaryPanelController.show(
            content: rootView,
            width: DetailLayout.width,
            minimumHeight: DetailLayout.minimumHeight,
            anchorRect: anchorRect
        )
    }

    private func dismissDetail() {
        detailCoordinator.dismiss()
        secondaryPanelController.hide()
    }

    private var emptyState: some View {
        PanelPluginEmptyState(
            tab: .components,
            onInstall: {
                pluginHost.presentPluginMarketplace()
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ComponentGridView: View {
    let pluginHost: PluginHost
    @EnvironmentObject private var presentation: MenuBarPanelPresentationModel
    let items: [PluginPanelWidgetSnapshot]
    let placements: [ComponentGridPlacement]
    var contentHeight: CGFloat? = nil
    let detailAnchorID: String?
    let onDismiss: () -> Void
    let onCardFrameChange: (String, CGRect?) -> Void

    private var itemsByID: [String: PluginPanelWidgetSnapshot] {
        Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
    }

    var body: some View {
        let _ = presentation.revision
        let itemLookup = itemsByID

        let frames = placements.map { placement in
            PanelItemFrame(id: placement.id, frame: CGRect(
                x: ComponentPanelLayout.xOffset(for: placement), y: placement.yOffset,
                width: ComponentPanelLayout.itemWidth(for: placement.span),
                height: ComponentPanelLayout.itemHeight(for: placement.span)))
        }
        PanelViewportStack(frames: frames, width: ComponentPanelLayout.gridWidth,
                           height: contentHeight ?? ComponentPanelLayout.gridContentHeight(for: placements),
                           retainedIDs: Set([detailAnchorID].compactMap { $0 })) { id in
            if let item = itemLookup[id] {
                ComponentCardContainer(
                    item: item,
                    componentViewItem: pluginHost.componentViewItem(for: item.id, dismiss: onDismiss),
                    measuresDetailAnchor: id == detailAnchorID,
                    onFrameChange: { onCardFrameChange(id, $0) }
                )
            }
        }
    }
}

private struct ComponentCardContainer: View {
    let item: PluginPanelWidgetSnapshot
    let componentViewItem: PluginPanelWidgetViewItem?
    let measuresDetailAnchor: Bool
    let onFrameChange: (CGRect?) -> Void

    var body: some View {
        Group {
            if let componentViewItem {
                componentViewItem.content
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .disabled(!item.isEnabled)
        .opacity(item.isEnabled ? 1 : 0.55)
        .background {
            if measuresDetailAnchor {
                ComponentCardFrameReader(onFrameChange: onFrameChange)
            }
        }
        .onDisappear {
            if measuresDetailAnchor {
                onFrameChange(nil)
            }
        }
    }
}

@MainActor
final class ComponentDetailCoordinator: ObservableObject {
    struct Selection: Equatable {
        let placementID: String
        let detailID: String
    }

    struct State: Equatable {
        var selection: Selection?
        var selectedCardFrame: CGRect?
    }

    @Published private(set) var state = State()

    func toggle(placementID: String, detailID: String) {
        let requested = Selection(placementID: placementID, detailID: detailID)

        if state.selection == requested {
            state = State()
            return
        }

        let selectedCardFrame = state.selection?.placementID == placementID
            ? state.selectedCardFrame
            : nil
        state = State(
            selection: requested,
            selectedCardFrame: selectedCardFrame
        )
    }

    func dismiss() {
        guard state.selection != nil || state.selectedCardFrame != nil else {
            return
        }
        state = State()
    }

    func updatePresentationFrame(id: String, frame: CGRect?) {
        guard let selection = state.selection, selection.placementID == id,
              state.selectedCardFrame != frame else { return }
        state.selectedCardFrame = frame
    }

}

@MainActor
final class ComponentGridLayoutCache: ObservableObject {
    private struct LayoutItem: Equatable {
        let id: String
        let span: PluginPanelWidgetSpan
    }

    private var layoutItems: [LayoutItem] = []
    private var cachedPlacements: [ComponentGridPlacement] = []

    func placements(for items: [PluginPanelWidgetSnapshot]) -> [ComponentGridPlacement] {
        let nextLayoutItems = items.map { LayoutItem(id: $0.id, span: $0.span) }
        guard nextLayoutItems != layoutItems else {
            return cachedPlacements
        }

        let placements = ComponentGridPlacementEngine.placements(for: items)
        layoutItems = nextLayoutItems
        cachedPlacements = placements
        return placements
    }
}

private struct ComponentCardFrameReader: NSViewRepresentable {
    let onFrameChange: (CGRect?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { updateFrame(for: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { updateFrame(for: nsView) }
    }

    private func updateFrame(for view: NSView) {
        guard let window = view.window else {
            onFrameChange(nil)
            return
        }
        let rectInWindow = view.convert(view.bounds, to: nil)
        onFrameChange(window.convertToScreen(rectInWindow))
    }
}

private struct ComponentDetailPanelView: View {
    let title: String
    let content: AnyView
    let onDismiss: () -> Void
    @Environment(\.menuBarPanelTheme) private var theme
    @State private var isCloseHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.text.primary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(
                            isCloseHovered ? theme.text.primary : theme.text.secondary
                        )
                        .frame(width: 28, height: 28)
                        .background(
                            Circle().fill(isCloseHovered ? theme.surfaces.hover : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .onHover { isCloseHovered = $0 }
                .keyboardShortcut(.cancelAction)
                .help(AppL10n.settings("panelTheme.close", defaultValue: "关闭"))
                .accessibilityLabel(AppL10n.settings("panelTheme.close", defaultValue: "关闭"))
            }

            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { MenuBarPanelBackground() }
        .clipShape(
            RoundedRectangle(cornerRadius: MenuBarPanelLayout.cornerRadius, style: .continuous)
        )
    }
}
