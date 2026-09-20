import SwiftUI

struct StorageExplorerHierarchyTreemapView: View {
    let nodes: [StorageExplorerHierarchyNode]
    @Binding var selection: String?
    let emptyLabel: String
    let addReviewLabel: String
    let unavailableReviewLabel: String
    let symlinkReviewUnavailableLabel: String
    let aggregateReviewLabel: String
    let open: (StorageItem) -> Void
    let preview: (StorageItem) -> Bool
    let toggleReview: (StorageItem) -> Void
    let canReview: (StorageItem) -> Bool

    @State private var hoveredID: String?
    @State private var hoverLocation: CGPoint?
    @State private var rectangles: [StorageExplorerHierarchyRect] = []
    @FocusState private var focusedID: String?

    var body: some View {
        GeometryReader { geometry in
            let key = LayoutKey(nodes: nodes, size: geometry.size)
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    for entry in rectangles where entry.id != hoveredID {
                        draw(entry, context: &context)
                    }
                    if let hovered = rectangles.last(where: { $0.id == hoveredID }) {
                        draw(hovered, context: &context)
                    }
                }
                .accessibilityHidden(true)

                ForEach(rectangles) { entry in
                    interactiveRegion(entry)
                }

                if let hovered = rectangles.last(where: { $0.id == hoveredID }),
                   let hoverLocation,
                   !hovered.node.isAggregate,
                   canReview(hovered.node.item) {
                    dragHotspot(for: hovered, at: hoverLocation)
                }

                if let hovered = rectangles.last(where: { $0.id == hoveredID }),
                   !hovered.node.isAggregate,
                   canReview(hovered.node.item) {
                    hoverReviewButton(for: hovered)
                }

                if rectangles.isEmpty {
                    Text(emptyLabel)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onContinuousHover { phase in
                switch phase {
                case let .active(location):
                    // Parent and child rectangles overlap by design. Resolve hover once at the
                    // container level so the deepest visible tile wins without competing events.
                    hoveredID = rectangles.last(where: { $0.rect.contains(location) })?.id
                    hoverLocation = location
                case .ended:
                    hoveredID = nil
                    hoverLocation = nil
                }
            }
            .onAppear { updateLayout(size: geometry.size) }
            .onChange(of: key) { _, _ in updateLayout(size: geometry.size) }
        }
    }

    private func interactiveRegion(_ entry: StorageExplorerHierarchyRect) -> some View {
        let inset = interactionRect(for: entry.rect)
        let reviewAvailable = !entry.node.isAggregate && canReview(entry.node.item)
        return Color.clear
            .contentShape(Rectangle())
            .frame(width: max(0, inset.width), height: max(0, inset.height))
            .onTapGesture {
                guard !entry.node.isAggregate else { return }
                if entry.node.item.isDirectory && !entry.node.item.isPackage {
                    open(entry.node.item)
                } else {
                    selection = entry.id
                }
            }
            .contextMenu {
                if !entry.node.isAggregate {
                    if reviewAvailable {
                        Button(addReviewLabel) { toggleReview(entry.node.item) }
                    } else {
                        Label(
                            reviewUnavailableLabel(for: entry.node.item),
                            systemImage: entry.node.item.isSymlink ? "link" : "exclamationmark.circle"
                        )
                    }
                }
            }
            .focusable(!entry.node.isAggregate, interactions: .activate)
            .focused($focusedID, equals: entry.id)
            .focusEffectDisabled()
            .onKeyPress(.return) {
                guard !entry.node.isAggregate else { return .ignored }
                activate(entry)
                return .handled
            }
            .onKeyPress(.space) {
                guard !entry.node.isAggregate else { return .ignored }
                return preview(entry.node.item) ? .handled : .ignored
            }
            .modifier(StorageExplorerTreemapAccessibilityModifier(
                label: entry.node.item.name,
                value: ByteCountFormatter.string(fromByteCount: entry.node.bytes, countStyle: .file),
                hint: helpText(for: entry.node) + helpSuffix(for: entry.node),
                enabled: !entry.node.isAggregate,
                reviewAvailable: reviewAvailable,
                addReviewLabel: addReviewLabel,
                activate: { activate(entry) },
                addToReview: { toggleReview(entry.node.item) }
            ))
            .help(helpText(for: entry.node) + helpSuffix(for: entry.node))
            // Keep positioning last so drag previews and hit targets use the tile's
            // local bounds instead of the full treemap coordinate space.
            .position(x: inset.midX, y: inset.midY)
    }

