import Foundation

/// Lifecycle state of the `container` system service.
public enum ContainerServiceStatus: String, Sendable, Equatable {
    case running
    case stopped
    case unregistered
    case unknown
}

/// A container instance reported by `container list`.
public struct ContainerInstance: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let statusText: String
    public let image: String
    /// Configured core count from `configuration.resources.cpus`.
    public let cpus: Int
    /// Configured memory limit from `configuration.resources.memoryInBytes`.
    public let memoryBytes: Int
    /// Container platform architecture, used to pick the matching image size.
    public let architecture: String
    /// On-disk size of the matching image variant, resolved from
    /// `container image list`; nil while no match is available.
    public let imageStorageBytes: Int?

    public var isRunning: Bool {
        statusText.lowercased() == "running"
    }

    public init(
        id: String,
        name: String,
        statusText: String,
        image: String,
        cpus: Int = 0,
        memoryBytes: Int = 0,
        architecture: String = "",
        imageStorageBytes: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.statusText = statusText
        self.image = image
        self.cpus = cpus
        self.memoryBytes = memoryBytes
        self.architecture = architecture
        self.imageStorageBytes = imageStorageBytes
    }

    /// Returns a copy carrying the resolved image storage size.
    public func withImageStorage(_ bytes: Int?) -> ContainerInstance {
        ContainerInstance(
            id: id,
            name: name,
            statusText: statusText,
            image: image,
            cpus: cpus,
            memoryBytes: memoryBytes,
            architecture: architecture,
            imageStorageBytes: bytes
        )
    }
}

/// A virtual machine reported by `container machine list`.
public struct ContainerMachine: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let statusText: String
    public let isDefault: Bool
    /// Virtual CPU count from `cpus`.
    public let cpus: Int
    /// Memory size from `memory` (bytes).
    public let memoryBytes: Int
    /// Disk image size from `diskSize` (bytes).
    public let diskSizeBytes: Int
    /// Boot image reference resolved from `container machine inspect`;
    /// empty until an inspect succeeded.
    public let image: String

    public var isRunning: Bool {
        statusText.lowercased() == "running"
    }

    public init(
        id: String,
        name: String,
        statusText: String,
        isDefault: Bool,
        cpus: Int = 0,
        memoryBytes: Int = 0,
        diskSizeBytes: Int = 0,
        image: String = ""
    ) {
        self.id = id
        self.name = name
        self.statusText = statusText
        self.isDefault = isDefault
        self.cpus = cpus
        self.memoryBytes = memoryBytes
        self.diskSizeBytes = diskSizeBytes
        self.image = image
    }

    /// Returns a copy carrying the resolved boot image reference.
    public func withImage(_ image: String) -> ContainerMachine {
        ContainerMachine(
            id: id,
            name: name,
            statusText: statusText,
            isDefault: isDefault,
            cpus: cpus,
            memoryBytes: memoryBytes,
            diskSizeBytes: diskSizeBytes,
            image: image
        )
    }
}

/// Byte sizes rendered for panel copy: whole units below GB, one decimal above.
public enum ContainerIndicatorFormatting {
    private static let units = ["B", "KB", "MB", "GB", "TB"]

    public static func bytes(_ byteCount: Int) -> String {
        guard byteCount > 0 else { return "-" }
        var value = Double(byteCount)
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        if index >= 3 {
            return String(format: "%.1f %@", value, units[index])
        }
        return String(format: "%.0f %@", value, units[index])
    }

    /// The full image reference while it fits; once it is too long for the
    /// column, only its last path segment stays visible. The full reference
    /// remains available through the row's hover help.
    public static func imageLabel(for reference: String, fits: Bool) -> String {
        guard !fits, reference.contains("/") else { return reference }
        return reference.split(separator: "/").last.map(String.init) ?? reference
    }
}

/// Immutable result of one status check, shared by every panel surface.
public struct ContainerSnapshot: Equatable, Sendable {
    public let status: ContainerServiceStatus
    public let containers: [ContainerInstance]
    public let machines: [ContainerMachine]
    public let updatedAt: Date?

