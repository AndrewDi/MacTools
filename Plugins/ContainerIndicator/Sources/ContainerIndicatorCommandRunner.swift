import Darwin
import Foundation
import MacToolsPluginKit

public struct ContainerCommandResult: Equatable, Sendable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String

    public init(exitCode: Int32, standardOutput: String, standardError: String) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public enum ContainerCommandError: LocalizedError, Sendable {
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .timedOut:
            return "The container command did not finish in time."
        }
    }
}

public protocol ContainerCommandRunning: Sendable {
    func run(
        executable: String,
        arguments: [String]
    ) async throws -> ContainerCommandResult
}

/// Finds the `container` command-line tool without trusting the caller's PATH.
public enum ContainerExecutableLocator {
    public static let standardPaths = [
        "/opt/homebrew/bin/container",
        "/usr/local/bin/container",
        "/usr/bin/container",
        "\(NSHomeDirectory())/.local/bin/container",
    ]

    public static func locate(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        for path in standardPaths where isValidExecutable(at: path, fileManager: fileManager) {
            return path
        }

        for entry in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(entry))
                .appendingPathComponent("container").path
            if isValidExecutable(at: candidate, fileManager: fileManager) {
                return candidate
            }
        }

        return nil
    }

    public static func isValidExecutable(
        at rawPath: String,
        fileManager: FileManager = .default
    ) -> Bool {
        let url = URL(fileURLWithPath: rawPath).standardizedFileURL
        guard url.lastPathComponent == "container" else { return false }

        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && fileManager.isExecutableFile(atPath: url.path)
    }
}

public struct ContainerCommandRunner: ContainerCommandRunning {
    public static let defaultTimeout: TimeInterval = 120
    private static let environmentPathDirectories = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
        "\(NSHomeDirectory())/.local/bin",
    ]

    private let timeout: TimeInterval

    public init(timeout: TimeInterval = ContainerCommandRunner.defaultTimeout) {
        self.timeout = timeout
    }

    public func run(
        executable: String,
        arguments: [String]
    ) async throws -> ContainerCommandResult {
        let execution = ContainerCommandExecution(
            executable: executable,
            arguments: arguments,
            environment: Self.environment(environment: ProcessInfo.processInfo.environment),
            timeout: timeout
        )
        // Cancelling the awaiting task terminates the child process group, so a
        // hidden panel never leaves a `container` command running behind it.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<ContainerCommandResult, Error>) in
                execution.start(continuation: continuation)
            }
        } onCancel: {
            execution.cancel()
        }
    }

    private static func environment(
        environment: [String: String]
    ) -> [String: String] {
        var resolved = environment
        var components = (environment["PATH"] ?? "").components(separatedBy: ":")
        for directory in environmentPathDirectories where !components.contains(directory) {
            components.insert(directory, at: 0)
        }
        resolved["PATH"] = components.joined(separator: ":")
        return resolved
    }
}

private final class ContainerCommandExecution: @unchecked Sendable {
    typealias Continuation = CheckedContinuation<ContainerCommandResult, Error>

    private struct LaunchResult {
        let processID: pid_t
        let outputDescriptor: Int32
        let errorDescriptor: Int32
    }

    private enum Stream {
        case standardOutput
        case standardError
    }

    private static let forcedKillDelay: TimeInterval = 0.25
    private static let drainDeadline: TimeInterval = 0.2
    private static let cancelDeadline: TimeInterval = 1

    private let executable: String
    private let arguments: [String]
    private let environment: [String: String]
    private let timeout: TimeInterval
    private let controlQueue = DispatchQueue(
        label: "cc.ggbond.mactools.container-indicator.command-control",
        qos: .utility
    )
    private let ioQueue = DispatchQueue(
        label: "cc.ggbond.mactools.container-indicator.command-io",
        qos: .utility
    )

    private var continuation: Continuation?
    private var lease: PluginProcessGroupLease?
    private var timeoutWorkItem: DispatchWorkItem?
    private var forcedKillWorkItem: DispatchWorkItem?
    private var drainWorkItem: DispatchWorkItem?
    private var cancelWorkItem: DispatchWorkItem?
    private var leaderDidExit = false
    private var didTimeOut = false
    private var didFinish = false
    /// Set by `cancel()`: the caller stopped waiting, so the command must fail
    /// with `CancellationError` instead of reporting whatever the CLI returned.
    private var didCancel = false
    /// Set by `cancel()` even when the continuation is not stored yet, so a
    /// cancellation that wins the race against `start` still avoids the spawn.
    private var isCancelRequested = false
    private var closedStreamCount = 0

    // Accessed only from ioQueue.
    private var outputData = Data()
    private var errorData = Data()
    private var outputSource: DispatchSourceRead?
    private var errorSource: DispatchSourceRead?
    private var outputDescriptor: Int32 = -1
    private var errorDescriptor: Int32 = -1
    private var outputDidClose = false
    private var errorDidClose = false

    init(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.timeout = max(1, timeout)
    }

