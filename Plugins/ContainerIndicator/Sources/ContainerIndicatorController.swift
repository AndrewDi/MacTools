import Combine
import Foundation
import MacToolsPluginKit

/// Main-actor state owner for the panel: it reads the `container` CLI into an
/// immutable snapshot and applies the quick start/stop operations.
@MainActor
public final class ContainerIndicatorController: ObservableObject {
    public static let pollInterval: TimeInterval = 5

    @Published public private(set) var snapshot: ContainerSnapshot = .unavailable
    @Published public private(set) var commandPath: String?
    @Published public private(set) var isChecking = false
    @Published public private(set) var isPerformingAction = false
    /// Operation failures win over the latest status-check failure, and survive
    /// the follow-up refresh so the user can still read what went wrong.
    @Published public private(set) var operationErrorMessage: String?
    @Published public private(set) var checkErrorMessage: String?

    public var lastErrorMessage: String? {
        operationErrorMessage ?? checkErrorMessage
    }

    public var onStateChange: (() -> Void)?

    private let commandRunner: any ContainerCommandRunning
    private let commandPathProvider: () -> String?
    private let localization: PluginLocalization
    private var pollTask: Task<Void, Never>?
    public private(set) var isMonitoring = false

    public init(
        commandRunner: any ContainerCommandRunning = ContainerCommandRunner(),
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        commandPathProvider: @escaping () -> String? = { ContainerExecutableLocator.locate() }
    ) {
        self.commandRunner = commandRunner
        self.localization = localization
        self.commandPath = commandPathProvider()
        self.commandPathProvider = commandPathProvider
    }

    public var isCommandAvailable: Bool {
        commandPath != nil
    }

    /// Localized service status line shared by the row and the widget card, so
    /// both surfaces always derive the same copy from the same snapshot.
    public var statusText: String {
        guard isCommandAvailable else {
            return localization.string(
                "panel.error.commandNotFound",
                defaultValue: "未找到 container 命令"
            )
        }

        switch snapshot.status {
        case .running:
            return localization.format(
                "panel.subtitle.runningFormat",
                defaultValue: "服务运行中 · %1$d 个容器 · %2$d 个虚拟机",
                snapshot.containers.count,
                snapshot.machines.count
            )
        case .stopped, .unregistered:
            return localization.string("panel.subtitle.stopped", defaultValue: "服务未运行")
        case .unknown:
            return localization.string(
                "panel.subtitle.checking",
                defaultValue: "正在检查服务状态"
            )
        }
    }

    // MARK: - Monitoring

