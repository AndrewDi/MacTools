import SwiftUI

struct StorageExplorerHierarchyTreemapView: View {
    let nodes: [StorageExplorerHierarchyNode]
    @Binding var selection: String?
    let emptyLabel: String
    let addReviewLabel: String
    let open: (StorageItem) -> Void
    let toggleReview: (StorageItem) -> Void

    @State private var hoveredID: String?
    @State private var rectangles: [StorageExplorerHierarchyRect] = []

    var body: some View {
        GeometryReader { geometry in
            let key = LayoutKey(nodes: nodes, size: geometry.size)
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    for entry in rectangles {
                        draw(entry, context: &context)
                    }
                }
                .accessibilityHidden(true)

                ForEach(rectangles) { entry in
                    interactiveRegion(entry)
                }

                if rectangles.isEmpty {
                    Text(emptyLabel)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onAppear { updateLayout(size: geometry.size) }
            .onChange(of: key) { _, _ in updateLayout(size: geometry.size) }
        }
    }

    private func interactiveRegion(_ entry: StorageExplorerHierarchyRect) -> some View {
        let inset = entry.rect.insetBy(dx: 2, dy: 2)
        return Color.clear
            .contentShape(Rectangle())
            .frame(width: max(0, inset.width), height: max(0, inset.height))
            .position(x: inset.midX, y: inset.midY)
            .onHover { hovering in
                if hovering {
                    hoveredID = entry.id
                } else if hoveredID == entry.id {
                    hoveredID = nil
                }
            }
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
                    Button(addReviewLabel) { toggleReview(entry.node.item) }
                }
            }
            .draggable(entry.node.isAggregate ? "" : entry.node.item.path) {
                HStack(spacing: 8) {
                    Image(systemName: entry.node.item.iconSystemName)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.node.item.name).lineLimit(1)
                        Text(ByteCountFormatter.string(fromByteCount: entry.node.bytes, countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            .overlay(alignment: .topTrailing) {
                if hoveredID == entry.id, !entry.node.isAggregate, inset.width > 54, inset.height > 38 {
                    Button { toggleReview(entry.node.item) } label: {
                        Image(systemName: "plus.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help(addReviewLabel)
                    .padding(7)
                }
            }
            .help(helpText(for: entry.node))
    }

    private func draw(_ entry: StorageExplorerHierarchyRect, context: inout GraphicsContext) {
        let inset = entry.rect.insetBy(dx: entry.depth == 0 ? 1.5 : 1, dy: entry.depth == 0 ? 1.5 : 1)
        guard inset.width > 0, inset.height > 0 else { return }
        let shape = Path(roundedRect: inset, cornerRadius: entry.depth == 0 ? 6 : 4)
        let base = color(for: entry.node.colorKey)
        let brightness = max(0.5, 0.88 - Double(entry.depth) * 0.10)
        context.fill(shape, with: .color(base.opacity(brightness)))
        context.stroke(
            shape,
            with: .color(hoveredID == entry.id ? .white : .white.opacity(entry.depth == 0 ? 0.72 : 0.42)),
            lineWidth: hoveredID == entry.id ? 2.5 : 1
        )
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

    private func updateLayout(size: CGSize) {
        hoveredID = nil
        rectangles = StorageExplorerHierarchyRectLayout.make(
            nodes: nodes,
            in: CGRect(origin: .zero, size: size)
        )
    }

    private func color(for key: String) -> Color {
        let palette: [Color] = [.blue, .teal, .green, .indigo, .purple, .pink, .orange, .mint]
        let hash = key.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }
        return palette[Int(hash % UInt64(palette.count))]
    }

    private func helpText(for node: StorageExplorerHierarchyNode) -> String {
        let size = ByteCountFormatter.string(fromByteCount: node.bytes, countStyle: .file)
        return node.isAggregate ? "\(node.item.name) · \(size)" : "\(node.item.name) · \(size)\n\(node.item.path)"
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