    func start(continuation: Continuation) {
        controlQueue.async { [self] in
            self.continuation = continuation
            // A cancellation that arrived before the spawn must fail the call
            // instead of launching a command nobody is waiting for.
            guard !isCancelRequested else {
                finish(throwing: CancellationError())
                return
            }
            do {
                let launch = try spawn()
                let processLease = PluginProcessGroupLease(processID: launch.processID)
                lease = processLease
                startReading(
                    outputDescriptor: launch.outputDescriptor,
                    errorDescriptor: launch.errorDescriptor
                )
                scheduleTimeout()
                DispatchQueue.global(qos: .utility).async { [self] in
                    let observedExit = processLease.waitForLeaderExit()
                    controlQueue.async { [self] in
                        processDidExit(observedExit: observedExit)
                    }
                }
            } catch {
                finish(throwing: error)
            }
        }
    }

    /// Terminates the child process group and fails the pending command, so the
    /// caller's cancellation reaches the CLI instead of only dropping its result.
    func cancel() {
        controlQueue.async { [self] in
            isCancelRequested = true
            guard !didFinish else { return }
            guard continuation != nil else {
                // `start` has not stored the continuation yet; it observes the
                // flag and finishes without spawning.
                return
            }
            didCancel = true
            lease?.signal(SIGTERM)
            scheduleForcedKill()
            // A child that ignores SIGTERM must not keep the caller suspended.
            let workItem = DispatchWorkItem { [self] in
                guard !didFinish else { return }
                lease?.signal(SIGKILL)
                closeStreamsAndFinish(throwing: CancellationError())
            }
            cancelWorkItem = workItem
            controlQueue.asyncAfter(deadline: .now() + Self.cancelDeadline, execute: workItem)
        }
    }

    private func startReading(outputDescriptor: Int32, errorDescriptor: Int32) {
        ioQueue.async { [self] in
            self.outputDescriptor = outputDescriptor
            self.errorDescriptor = errorDescriptor
            outputSource = makeReadSource(descriptor: outputDescriptor, stream: .standardOutput)
            errorSource = makeReadSource(descriptor: errorDescriptor, stream: .standardError)
            outputSource?.resume()
            errorSource?.resume()
        }
    }