    /// Starts the visibility-scoped polling loop and performs one immediate check.
    public func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        refreshNow()

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isMonitoring else { return }
                try? await Task.sleep(for: .seconds(Self.pollInterval))
                guard !Task.isCancelled else { return }
                await self.refresh()
            }
        }
    }

    public func stopMonitoring() {
        isMonitoring = false
        pollTask?.cancel()
        pollTask = nil
    }

    public func refreshNow() {
        Task { [weak self] in
            await self?.refresh()
        }
    }

    public func refresh() async {
        guard !isPerformingAction else { return }
        resolveCommandPathIfNeeded()
        guard let path = commandPath else {
            publish(.unavailable)
            return
        }

        isChecking = true
        onStateChange?()

        let statusResult: ContainerCommandResult
        do {
            statusResult = try await commandRunner.run(
                executable: path,
                arguments: ["system", "status", "--format", "json"]
            )
        } catch {
            // A spawn/timeout failure is a check failure, not an operation failure.
            isChecking = false
            checkErrorMessage = localization.string(
                "panel.error.commandFailed",
                defaultValue: "命令执行失败"
            )
            publish(ContainerSnapshot(status: .unknown, containers: [], machines: [], updatedAt: Date()))
            return
        }
        let status = ContainerIndicatorParser.serviceStatus(
            exitCode: statusResult.exitCode,
            output: statusResult.standardOutput
        )

        guard status == .running else {
            isChecking = false
            if status == .unknown {
                checkErrorMessage = failureDetail(
                    exitCode: statusResult.exitCode,
                    standardError: statusResult.standardError
                )
            } else {
                checkErrorMessage = nil
            }
            publish(ContainerSnapshot(status: status, containers: [], machines: [], updatedAt: Date()))
            return
        }

        var containers: [ContainerInstance] = []
        let containerResult = try? await commandRunner.run(
            executable: path,
            arguments: ["list", "--all", "--format", "json"]
        )
        if containerResult?.exitCode == 0 {
            containers = ContainerIndicatorParser.containers(fromJSON: containerResult?.standardOutput ?? "")
        }

        var machines: [ContainerMachine] = []
        let machineResult = try? await commandRunner.run(
            executable: path,
            arguments: ["machine", "list", "--format", "json"]
        )
        if machineResult?.exitCode == 0 {
            machines = ContainerIndicatorParser.machines(fromJSON: machineResult?.standardOutput ?? "")
        }

        // Machine images only exist in per-machine inspect output; a failed
        // inspect keeps the previously known image instead of clearing it.
        var resolvedMachines: [ContainerMachine] = []
        for machine in machines {
            let inspectResult = try? await commandRunner.run(
                executable: path,
                arguments: ["machine", "inspect", machine.id]
            )
            let image = inspectResult?.exitCode == 0
                ? ContainerIndicatorParser.machineImage(
                    fromInspectJSON: inspectResult?.standardOutput ?? ""
                )
                : ""
            resolvedMachines.append(image.isEmpty ? machine : machine.withImage(image))
        }
        machines = resolvedMachines

        // The image list supplies per-architecture storage sizes; a missing or
        // failed image list only leaves the storage column empty.
        var imageStorage: [String: [String: Int]] = [:]
        let imageResult = try? await commandRunner.run(
            executable: path,
            arguments: ["image", "list", "--format", "json"]
        )
        if imageResult?.exitCode == 0 {
            imageStorage = ContainerIndicatorParser.imageStorageSizes(
                fromJSON: imageResult?.standardOutput ?? ""
            )
        }
        containers = containers.map { container in
            let sizes = imageStorage[container.image]
            let bytes = sizes?[container.architecture]
                ?? sizes?.first { $0.key != "unknown" }?.value
                ?? sizes?.first?.value
            return container.withImageStorage(bytes)
        }

        isChecking = false
        checkErrorMessage = nil
        publish(ContainerSnapshot(
            status: .running,
            containers: containers,
            machines: machines,
            updatedAt: Date()
        ))
    }

    // MARK: - Operations

    public func setServiceRunning(_ running: Bool) {
        perform(sequences: [running ? ["system", "start"] : ["system", "stop"]])
    }

    public func startContainer(id: String) {
        perform(sequences: [["start", id]])
    }

    public func stopContainer(id: String) {
        perform(sequences: [["stop", id]])
    }

    /// Restart stops first and only starts when the stop succeeded, so a failed
    /// stop never races a duplicate start.
    public func restartContainer(id: String) {
        perform(sequences: [["stop", id], ["start", id]])
    }

    public func startMachine(id: String) {
        perform(sequences: [["machine", "run", "-n", id, "-d"]])
    }

    public func stopMachine(id: String) {
        perform(sequences: [["machine", "stop", id]])
    }

    public func restartMachine(id: String) {
        perform(sequences: [
            ["machine", "stop", id],
            ["machine", "run", "-n", id, "-d"],
        ])
    }

    /// Runs a command sequence as one operation: it stops at the first failure
    /// and publishes exactly one outcome, then refreshes the snapshot.
    private func perform(sequences: [[String]]) {
        guard !isPerformingAction else { return }
        resolveCommandPathIfNeeded()
        guard let path = commandPath else {
            operationErrorMessage = localization.string(
                "panel.error.commandNotFound",
                defaultValue: "未找到 container 命令"
            )
            onStateChange?()
            return
        }

        isPerformingAction = true
        operationErrorMessage = nil
        onStateChange?()

        Task { [weak self] in
            guard let self else { return }
            var failure: String?
            for arguments in sequences {
                do {
                    let result = try await commandRunner.run(executable: path, arguments: arguments)
                    if result.exitCode != 0 {
                        failure = failureDetail(exitCode: result.exitCode, standardError: result.standardError)
                        break
                    }
                } catch {
                    failure = localization.format(
                        "panel.error.actionFailedFormat",
                        defaultValue: "操作失败：%@",
                        error.localizedDescription
                    )
                    break
                }
            }
            isPerformingAction = false
            operationErrorMessage = failure
            onStateChange?()
            await refresh()
        }
    }

    // MARK: - Helpers

    private func publish(_ newSnapshot: ContainerSnapshot) {
        if snapshot != newSnapshot {
            snapshot = newSnapshot
        }
        onStateChange?()
    }

    private func resolveCommandPathIfNeeded() {
        guard commandPath == nil else { return }
        commandPath = commandPathProvider()
    }

    private func failureDetail(exitCode: Int32, standardError: String) -> String? {
        guard exitCode != 0 else { return nil }

        let lines = standardError
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let detail = lines.first.map { String($0.prefix(160)) }
            ?? localization.string("panel.error.commandFailed", defaultValue: "命令执行失败")
        return localization.format(
            "panel.error.actionFailedFormat",
            defaultValue: "操作失败：%@",
            detail
        )
    }
}