    /// SwiftUI centers a custom drag preview over its source view. A treemap tile can be
    /// hundreds of points wide, which made the preview appear far from a pointer near an edge.
    /// Keep a small drag source under the current pointer so the preview begins where the drag
    /// actually starts while the full tile remains the visual and keyboard interaction target.
    @ViewBuilder
    private func dragHotspot(
        for entry: StorageExplorerHierarchyRect,
        at location: CGPoint
    ) -> some View {
        let inset = interactionRect(for: entry.rect)
        let diameter: CGFloat = 36
        let width = max(0, min(diameter, inset.width))
        let height = max(0, min(diameter, inset.height))
        let halfWidth = width / 2
        let halfHeight = height / 2
        let x = min(max(location.x, inset.minX + halfWidth), inset.maxX - halfWidth)
        let y = min(max(location.y, inset.minY + halfHeight), inset.maxY - halfHeight)
        if width > 0, height > 0 {
            Color.clear
                .contentShape(Rectangle())
                .frame(width: width, height: height)
                .draggable(entry.node.item.path) {
                    StorageExplorerDragPreview(item: entry.node.item, bytes: entry.node.bytes)
                }
                .onTapGesture { activate(entry) }
                .contextMenu {
                    Button(addReviewLabel) { toggleReview(entry.node.item) }
                }
                .help(helpText(for: entry.node) + helpSuffix(for: entry.node))
                .position(x: x, y: y)
                .zIndex(9)
        }
    }

    private func activate(_ entry: StorageExplorerHierarchyRect) {
        if entry.node.item.isDirectory && !entry.node.item.isPackage {
            open(entry.node.item)
        } else {
            selection = entry.id
        }
    }

