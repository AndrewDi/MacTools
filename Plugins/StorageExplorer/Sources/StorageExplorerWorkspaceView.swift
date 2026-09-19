import AppKit
import MacToolsPluginKit
import SwiftUI

public struct StorageExplorerWorkspaceView: View {
    @ObservedObject public var controller: StorageExplorerController
    public let localization: PluginLocalization
    @State private var showsInspector = false
    @State private var showsSkippedDetails = false
    @State private var sortOrder = [KeyPathComparator(\StorageExplorerRow.bytes, order: .reverse)]

    public init(controller: StorageExplorerController,
                localization: PluginLocalization = PluginLocalization(bundle: .main)) {
        self.controller = controller
        self.localization = localization
    }

    private func text(_ key: String, _ fallback: String) -> String {
        localization.string("storageExplorer." + key, defaultValue: fallback)
    }

    public var body: some View {
        GeometryReader { geometry in
            workspace(width: geometry.size.width)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
    }

    private func workspace(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            controls
            if controller.rootItem != nil {
                StorageExplorerProgressView(
                    status: controller.status,
                    metric: controller.metric,
                    localization: localization,
                    showsDetails: $showsSkippedDetails
                )
                navigation(compact: width < 780)
                explorer(width: width)
                reviewBar
            } else if controller.isScanning {
                StorageExplorerScanningView(
                    status: controller.status,
                    metric: controller.metric,
                    scanningTitle: text("scanning", "正在扫描…"),
                    filesScannedFormat: text("filesScannedFormat", "已扫描 %d 个项目"),
                    skippedCountFormat: text("skippedCount", "跳过 %d 项")
                )
            } else {
                ContentUnavailableView(text("emptyStateTitle", "选择要分析的文件夹"), systemImage: "internaldrive",
                    description: Text(text("exploreDescription", "查看空间分布、查找大文件，审阅后移至废纸篓。")))
            }
            if let error = controller.lastErrorMessage {
                Text(error).font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.red).textSelection(.enabled)
            }
            if let success = controller.lastSuccessMessage {
                Text(success).font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
            }
        }
        .padding(PluginSettingsTheme.Spacing.section)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $controller.isConfirmingTrash) { confirmation }
        .onChange(of: sortOrder) { _, order in
            guard let first = order.first else { return }
            let key: StorageExplorerSort = first.keyPath == \StorageExplorerRow.name ? .name
                : first.keyPath == \StorageExplorerRow.kind ? .kind
                : first.keyPath == \StorageExplorerRow.modified ? .modified : .size
            controller.setSort(key, ascending: first.order == .forward)
        }
    }

    private func explorer(width: CGFloat) -> some View {
        let nodes = StorageExplorerHierarchyLayout.make(
            snapshot: controller.snapshot,
            directory: controller.currentPath ?? controller.snapshot.rootPath,
            metric: controller.metric,
            excluding: controller.basket,
            otherName: text("other", "其他")
        )
        return Group {
            if width >= 780 {
                GeometryReader { geometry in
                    HStack(spacing: 12) {
                        hierarchyTreemap(nodes: nodes)
                            .frame(width: max(420, geometry.size.width * 0.72))
                        compactList
                            .frame(maxWidth: .infinity)
                    }
                }
            } else {
                VStack(spacing: 10) {
                    hierarchyTreemap(nodes: nodes)
                    compactList.frame(maxHeight: 190)
                }
            }
        }
        .frame(minHeight: 410, maxHeight: .infinity)
        .clipped()
    }

    private func hierarchyTreemap(nodes: [StorageExplorerHierarchyNode]) -> some View {
        StorageExplorerHierarchyTreemapView(
            nodes: nodes,
            selection: $controller.selectedPath,
            emptyLabel: text("noSizedItems", "尚无可显示的大小"),
            addReviewLabel: text("addToReview", "加入审阅"),
            open: controller.drillDown,
            toggleReview: { controller.toggleSelection(path: $0.path) }
        )
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private var controls: some View {
        HStack {
            Button { controller.scanHomeFolder() } label: { Label(text("homeFolder", "个人目录"), systemImage: "house") }
            Button { controller.selectFolderAndScan() } label: { Label(text("selectFolder", "选择文件夹…"), systemImage: "folder.badge.plus") }
            Spacer()
            if controller.isScanning {
                Button(text("cancel", "取消"), role: .cancel) { controller.cancelScan() }
            } else if let root = controller.scanRootURL {
                Button { controller.startScan(at: root) } label: { Label(text("refresh", "刷新"), systemImage: "arrow.clockwise") }
                    .contextMenu {
                        Button(text("rescan", "重新扫描")) { controller.startScan(at: root, force: true) }
                    }
            }
        }
        .buttonStyle(.bordered).controlSize(.small)
        .disabled(controller.isExecutingTrash)
    }

    private func navigation(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Button { controller.navigateUp() } label: {
                    Image(systemName: "arrow.up")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(controller.navigationStack.count <= 1)
                .help(text("goUp", "返回上一级"))

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(controller.navigationStack.enumerated()), id: \.element.path) { index, item in
                            if index > 0 { Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
                            Button(item.name.isEmpty ? "/" : item.name) { controller.navigateToBreadcrumb(at: index) }
                                .buttonStyle(.borderless)
                                .help(String(format: text("openPath", "打开 %@"), item.path))
                        }
                    }
                    .font(PluginSettingsTheme.Typography.rowTitle)
                }
            }
            HStack(spacing: 8) {
                Picker(text("viewMode", "视图"), selection: $controller.mode) {
                    Text(text("browseItems", "浏览项目")).tag(StorageExplorerMode.folders)
                    Text(text("largestFiles", "大文件")).tag(StorageExplorerMode.largestFiles)
                    Text(text("fileTypes", "文件类型")).tag(StorageExplorerMode.fileTypes)
                }.pickerStyle(.menu).fixedSize()
                Picker(text("sizeMetric", "大小"), selection: $controller.metric) {
                    Text(text("logicalSize", "文件大小")).tag(StorageExplorerMetric.logical)
                    Text(text("allocatedSize", "占用空间")).tag(StorageExplorerMetric.allocated)
                }.labelsHidden().pickerStyle(.menu).fixedSize()
                Spacer(minLength: 8)
                Button { showsInspector.toggle() } label: { Image(systemName: "info.circle") }
                    .help(text("details", "详细信息"))
                    .popover(isPresented: $showsInspector) { inspector.frame(width: 300, height: 430).padding(12) }
            }.controlSize(.small)
            TextField(text("search", "搜索…"), text: $controller.searchQuery).textFieldStyle(.roundedBorder)
        }
    }

    private var compactList: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(controller.rows.prefix(80)) { row in
                    HStack(spacing: 8) {
                        Button {
                            controller.toggleSelection(path: row.item.path)
                        } label: {
                            Image(systemName: controller.basket.contains(row.id) ? "checkmark.circle.fill" : "plus.circle")
                                .foregroundStyle(controller.basket.contains(row.id) ? Color.accentColor : Color.secondary)
                        }
                        .buttonStyle(.plain)
                        .disabled(!controller.canStage(row.item))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(localizedName(row)).lineLimit(1).truncationMode(.middle)
                            Text(localizedKind(row))
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Text(row.sizeLabel)
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        if row.item.isDirectory && !row.item.isPackage {
                            Button { controller.drillDown(to: row.item) } label: {
                                Image(systemName: "chevron.right")
                            }
                            .buttonStyle(.plain)
                            .help(text("openFolder", "打开文件夹"))
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        controller.selectedPath == row.id ? Color.accentColor.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if row.item.isDirectory && !row.item.isPackage {
                            controller.drillDown(to: row.item)
                        } else {
                            controller.selectedPath = row.id
                        }
                    }
                    .draggable(row.item.path)
                }
            }
        }
        .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel(text("results", "扫描结果"))
    }

    private func localizedKind(_ row: StorageExplorerRow) -> String {
        if row.kind == "package" || row.item.isPackage {
            return text("applicationsAndPackages", "应用与软件包")
        }
        if row.item.isDirectory { return text("folders", "文件夹") }
        return row.kind.isEmpty ? text("other", "其他") : row.kind.uppercased()
    }

    private func localizedName(_ row: StorageExplorerRow) -> String {
        row.id == "type:package" ? text("applicationsAndPackages", "应用与软件包") : row.name
    }

    private var fileTable: some View {
        Table(controller.rows, selection: $controller.selectedPath, sortOrder: $sortOrder) {
            TableColumn("") { row in
                Button {
                    controller.toggleSelection(path: row.item.path)
                } label: {
                    Image(systemName: controller.basket.contains(row.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(controller.basket.contains(row.id) ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(!controller.canStage(row.item))
                .help(controller.basket.contains(row.id) ? text("removeFromReview", "移出审阅") : text("addToReview", "加入审阅"))
            }
            .width(24)
            TableColumn(text("nameColumn", "名称"), value: \.name) { row in
                HStack(spacing: 6) {
                    Image(systemName: row.item.iconSystemName).foregroundStyle(.secondary)
                    Text(localizedName(row)).lineLimit(1).truncationMode(.middle)
                    if row.item.isIncomplete { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) }
                    if controller.basket.contains(row.id) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                }
                .help(row.item.path)
            }.width(min: 140, ideal: 220)
            TableColumn(text("sizeColumn", "大小"), value: \.bytes) { row in
                Text(row.sizeLabel).monospacedDigit()
            }.width(min: 70, ideal: 90)
            TableColumn(text("proportionColumn", "占比")) { row in Text(row.percentage).monospacedDigit() }
                .width(min: 45, ideal: 55)
            TableColumn(text("kind", "类型"), value: \.kind) { row in
                Text(localizedKind(row))
            }.width(min: 60, ideal: 80)
            TableColumn(text("modified", "修改日期"), value: \.modified) { row in Text(row.dateLabel) }
                .width(min: 80, ideal: 95)
        }
        .contextMenu(forSelectionType: String.self) { paths in
            if let path = paths.first, let item = controller.rows.first(where: { $0.id == path })?.item {
                Button(text("openFolder", "打开文件夹")) { controller.drillDown(to: item) }
                    .disabled(!item.isDirectory || item.isPackage)
                Button(text("revealInFinder", "在访达中显示")) { controller.revealInFinder(path: path) }
                    .disabled(path.hasPrefix("type:"))
                Button(text("addToReview", "加入审阅")) { controller.toggleSelection(path: path) }
                    .disabled(!controller.canStage(item))
            }
        } primaryAction: { paths in
            if let path = paths.first, let item = controller.rows.first(where: { $0.id == path })?.item {
                controller.drillDown(to: item)
            }
        }
        .accessibilityLabel(text("results", "扫描结果"))
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
                Label(text("details", "详细信息"), systemImage: "info.circle")
                    .font(PluginSettingsTheme.Typography.sectionTitle).foregroundStyle(.secondary)
                if let item = controller.inspectedItem {
                    Text(item.path == "type:package" ? text("applicationsAndPackages", "应用与软件包") : item.name)
                        .font(PluginSettingsTheme.Typography.emphasizedRowTitle).textSelection(.enabled)
                    if !item.path.hasPrefix("type:") {
                        Text(item.path).font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    detail(text("logicalSize", "文件大小"), ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                    detail(text("allocatedSize", "占用空间"), ByteCountFormatter.string(fromByteCount: item.allocatedSize, countStyle: .file))
                    if item.isAccessDenied { Label(text("accessDenied", "无访问权限"), systemImage: "lock.fill").foregroundStyle(.orange) }
                    if item.isCloudPlaceholder { Label(text("cloudPlaceholder", "仅在云端"), systemImage: "icloud").foregroundStyle(.secondary) }
                    if item.isIncomplete { Text(text("incomplete", "大小尚不完整" )).foregroundStyle(.orange) }
                    Text(text("spaceNote", "占用空间不等于可释放空间；共享数据和废纸篓会影响实际可用容量。"))
                        .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                    if !item.path.hasPrefix("type:") {
                        Button(text("revealInFinder", "在访达中显示")) { controller.revealInFinder(path: item.path) }
                        Button(controller.basket.contains(item.path) ? text("removeFromReview", "移出审阅") : text("addToReview", "加入审阅")) {
                            controller.toggleSelection(path: item.path)
                        }.disabled(!controller.canStage(item))
                        if !item.isDirectory && !item.isSymlink && !item.isCloudPlaceholder {
                            StorageExplorerQuickLookView(url: item.url).frame(height: 170)
                        }
                    }
                } else {
                    Text(text("selectToInspect", "选择图块或列表项目以查看详情。"))
                        .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                }
            }.padding(.leading, 12).padding(.trailing, 4)
        }
        .buttonStyle(.bordered).controlSize(.small)
    }

    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
            Text(value).font(PluginSettingsTheme.Typography.monospacedValue)
        }
    }

    private var reviewBar: some View {
        HStack(spacing: 10) {
            Image(systemName: controller.basket.isEmpty ? "tray.and.arrow.down" : "checkmark.circle.fill")
                .foregroundStyle(controller.basket.isEmpty ? Color.secondary : Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                if controller.basket.isEmpty {
                    Text(text("dropToReview", "拖到这里以加入审阅"))
                        .font(PluginSettingsTheme.Typography.rowTitle)
                    Text(text("dropToReviewDescription", "也可以点按项目旁的加号。"))
                        .font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.secondary)
                } else {
                    Text(String(format: text("selectedItemsFormat", "已选 %d 个项目（共 %@）"), controller.basket.count,
                        ByteCountFormatter.string(fromByteCount: controller.totalSelectedBytes, countStyle: .file)))
                        .font(PluginSettingsTheme.Typography.emphasizedRowTitle).monospacedDigit()
                    Text(controller.selectedItemsForReview.prefix(3).map(\.name).joined(separator: " · "))
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Button(text("clearSelection", "取消选择")) { controller.clearSelection() }.disabled(controller.basket.isEmpty)
            Button(text("review", "审阅…")) { controller.confirmTrash() }
                .buttonStyle(.borderedProminent)
                .disabled(controller.basket.isEmpty || controller.isScanning)
        }
        .buttonStyle(.bordered).controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Color.accentColor.opacity(controller.basket.isEmpty ? 0.04 : 0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.65), lineWidth: 1.5))
        .dropDestination(for: String.self) { paths, _ in
            var accepted = false
            for path in paths where controller.snapshot.items[path] != nil {
                if !controller.basket.contains(path) {
                    controller.toggleSelection(path: path)
                    accepted = true
                }
            }
            return accepted
        } isTargeted: { _ in }
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            Label(text("confirmTrashTitle", "移至废纸篓确认"), systemImage: "trash")
                .font(PluginSettingsTheme.Typography.sectionTitle)
            Text(text("confirmTrashMessage", "所选项目将移至 macOS 废纸篓，可从废纸篓恢复。"))
            List(controller.reviewItems) { item in
                VStack(alignment: .leading) {
                    Text(item.name)
                    Text(item.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }.frame(height: 220)
            Text(String(format: text("selectedItemsFormat", "已选 %d 个项目（共 %@）"), controller.reviewItems.count,
                ByteCountFormatter.string(fromByteCount: controller.reviewItems.reduce(0) { $0 + controller.metric.bytes($1) }, countStyle: .file)))
            HStack {
                Spacer()
                Button(text("cancel", "取消"), role: .cancel) { controller.isConfirmingTrash = false }
                Button(text("moveToTrash", "移至废纸篓…"), role: .destructive) { Task { await controller.executeTrash() } }
                    .disabled(controller.isExecutingTrash)
            }
        }.padding(24).frame(width: 540)
            .interactiveDismissDisabled(controller.isExecutingTrash)
    }
}

