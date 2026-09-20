import Foundation
import OSLog

enum DisplayVolumeLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools"

    static let plugin = Logger(subsystem: subsystem, category: "DisplayVolumePlugin")
    static let controller = Logger(subsystem: subsystem, category: "DisplayVolumeController")
    static let backend = Logger(subsystem: subsystem, category: "DisplayVolumeBackend")
}
