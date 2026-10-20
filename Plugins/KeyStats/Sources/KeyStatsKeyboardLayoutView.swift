import SwiftUI
import MacToolsPluginKit

struct KeyStatsKeyboardLayoutView: View {
    let counts: [String: Int]

    private let totalUnits: CGFloat = 15
    private let keySpacing: CGFloat = 4
    private let rowSpacing: CGFloat = 4
    private let functionRowHeight: CGFloat = 40
    private let rowHeight: CGFloat = 40

    var body: some View {
        GeometryReader { geometry in
            let unit = max(
                0,
                (geometry.size.width - keySpacing * (totalUnits - 1)) / totalUnits
            )

            VStack(spacing: rowSpacing) {
                keyRow(Self.functionRow, unit: unit, height: functionRowHeight)
                keyRow(Self.numberRow, unit: unit, height: rowHeight)
                keyRow(Self.tabRow, unit: unit, height: rowHeight)
                keyRow(Self.capsRow, unit: unit, height: rowHeight)
                keyRow(Self.shiftRow, unit: unit, height: rowHeight)
                bottomRow(unit: unit, height: rowHeight)
            }
        }
        .frame(height: totalHeight)
        .accessibilityElement(children: .contain)
    }

    private var totalHeight: CGFloat {
        functionRowHeight + rowHeight * 5 + rowSpacing * 5
    }

    private var maxCount: Int {
        Self.allKeys.reduce(0) { result, key in
            guard let statName = key.statName else {
                return result
            }
            return max(result, counts[statName] ?? 0)
        }
    }

    private func keyRow(
        _ keys: [KeyStatsKeyboardKey],
        unit: CGFloat,
        height: CGFloat,
        compact: Bool = false
    ) -> some View {
        HStack(spacing: keySpacing) {
            ForEach(keys) { key in
                keyCap(key, compact: compact)
                    .frame(width: keyWidth(key, unit: unit), height: height)
            }
        }
    }

    private func bottomRow(unit: CGFloat, height: CGFloat) -> some View {
        HStack(spacing: keySpacing) {
            ForEach(Self.bottomKeys) { key in
                keyCap(key)
                    .frame(width: keyWidth(key, unit: unit), height: height)
            }

            arrowCluster(unit: unit, height: height)
        }
    }

    private func arrowCluster(unit: CGFloat, height: CGFloat) -> some View {
        let halfHeight = max(0, (height - keySpacing) / 2)
        let arrowKeyWidth = unit * (3.25 / 3)

        return HStack(spacing: keySpacing) {
            keyCap(Self.arrowLeft)
                .frame(width: arrowKeyWidth, height: height)

            VStack(spacing: keySpacing) {
                keyCap(Self.arrowUp, compact: true)
                    .frame(width: arrowKeyWidth, height: halfHeight)
                keyCap(Self.arrowDown, compact: true)
                    .frame(width: arrowKeyWidth, height: halfHeight)
            }

            keyCap(Self.arrowRight)
                .frame(width: arrowKeyWidth, height: height)
        }
        .frame(width: unit * 3.25 + keySpacing * 2.25, height: height)
    }

    private func keyWidth(_ key: KeyStatsKeyboardKey, unit: CGFloat) -> CGFloat {
        max(0, key.widthUnits * unit + keySpacing * (key.widthUnits - 1))
    }

