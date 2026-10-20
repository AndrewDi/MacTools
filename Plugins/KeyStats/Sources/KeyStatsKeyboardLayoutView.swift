import SwiftUI
import MacToolsPluginKit

struct KeyStatsKeyboardLayoutView: View {
    let stats: KeyStatsDailyStats
    var otherKeysTitle: String = ""

    private let totalUnits: CGFloat = 15
    private let keySpacing: CGFloat = 4
    private let rowSpacing: CGFloat = 4
    private let functionRowHeight: CGFloat = 40
    private let rowHeight: CGFloat = 40

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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

            if !otherPresses.isEmpty {
                otherKeys
            }
        }
    }

    private var counts: [Int: Int] {
        stats.keyPressCounts
    }

    /// Keys that are counted but have no cap in the MacBook Pro diagram, such
    /// as keypad keys, navigation keys, and legacy name-only records.
    private var otherPresses: [KeyStatsKeyPress] {
        let diagramKeyCodes = Set(Self.allKeys.compactMap(\.keyCode))

        return stats.sortedPresses.filter { press in
            guard let keyCode = press.keyCode else {
                return true
            }
            return !diagramKeyCodes.contains(keyCode)
        }
    }

    private var totalHeight: CGFloat {
        functionRowHeight + rowHeight * 5 + rowSpacing * 5
    }

    private var maxCount: Int {
        counts.values.max() ?? 0
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
        let count = key.keyCode.map { counts[$0] ?? 0 }
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

    private var otherKeys: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !otherKeysTitle.isEmpty {
                Text(otherKeysTitle)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(
                columns: [
                    GridItem(
                        .adaptive(minimum: 82),
                        spacing: keySpacing,
                        alignment: .leading
                    )
                ],
                alignment: .leading,
                spacing: keySpacing
            ) {
                ForEach(otherPresses, id: \.self) { press in
                    otherKeyChip(press)
                }
            }
        }
    }

    private func otherKeyChip(_ press: KeyStatsKeyPress) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: PluginSettingsTheme.Radius.field,
            style: .continuous
        )

        return HStack(spacing: 4) {
            Text(press.name)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Spacer(minLength: 0)

            Text(KeyStatsFormatting.decimal(press.count))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(PluginSettingsTheme.Typography.statusBadge)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PluginSettingsTheme.Palette.keycapBackground, in: shape)
        .overlay {
            shape.strokeBorder(
                PluginSettingsTheme.Palette.cardBorder,
                lineWidth: PluginSettingsTheme.Stroke.hairline
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(press.name))
        .accessibilityValue(Text(KeyStatsFormatting.decimal(press.count)))
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

    nonisolated private static func letterKey(_ letter: String, code: Int) -> KeyStatsKeyboardKey {
        key("letter-\(letter.lowercased())", letter, code: code)
    }

    private static let functionRow: [KeyStatsKeyboardKey] = {
        var keys = [key("esc", "esc", code: 53, width: 1.5)]
        let functionKeyWidth: CGFloat = 11.5 / 12
        let functionRowCodes = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        keys += functionRowCodes.enumerated().map { index, code in
            key("f\(index + 1)", "F\(index + 1)", code: code, width: functionKeyWidth)
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
        var keys = [key("grave", "`", code: 50)]
        let numberCodes = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        keys += numberCodes.enumerated().map { index, code in
            key("number-\(index + 1)", "\(index + 1)", code: code)
        }
        keys += [
            key("number-0", "0", code: 29),
            key("minus", "-", code: 27),
            key("equal", "=", code: 24),
            key("delete", "", code: 51, width: 2, image: "delete.left", accessibility: "Delete"),
        ]
        return keys
    }()

    private static let tabRow: [KeyStatsKeyboardKey] = {
        var keys = [key("tab", "tab", code: 48, width: 2)]
        let letterCodes = [12, 13, 14, 15, 17, 16, 32, 34, 31, 35]
        keys += zip(["Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P"], letterCodes)
            .map { letter, code in letterKey(letter, code: code) }
        keys += [
            key("left-bracket", "[", code: 33),
            key("right-bracket", "]", code: 30),
            key("backslash", "\\", code: 42),
        ]
        return keys
    }()

    private static let capsRow: [KeyStatsKeyboardKey] = {
        var keys = [key("caps-lock", "caps lock", code: 57, width: 2)]
        let letterCodes = [0, 1, 2, 3, 5, 4, 38, 40, 37]
        keys += zip(["A", "S", "D", "F", "G", "H", "J", "K", "L"], letterCodes)
            .map { letter, code in letterKey(letter, code: code) }
        keys += [
            key("semicolon", ";", code: 41),
            key("quote", "'", code: 39),
            key("return", "return", code: 36, width: 2),
        ]
        return keys
    }()

    private static let shiftRow: [KeyStatsKeyboardKey] = {
        var keys = [key("left-shift", "shift", code: 56, width: 2)]
        let letterCodes = [6, 7, 8, 9, 11, 45, 46]
        keys += zip(["Z", "X", "C", "V", "B", "N", "M"], letterCodes)
            .map { letter, code in letterKey(letter, code: code) }
        keys += [
            key("comma", ",", code: 43),
            key("period", ".", code: 47),
            key("slash", "/", code: 44),
            key("right-shift", "shift", code: 60, width: 3),
        ]
        return keys
    }()

    private static let bottomKeys: [KeyStatsKeyboardKey] = [
        key("fn", "fn", code: 63),
        key("left-control", "⌃", code: 59, accessibility: "Left Control"),
        key("left-option", "⌥", code: 58, width: 1.25, accessibility: "Left Option"),
        key("left-command", "⌘", code: 55, width: 1.25, accessibility: "Left Command"),
        key("space", "space", code: 49, width: 4.75),
        key("right-command", "⌘", code: 54, width: 1.25, accessibility: "Right Command"),
        key("right-option", "⌥", code: 61, width: 1.25, accessibility: "Right Option"),
    ]

    private static let arrowLeft = key("arrow-left", "←", code: 123)
    private static let arrowUp = key("arrow-up", "↑", code: 126)
    private static let arrowDown = key("arrow-down", "↓", code: 125)
    private static let arrowRight = key("arrow-right", "→", code: 124)

    private static let allKeys =
        functionRow + numberRow + tabRow + capsRow + shiftRow + bottomKeys +
        [arrowLeft, arrowUp, arrowDown, arrowRight]
}

private struct KeyStatsKeyboardKey: Identifiable {
    let id: String
    let label: String
    let systemImage: String?
    let accessibilityLabel: String
    let keyCode: Int?
    let widthUnits: CGFloat

    init(
        id: String,
        label: String,
        systemImage: String? = nil,
        accessibilityLabel: String? = nil,
        keyCode: Int?,
        widthUnits: CGFloat = 1
    ) {
        self.id = id
        self.label = label
        self.systemImage = systemImage
        self.accessibilityLabel = accessibilityLabel ?? label
        self.keyCode = keyCode
        self.widthUnits = widthUnits
    }
}

private func key(
    _ id: String,
    _ label: String,
    code: Int? = nil,
    width: CGFloat = 1,
    image: String? = nil,
    accessibility: String? = nil
) -> KeyStatsKeyboardKey {
    KeyStatsKeyboardKey(
        id: id,
        label: label,
        systemImage: image,
        accessibilityLabel: accessibility,
        keyCode: code,
        widthUnits: width
    )
}