    private func hoverReviewButton(for entry: StorageExplorerHierarchyRect) -> some View {
        let inset = interactionRect(for: entry.rect)
        return Button { toggleReview(entry.node.item) } label: {
            Image(systemName: "plus.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color.accentColor)
        }
        .buttonStyle(.plain)
        .help(addReviewLabel)
        .position(
            x: min(inset.maxX - 15, inset.midX + inset.width / 2 - 15),
            y: inset.minY + 15
        )
        .opacity(inset.width > 54 && inset.height > 38 ? 1 : 0)
        .allowsHitTesting(inset.width > 54 && inset.height > 38)
        .zIndex(10)
    }

    private func draw(_ entry: StorageExplorerHierarchyRect, context: inout GraphicsContext) {
        let inset = entry.rect.insetBy(dx: entry.depth == 0 ? 1.5 : 1, dy: entry.depth == 0 ? 1.5 : 1)
        guard inset.width > 0, inset.height > 0 else { return }
        let shape = Path(roundedRect: inset, cornerRadius: entry.depth == 0 ? 6 : 4)
        let base = color(for: entry.node.colorKey)
        let brightness = max(0.5, 0.88 - Double(entry.depth) * 0.10)
        let isHovered = hoveredID == entry.id
        let isFocused = focusedID == entry.id
        let isSelected = selection == entry.id
        let hasHover = hoveredID != nil
        context.fill(shape, with: .color(base.opacity(brightness * (hasHover && !isHovered ? 0.48 : 1))))
        if entry.node.isAggregate {
            drawAggregatePattern(in: shape, bounds: inset, context: &context)
        }
        if isHovered {
            context.fill(shape, with: .color(.white.opacity(0.12)))
        }
        context.stroke(
            shape,
            with: .color(isHovered ? .white : .white.opacity(entry.depth == 0 ? 0.72 : 0.42)),
            lineWidth: isHovered ? 3.5 : 1
        )
        if isHovered {
            context.stroke(shape, with: .color(.black.opacity(0.45)), lineWidth: 1)
        }
        if isFocused || isSelected {
            context.stroke(
                shape,
                with: .color(isFocused ? Color.accentColor : .white),
                lineWidth: isFocused ? 4 : 2.5
            )
        }
        guard inset.width > 62, inset.height > 30 else { return }
        let name = Text(entry.node.item.name)
            .font(.system(size: entry.depth == 0 ? 13 : 11, weight: .semibold))
            .foregroundStyle(.white)
        context.draw(
            name,
            in: CGRect(x: inset.minX + 8, y: inset.minY + 6, width: inset.width - 16, height: 18)
        )
        if inset.height > 52 {
            context.draw(
                Text(ByteCountFormatter.string(fromByteCount: entry.node.bytes, countStyle: .file))
                    .font(.caption2).foregroundStyle(.white.opacity(0.9)),
                in: CGRect(x: inset.minX + 8, y: inset.minY + 25, width: inset.width - 16, height: 16)
            )
        }
    }

    private func drawAggregatePattern(in shape: Path, bounds: CGRect, context: inout GraphicsContext) {
        context.drawLayer { layer in
            layer.clip(to: shape)
            var stripes = Path()
            let spacing: CGFloat = 10
            var offset = -bounds.height
            while offset < bounds.width {
                stripes.move(to: CGPoint(x: bounds.minX + offset, y: bounds.maxY))
                stripes.addLine(to: CGPoint(x: bounds.minX + offset + bounds.height, y: bounds.minY))
                offset += spacing
            }
            layer.stroke(stripes, with: .color(.white.opacity(0.15)), lineWidth: 2)
        }
    }

    private func updateLayout(size: CGSize) {
        hoveredID = nil
        hoverLocation = nil
        rectangles = StorageExplorerHierarchyRectLayout.make(
            nodes: nodes,
            in: CGRect(origin: .zero, size: size)
        )
    }

    private func interactionRect(for rect: CGRect) -> CGRect {
        rect.insetBy(
            dx: min(2, max(0, rect.width / 2)),
            dy: min(2, max(0, rect.height / 2))
        )
    }

    private func color(for key: String) -> Color {
        // A muted Morandi palette keeps neighboring branches distinct without the visual
        // noise of fully saturated system colors. Rank remains meaningful: the largest
        // branches start with dusty red and progress through warm, then cool hues.
        let palette: [Color] = [
            Color(red: 0.68, green: 0.34, blue: 0.38),
            Color(red: 0.69, green: 0.46, blue: 0.37),
            Color(red: 0.64, green: 0.54, blue: 0.36),
            Color(red: 0.42, green: 0.54, blue: 0.40),
            Color(red: 0.34, green: 0.52, blue: 0.51),
            Color(red: 0.39, green: 0.48, blue: 0.61),
            Color(red: 0.48, green: 0.43, blue: 0.61),
            Color(red: 0.56, green: 0.41, blue: 0.51),
        ]
        if key.hasPrefix("size-rank:"),
           let rank = Int(key.dropFirst("size-rank:".count).prefix { $0.isNumber }) {
            return palette[min(rank, palette.count - 1)]
        }
        return .gray
    }

    private func helpText(for node: StorageExplorerHierarchyNode) -> String {
        let size = ByteCountFormatter.string(fromByteCount: node.bytes, countStyle: .file)
        return node.isAggregate ? "\(node.item.name) · \(size)" : "\(node.item.name) · \(size)\n\(node.item.path)"
    }

    private func helpSuffix(for node: StorageExplorerHierarchyNode) -> String {
        if node.isAggregate {
            return "\n" + aggregateReviewLabel
        }
        if node.item.isSymlink {
            return "\n" + symlinkReviewUnavailableLabel
        }
        if !canReview(node.item) {
            return "\n" + unavailableReviewLabel
        }
        return ""
    }

    private func reviewUnavailableLabel(for item: StorageItem) -> String {
        item.isSymlink ? symlinkReviewUnavailableLabel : unavailableReviewLabel
    }
}

private struct StorageExplorerTreemapAccessibilityModifier: ViewModifier {
    let label: String
    let value: String
    let hint: String
    let enabled: Bool
    let reviewAvailable: Bool
    let addReviewLabel: String
    let activate: () -> Void
    let addToReview: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            if reviewAvailable {
                accessible(content)
                    .accessibilityAction { activate() }
                    .accessibilityAction(named: Text(addReviewLabel)) { addToReview() }
            } else {
                accessible(content)
                    .accessibilityAction { activate() }
            }
        } else {
            accessible(content)
        }
    }

    private func accessible(_ content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(value)
            .accessibilityHint(hint)
    }
}

private struct StorageExplorerDragPreview: View {
    let item: StorageItem
    let bytes: Int64

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.iconSystemName)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct LayoutKey: Equatable {
    struct Entry: Equatable {
        let id: String
        let bytes: Int64
        let children: Int
    }

    let size: CGSize
    let entries: [Entry]

    init(nodes: [StorageExplorerHierarchyNode], size: CGSize) {
        self.size = size
        var flattened: [Entry] = []
        func append(_ nodes: [StorageExplorerHierarchyNode]) {
            for node in nodes {
                flattened.append(Entry(id: node.id, bytes: node.bytes, children: node.children.count))
                append(node.children)
            }
        }
        append(nodes)
        entries = flattened
    }
}