    private func keyCap(_ key: KeyStatsKeyboardKey, compact: Bool = false) -> some View {
        let count = key.statName.map { counts[$0] ?? 0 }
        let ratio = maxCount > 0 ? Double(count ?? 0) / Double(maxCount) : 0
        let fill: AnyShapeStyle = (count ?? 0) > 0
            ? AnyShapeStyle(Color.accentColor.opacity(0.08 + 0.28 * ratio))
            : AnyShapeStyle(PluginSettingsTheme.Palette.keycapBackground)
        let shape = RoundedRectangle(
            cornerRadius: PluginSettingsTheme.Radius.field,
            style: .continuous
        )

        return Group {
            if compact {
                HStack(spacing: 1) {
                    keyLabel(key)
                    if let count {
                        countLabel(count)
                    }
                }
            } else {
                VStack(spacing: 1) {
                    keyLabel(key)
                    if let count {
                        countLabel(count)
                    }
                }
            }
        }
        .padding(.horizontal, compact ? 1 : 2)
        .padding(.vertical, compact ? 1 : 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(fill, in: shape)
        .overlay {
            shape.strokeBorder(
                PluginSettingsTheme.Palette.cardBorder,
                lineWidth: PluginSettingsTheme.Stroke.hairline
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(key.accessibilityLabel))
        .accessibilityValue(Text(count.map(KeyStatsFormatting.decimal) ?? ""))
    }

    @ViewBuilder
    private func keyLabel(_ key: KeyStatsKeyboardKey) -> some View {
        if let systemImage = key.systemImage {
            Image(systemName: systemImage)
                .font(PluginSettingsTheme.Typography.rowIcon)
                .foregroundStyle(.primary)
        } else {
            Text(key.label)
                .font(PluginSettingsTheme.Typography.statusBadge)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }

    private func countLabel(_ count: Int) -> some View {
        Text(KeyStatsFormatting.decimal(count))
            .font(PluginSettingsTheme.Typography.statusBadge.monospacedDigit())
            .foregroundStyle(.secondary)
            .opacity(count > 0 ? 1 : 0.5)
            .lineLimit(1)
            .minimumScaleFactor(0.65)
    }

    nonisolated private static func letterKey(_ letter: String) -> KeyStatsKeyboardKey {
        key("letter-\(letter.lowercased())", letter, stat: letter)
    }

    private static let functionRow: [KeyStatsKeyboardKey] = {
        var keys = [key("esc", "esc", stat: "Esc", width: 1.5)]
        let functionKeyWidth: CGFloat = 11.5 / 12
        keys += (1...12).map { index in
            key("f\(index)", "F\(index)", stat: "F\(index)", width: functionKeyWidth)
        }
        keys.append(
            key(
                "touch-id",
                "",
                width: 2,
                image: "touchid",
                accessibility: "Touch ID"
            )
        )
        return keys
    }()

    private static let numberRow: [KeyStatsKeyboardKey] = {
        var keys = [key("grave", "`", stat: "`")]
        keys += (1...9).map { index in
            key("number-\(index)", "\(index)", stat: "\(index)")
        }
        keys += [
            key("number-0", "0", stat: "0"),
            key("minus", "-", stat: "-"),
            key("equal", "=", stat: "="),
            key("delete", "", stat: "Delete", width: 2, image: "delete.left", accessibility: "Delete"),
        ]
        return keys
    }()

    private static let tabRow: [KeyStatsKeyboardKey] = {
        var keys = [key("tab", "tab", stat: "Tab", width: 2)]
        keys += ["Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P"].map(letterKey)
        keys += [
            key("left-bracket", "[", stat: "["),
            key("right-bracket", "]", stat: "]"),
            key("backslash", "\\", stat: "\\"),
        ]
        return keys
    }()

    private static let capsRow: [KeyStatsKeyboardKey] = {
        var keys = [key("caps-lock", "caps lock", stat: "Caps", width: 2)]
        keys += ["A", "S", "D", "F", "G", "H", "J", "K", "L"].map(letterKey)
        keys += [
            key("semicolon", ";", stat: ";"),
            key("quote", "'", stat: "'"),
            key("return", "return", stat: "Return", width: 2),
        ]
        return keys
    }()

    private static let shiftRow: [KeyStatsKeyboardKey] = {
        var keys = [key("left-shift", "shift", stat: "⇧L", width: 2)]
        keys += ["Z", "X", "C", "V", "B", "N", "M"].map(letterKey)
        keys += [
            key("comma", ",", stat: ","),
            key("period", ".", stat: "."),
            key("slash", "/", stat: "/"),
            key("right-shift", "shift", stat: "⇧R", width: 3),
        ]
        return keys
    }()

    private static let bottomKeys: [KeyStatsKeyboardKey] = [
        key("fn", "fn", stat: "Fn"),
        key("left-control", "⌃", stat: "⌃L", accessibility: "Left Control"),
        key("left-option", "⌥", stat: "⌥L", width: 1.25, accessibility: "Left Option"),
        key("left-command", "⌘", stat: "⌘L", width: 1.25, accessibility: "Left Command"),
        key("space", "space", stat: "Space", width: 4.75),
        key("right-command", "⌘", stat: "⌘R", width: 1.25, accessibility: "Right Command"),
        key("right-option", "⌥", stat: "⌥R", width: 1.25, accessibility: "Right Option"),
    ]

    private static let arrowLeft = key("arrow-left", "←", stat: "←")
    private static let arrowUp = key("arrow-up", "↑", stat: "↑")
    private static let arrowDown = key("arrow-down", "↓", stat: "↓")
    private static let arrowRight = key("arrow-right", "→", stat: "→")

    private static let allKeys =
        functionRow + numberRow + tabRow + capsRow + shiftRow + bottomKeys +
        [arrowLeft, arrowUp, arrowDown, arrowRight]
}

private struct KeyStatsKeyboardKey: Identifiable {
    let id: String
    let label: String
    let systemImage: String?
    let accessibilityLabel: String
    let statName: String?
    let widthUnits: CGFloat

    init(
        id: String,
        label: String,
        systemImage: String? = nil,
        accessibilityLabel: String? = nil,
        statName: String?,
        widthUnits: CGFloat = 1
    ) {
        self.id = id
        self.label = label
        self.systemImage = systemImage
        self.accessibilityLabel = accessibilityLabel ?? label
        self.statName = statName
        self.widthUnits = widthUnits
    }
}

private func key(
    _ id: String,
    _ label: String,
    stat: String? = nil,
    width: CGFloat = 1,
    image: String? = nil,
    accessibility: String? = nil
) -> KeyStatsKeyboardKey {
    KeyStatsKeyboardKey(
        id: id,
        label: label,
        systemImage: image,
        accessibilityLabel: accessibility,
        statName: stat,
        widthUnits: width
    )
}
