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
    case keyPress(name: String)
    case trackpadUse
}

struct KeyStatsDailyStats: Codable, Identifiable, Equatable, Sendable {
    let date: String
    var keyPressCounts: [String: Int]
    var trackpadUses: Int

    init(
        date: String,
        keyPressCounts: [String: Int] = [:],
        trackpadUses: Int = 0
    ) {
        self.date = date
        self.keyPressCounts = keyPressCounts
        self.trackpadUses = trackpadUses
    }

    var id: String { date }

    var totalKeyPresses: Int {
        keyPressCounts.values.reduce(0) { total, value in
            let nonnegative = max(0, value)
            let (sum, overflow) = total.addingReportingOverflow(nonnegative)
            return overflow ? Int.max : sum
        }
    }

    var sortedKeys: [(name: String, count: Int)] {
        keyPressCounts
            .filter { !$0.key.isEmpty && $0.value > 0 }
            .map { (name: $0.key, count: $0.value) }
            .sorted {
                if $0.count != $1.count {
                    return $0.count > $1.count
                }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    enum CodingKeys: String, CodingKey {
        case date
        case keyPressCounts
        case trackpadUses
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decode(String.self, forKey: .date)
        keyPressCounts = try container.decodeIfPresent([String: Int].self, forKey: .keyPressCounts) ?? [:]
        trackpadUses = try container.decodeIfPresent(Int.self, forKey: .trackpadUses) ?? 0
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

    static func weekday(_ date: Date, locale: Locale = PluginRuntimeLocalization.locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = "E"
        return formatter.string(from: date)
    }
}