private struct StorageExplorerProgressView: View {
    @ObservedObject var status: StorageExplorerScanStatus
    let metric: StorageExplorerMetric
    let localization: PluginLocalization
    @Binding var showsDetails: Bool
    var body: some View {
        HStack(spacing: 14) {
            Text(ByteCountFormatter.string(
                fromByteCount: metric == .logical
                    ? status.progress.bytesScanned
                    : status.progress.allocatedBytesScanned,
                countStyle: .file
            ))
                .font(PluginSettingsTheme.Typography.emphasizedRowTitle).monospacedDigit()
            Text(String(format: localization.string("storageExplorer.filesScannedFormat", defaultValue: "已扫描 %d 个项目"), status.progress.filesScanned))
            Text(String(format: "%.1f s", status.progress.elapsed)).monospacedDigit()
            if status.progress.skippedCount > 0 {
                Button {
                    showsDetails.toggle()
                } label: {
                    Label(String(format: localization.string("storageExplorer.skippedCount", defaultValue: "跳过 %d 项"), status.progress.skippedCount),
                          systemImage: "exclamationmark.circle")
                }
                .buttonStyle(.plain).foregroundStyle(.orange)
                .help(localization.string("storageExplorer.skippedDetailsHelp", defaultValue: "显示跳过项目的说明"))
                .popover(isPresented: $showsDetails) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(localization.string("storageExplorer.skippedDetailsTitle", defaultValue: "未扫描的项目"))
                            .font(.headline)
                        Text(String(format: localization.string(
                            "storageExplorer.skippedDetailsMessage",
                            defaultValue: "%d 个项目因权限、云端占位文件或文件系统边界而被跳过。显示的总大小可能偏低。"
                        ), status.progress.skippedCount))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14).frame(width: 330)
                }
            }
            Spacer()
        }
        .font(PluginSettingsTheme.Typography.rowDescription)
        .padding(.horizontal, 2)
    }
}

private struct StorageExplorerScanningView: View {
    @ObservedObject var status: StorageExplorerScanStatus
    let metric: StorageExplorerMetric
    let scanningTitle: String
    let filesScannedFormat: String
    let skippedCountFormat: String

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text(scanningTitle)
                .font(PluginSettingsTheme.Typography.sectionTitle)
            HStack(spacing: 18) {
                Text(ByteCountFormatter.string(
                    fromByteCount: metric == .logical
                        ? status.progress.bytesScanned
                        : status.progress.allocatedBytesScanned,
                    countStyle: .file
                ))
                .frame(width: 110, alignment: .trailing)
                Text(String(format: filesScannedFormat, status.progress.filesScanned))
                    .frame(width: 170, alignment: .leading)
                Text(String(format: "%.1f s", status.progress.elapsed))
                    .frame(width: 64, alignment: .trailing)
            }
            .font(PluginSettingsTheme.Typography.rowDescription)
            .monospacedDigit()
            if status.progress.skippedCount > 0 {
                Label(String(format: skippedCountFormat, status.progress.skippedCount),
                      systemImage: "exclamationmark.circle")
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.orange)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