    private func makeReadSource(descriptor: Int32, stream: Stream) -> DispatchSourceRead {
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: ioQueue)
        source.setEventHandler { [self] in
            drain(descriptor: descriptor, stream: stream)
        }
        source.setCancelHandler { [self] in
            Darwin.close(descriptor)
            controlQueue.async { [self] in
                closedStreamCount += 1
                finishIfReady()
            }
        }
        return source
    }

    private func drain(descriptor: Int32, stream: Stream) {
        var bytes = [UInt8](repeating: 0, count: 16 * 1024)
        for _ in 0 ..< 16 {
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress, buffer.count)
            }
            if count > 0 {
                switch stream {
                case .standardOutput:
                    outputData.append(contentsOf: bytes.prefix(count))
                case .standardError:
                    errorData.append(contentsOf: bytes.prefix(count))
                }
                continue
            }
            if count < 0, errno == EINTR { continue }
            if count == 0 { close(stream: stream) }
            break
        }
    }

    private func close(stream: Stream) {
        switch stream {
        case .standardOutput:
            guard !outputDidClose else { return }
            outputDidClose = true
            outputSource?.cancel()
            outputSource = nil
            outputDescriptor = -1
        case .standardError:
            guard !errorDidClose else { return }
            errorDidClose = true
            errorSource?.cancel()
            errorSource = nil
            errorDescriptor = -1
        }
    }

    private func scheduleTimeout() {
        let workItem = DispatchWorkItem { [self] in
            guard !leaderDidExit, !didFinish else { return }
            didTimeOut = true
            lease?.signal(SIGTERM)
            scheduleForcedKill()
        }
        timeoutWorkItem = workItem
        controlQueue.asyncAfter(deadline: .now() + timeout, execute: workItem)
    }

    private func scheduleForcedKill() {
        guard forcedKillWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [self] in
            guard !leaderDidExit, !didFinish else { return }
            lease?.signal(SIGKILL)
        }
        forcedKillWorkItem = workItem
        controlQueue.asyncAfter(deadline: .now() + Self.forcedKillDelay, execute: workItem)
    }

    private func processDidExit(observedExit: Bool) {
        guard !didFinish else { return }
        leaderDidExit = true
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        forcedKillWorkItem?.cancel()
        forcedKillWorkItem = nil

        guard observedExit else {
            closeStreamsAndFinish(throwing: nil)
            return
        }
        if closedStreamCount == 2 {
            finishIfReady()
            return
        }

        // An exited leader can leave descendants holding inherited pipe
        // descriptors; stop them and drain once so the panel never hangs.
        let workItem = DispatchWorkItem { [self] in
            guard !didFinish else { return }
            lease?.signal(SIGKILL)
            closeStreamsAndFinish(throwing: nil)
        }
        drainWorkItem = workItem
        controlQueue.asyncAfter(deadline: .now() + Self.drainDeadline, execute: workItem)
    }

    /// Cancellation outranks the timeout: the caller already stopped waiting,
    /// so reporting a timeout would describe a deadline it no longer has.
    private var terminalFailure: Error? {
        if didCancel { return CancellationError() }
        return didTimeOut ? ContainerCommandError.timedOut : nil
    }

    private func finishIfReady() {
        guard leaderDidExit, closedStreamCount == 2, !didFinish else { return }
        captureStreamsAndFinish(throwing: terminalFailure)
    }

    private func closeStreamsAndFinish(throwing failure: Error?) {
        let resolvedFailure = failure ?? terminalFailure
        ioQueue.async { [self] in
            if outputDescriptor >= 0 {
                drain(descriptor: outputDescriptor, stream: .standardOutput)
            }
            if errorDescriptor >= 0 {
                drain(descriptor: errorDescriptor, stream: .standardError)
            }
            close(stream: .standardOutput)
            close(stream: .standardError)
            let output = outputData
            let error = errorData
            controlQueue.async { [self] in
                finish(output: output, error: error, throwing: resolvedFailure)
            }
        }
    }

    private func captureStreamsAndFinish(throwing error: Error?) {
        ioQueue.async { [self] in
            let output = outputData
            let streams = errorData
            controlQueue.async { [self] in
                finish(output: output, error: streams, throwing: error)
            }
        }
    }

    private func finish(throwing error: Error) {
        finish(output: Data(), error: Data(), throwing: error)
    }

    private func finish(output: Data, error: Data, throwing failure: Error?) {
        guard !didFinish else { return }
        didFinish = true
        drainWorkItem?.cancel()
        drainWorkItem = nil
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        forcedKillWorkItem?.cancel()
        forcedKillWorkItem = nil
        cancelWorkItem?.cancel()
        cancelWorkItem = nil
        let rawStatus = lease?.reapLeader()
        lease = nil

        let pendingContinuation = continuation
        continuation = nil
        if let failure {
            pendingContinuation?.resume(throwing: failure)
            return
        }

        let exitCode = rawStatus.map(Self.exitCode(from:)) ?? 1
        pendingContinuation?.resume(returning: ContainerCommandResult(
            exitCode: exitCode,
            standardOutput: String(decoding: output, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            standardError: String(decoding: error, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
    }

    private func spawn() throws -> LaunchResult {
        var outputPipe: [Int32] = [-1, -1]
        var errorPipe: [Int32] = [-1, -1]
        guard pipe(&outputPipe) == 0 else { throw POSIXError(.EIO) }
        guard pipe(&errorPipe) == 0 else {
            Darwin.close(outputPipe[0])
            Darwin.close(outputPipe[1])
            throw POSIXError(.EIO)
        }

        func closePipes() {
            outputPipe.filter { $0 >= 0 }.forEach { Darwin.close($0) }
            errorPipe.filter { $0 >= 0 }.forEach { Darwin.close($0) }
        }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0,
              posix_spawnattr_init(&attributes) == 0 else {
            closePipes()
            throw POSIXError(.EIO)
        }
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }

        guard posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, errorPipe[1], STDERR_FILENO) == 0,
              posix_spawn_file_actions_addclose(&actions, outputPipe[0]) == 0,
              posix_spawn_file_actions_addclose(&actions, errorPipe[0]) == 0,
              posix_spawn_file_actions_addclose(&actions, outputPipe[1]) == 0,
              posix_spawn_file_actions_addclose(&actions, errorPipe[1]) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
            closePipes()
            throw POSIXError(.EIO)
        }

        var processID: pid_t = 0
        let launchArguments = [executable] + arguments
        let environmentEntries = environment.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
        let result = withContainerCStringArray(launchArguments) { argv in
            withContainerCStringArray(environmentEntries) { environmentPointer in
                posix_spawn(
                    &processID,
                    executable,
                    &actions,
                    &attributes,
                    argv,
                    environmentPointer
                )
            }
        }
        guard result == 0 else {
            closePipes()
            throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO)
        }

        Darwin.close(outputPipe[1])
        outputPipe[1] = -1
        Darwin.close(errorPipe[1])
        errorPipe[1] = -1
        for descriptor in [outputPipe[0], errorPipe[0]] {
            let flags = fcntl(descriptor, F_GETFL)
            if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) }
        }
        return LaunchResult(
            processID: processID,
            outputDescriptor: outputPipe[0],
            errorDescriptor: errorPipe[0]
        )
    }

    private static func exitCode(from status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }
}

private func withContainerCStringArray<Result>(
    _ strings: [String],
    _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
) -> Result {
    var pointers = strings.map { strdup($0) } + [nil]
    defer { pointers.compactMap { $0 }.forEach { free($0) } }
    return pointers.withUnsafeMutableBufferPointer { buffer in
        body(buffer.baseAddress!)
    }
}