    public static let unavailable = ContainerSnapshot(
        status: .unknown,
        containers: [],
        machines: [],
        updatedAt: nil
    )

    public init(
        status: ContainerServiceStatus,
        containers: [ContainerInstance],
        machines: [ContainerMachine],
        updatedAt: Date?
    ) {
        self.status = status
        self.containers = containers
        self.machines = machines
        self.updatedAt = updatedAt
    }

    public var runningContainerCount: Int {
        containers.filter(\.isRunning).count
    }

    public var runningMachineCount: Int {
        machines.filter(\.isRunning).count
    }
}

/// Pure JSON parsing kept separate from process execution so state derivation
/// stays testable without the real `container` command-line tool.
public enum ContainerIndicatorParser {
    public static func serviceStatus(exitCode: Int32, output: String) -> ContainerServiceStatus {
        guard exitCode == 0 else {
            // The `container` CLI reports a stopped service with exit code 1.
            return exitCode == 1 ? .stopped : .unknown
        }

        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = json["status"] as? String else {
            return .unknown
        }

        return ContainerServiceStatus(rawValue: status) ?? .unknown
    }

    public static func containers(fromJSON output: String) -> [ContainerInstance] {
        guard let data = output.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        return entries.compactMap { entry in
            guard let id = entry["id"] as? String else { return nil }

            let configuration = entry["configuration"] as? [String: Any]
            let name = configuration?["id"] as? String ?? id
            let image = configuration?["image"] as? [String: Any]
            let imageReference = image?["reference"] as? String ?? ""
            let status = entry["status"] as? [String: Any]
            let state = status?["state"] as? String ?? ""
            let resources = configuration?["resources"] as? [String: Any]
            let platform = configuration?["platform"] as? [String: Any]

            return ContainerInstance(
                id: id,
                name: name,
                statusText: state,
                image: imageReference,
                cpus: resources?["cpus"] as? Int ?? 0,
                memoryBytes: resources?["memoryInBytes"] as? Int ?? 0,
                architecture: platform?["architecture"] as? String ?? ""
            )
        }
    }

    public static func machines(fromJSON output: String) -> [ContainerMachine] {
        guard let data = output.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        return entries.compactMap { entry in
            guard let id = entry["id"] as? String else { return nil }

            return ContainerMachine(
                id: id,
                name: id,
                statusText: entry["status"] as? String ?? "",
                isDefault: entry["default"] as? Bool ?? false,
                cpus: entry["cpus"] as? Int ?? 0,
                memoryBytes: entry["memory"] as? Int ?? 0,
                diskSizeBytes: entry["diskSize"] as? Int ?? 0
            )
        }
    }

    /// Reads the boot image reference from `container machine inspect` output,
    /// which is an array whose first entry carries `image.reference`.
    public static func machineImage(fromInspectJSON output: String) -> String {
        guard let data = output.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = entries.first else {
            return ""
        }

        let image = first["image"] as? [String: Any]
        return image?["reference"] as? String ?? ""
    }

    /// Maps image reference to architecture to variant size from
    /// `container image list`, so each container can show the storage size of
    /// the image variant it actually runs.
    public static func imageStorageSizes(fromJSON output: String) -> [String: [String: Int]] {
        guard let data = output.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return [:]
        }

        var result: [String: [String: Int]] = [:]
        for entry in entries {
            let configuration = entry["configuration"] as? [String: Any]
            guard let name = configuration?["name"] as? String,
                  let variants = entry["variants"] as? [[String: Any]] else { continue }

            var sizesByArchitecture = result[name] ?? [:]
            for variant in variants {
                guard let size = variant["size"] as? Int else { continue }
                let variantConfig = variant["config"] as? [String: Any]
                let architecture = variantConfig?["architecture"] as? String ?? ""
                sizesByArchitecture[architecture] = max(sizesByArchitecture[architecture] ?? 0, size)
            }
            if !sizesByArchitecture.isEmpty {
                result[name] = sizesByArchitecture
            }
        }
        return result
    }
}
