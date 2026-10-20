import Foundation
import MacToolsPluginKit

enum KeyStatsConstants {
    static let pluginID = "key-stats"
}

enum KeyStatsInputMonitorStatus: Equatable, Sendable {
    case idle
    case running
    case inputMonitoringDenied
}

enum KeyStatsInputEvent: Equatable, Sendable {
    case keyPress(keyCode: Int, name: String)
    case trackpadUse
}

/// A counted key press.
///
/// The physical key code stays stable across keyboard layouts, so the heatmap
/// keeps working when a user types with a non-English layout. The name is the
/// label captured when the key was pressed and is only used for keys the
/// keyboard diagram cannot show.
struct KeyStatsKeyPress: Codable, Equatable, Hashable, Sendable {
    var keyCode: Int?
    var name: String
    var count: Int
}

struct KeyStatsDailyStats: Codable, Identifiable, Equatable, Sendable {
    let date: String
    var keyPresses: [KeyStatsKeyPress]
    var trackpadUses: Int

    init(
        date: String,
        keyPresses: [KeyStatsKeyPress] = [],
        trackpadUses: Int = 0
    ) {
        self.date = date
        self.keyPresses = keyPresses
        self.trackpadUses = trackpadUses
    }

    var id: String { date }

    var totalKeyPresses: Int {
        keyPresses.reduce(0) { total, press in
            let nonnegative = max(0, press.count)
            let (sum, overflow) = total.addingReportingOverflow(nonnegative)
            return overflow ? Int.max : sum
        }
    }

    var usedKeyCount: Int {
        countedPresses.count
    }

    var sortedPresses: [KeyStatsKeyPress] {
        countedPresses.sorted {
            if $0.count != $1.count {
                return $0.count > $1.count
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func press(forKeyCode keyCode: Int) -> KeyStatsKeyPress? {
        keyPresses.first { $0.keyCode == keyCode }
    }

    func count(forKeyCode keyCode: Int) -> Int {
        max(0, press(forKeyCode: keyCode)?.count ?? 0)
    }

    /// Counts keyed by physical key code, for layout-independent heatmaps.
    var keyPressCounts: [Int: Int] {
        countedPresses.reduce(into: [:]) { result, press in
            guard let keyCode = press.keyCode else {
                return
            }
            result[keyCode, default: 0] += press.count
        }
    }

    private var countedPresses: [KeyStatsKeyPress] {
        keyPresses.filter { !$0.name.isEmpty && $0.count > 0 }
    }

    enum CodingKeys: String, CodingKey {
        case date
        case keyPresses
        case trackpadUses
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case keyPressCounts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decode(String.self, forKey: .date)
        trackpadUses = try container.decodeIfPresent(Int.self, forKey: .trackpadUses) ?? 0

        if container.contains(.keyPresses) {
            keyPresses = try container.decode([KeyStatsKeyPress].self, forKey: .keyPresses)
            return
        }

        // Records written before key presses were tracked by physical key code
        // only carried a display name. Recover the physical key when the name
        // is unambiguous and keep the rest as named-only entries.
        let legacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)
        let legacyCounts = try legacyContainer.decodeIfPresent(
            [String: Int].self,
            forKey: .keyPressCounts
        ) ?? [:]
        keyPresses = legacyCounts
            .map { name, count in
                KeyStatsKeyPress(
                    keyCode: KeyStatsKeyNameDecoder.keyCode(forName: name),
                    name: name,
                    count: count
                )
            }
            .sorted {
                if $0.count != $1.count {
                    return $0.count > $1.count
                }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }
}

enum KeyStatsFormatting {
    static func decimal(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = PluginRuntimeLocalization.locale
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func compactCount(_ value: Int) -> String {
        guard value >= 1_000 else {
            return decimal(value)
        }

        let scaled = Double(value) / 1_000
        if scaled >= 100 {
            return "\(Int(scaled.rounded()))k"
        }
        return String(format: "%.1fk", locale: PluginRuntimeLocalization.locale, scaled)
    }

    static func monthDay(_ date: Date, locale: Locale = PluginRuntimeLocalization.locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter.string(from: date)
    }

    static func compactMonthDay(_ date: Date, locale: Locale = PluginRuntimeLocalization.locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("Md")
        return formatter.string(from: date)
    }
}
