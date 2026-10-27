import AppKit
import Foundation

/// A running resource that can open an interactive shell.
public enum ContainerTerminalTarget: Equatable, Sendable {
    case container(id: String)
    case machine(id: String)

    public var identifier: String {
        switch self {
        case .container(let id), .machine(let id):
            return id
        }
    }
}

public enum ContainerTerminalLaunchError: Error, Equatable, Sendable {
    case invalidIdentifier
    case invalidExecutable
    case scriptWriteFailed
    case openFailed
}

@MainActor
public protocol ContainerTerminalLaunching {
    func launch(target: ContainerTerminalTarget, executable: String) throws
}

/// Opens an interactive shell in the user's default terminal. The plugin runs
/// inside the host app and has no PTY, so it writes a small `.command` script
/// and hands it to LaunchServices: that keeps the terminal choice with the
/// user and avoids AppleScript automation prompts.
@MainActor
public struct ContainerTerminalLauncher: ContainerTerminalLaunching {
    /// Container and machine identifiers are user-chosen names; anything
    /// outside this set never reaches the script.
    private static let identifierPattern = "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"

    private let directory: URL
    private let openURL: (URL) -> Bool
    private let fileManager: FileManager

    public init(
        directory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacTools/ContainerIndicator/Terminal", isDirectory: true),
        fileManager: FileManager = .default,
        openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.directory = directory
        self.fileManager = fileManager
        self.openURL = openURL
    }

    public func launch(target: ContainerTerminalTarget, executable: String) throws {
        guard Self.isValidIdentifier(target.identifier) else {
            throw ContainerTerminalLaunchError.invalidIdentifier
        }
        guard Self.isValidExecutablePath(executable) else {
            throw ContainerTerminalLaunchError.invalidExecutable
        }

        let script = Self.script(for: target, executable: executable)
        let fileURL = directory.appendingPathComponent(Self.fileName(for: target))

        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try? fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
            try Data(script.utf8).write(to: fileURL, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: fileURL.path
            )
        } catch {
            throw ContainerTerminalLaunchError.scriptWriteFailed
        }

        guard openURL(fileURL) else {
            throw ContainerTerminalLaunchError.openFailed
        }
    }

    /// The script content, exposed for tests. It prefers bash when the image
    /// has it and falls back to the POSIX shell.
    public static func script(
        for target: ContainerTerminalTarget,
        executable: String
    ) -> String {
        let container = shellQuoted(executable)
        let identifier = shellQuoted(target.identifier)

        switch target {
        case .container:
            return """
            #!/bin/zsh
            CONTAINER=\(container)
            ID=\(identifier)
            if "$CONTAINER" exec "$ID" /bin/sh -c 'test -x /bin/bash' >/dev/null 2>&1; then
              exec "$CONTAINER" exec -it "$ID" /bin/bash
            fi
            exec "$CONTAINER" exec -it "$ID" /bin/sh
            """
        case .machine:
            return """
            #!/bin/zsh
            exec \(container) machine run -n \(identifier)
            """
        }
    }

    /// Single-quote shell escaping: wrap in quotes and splice embedded quotes
    /// as `'\''`.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func isValidIdentifier(_ identifier: String) -> Bool {
        identifier.range(of: identifierPattern, options: .regularExpression) != nil
    }

    static func isValidExecutablePath(_ path: String) -> Bool {
        path.hasPrefix("/")
            && !path.contains("\n")
            && !path.contains("\r")
            && !path.contains("\0")
    }

    private static func fileName(for target: ContainerTerminalTarget) -> String {
        let prefix: String
        switch target {
        case .container: prefix = "container"
        case .machine: prefix = "machine"
        }
        let sanitized = target.identifier.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "-",
            options: .regularExpression
        )
        return "\(prefix)-\(sanitized).command"
    }
}
