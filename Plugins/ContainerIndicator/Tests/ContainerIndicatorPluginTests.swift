import MacToolsPluginKit
import XCTest
@testable import ContainerIndicatorPlugin

@MainActor
final class ContainerIndicatorPluginTests: XCTestCase {
    func testParserReadsServiceStatusFromSystemStatusOutput() {
        XCTAssertEqual(
            ContainerIndicatorParser.serviceStatus(
                exitCode: 0,
                output: #"{"status":"running","statusMessage":"ready"}"#
            ),
            .running
        )
        // The `container` CLI reports a stopped service with exit code 1.
        XCTAssertEqual(ContainerIndicatorParser.serviceStatus(exitCode: 1, output: ""), .stopped)
        XCTAssertEqual(ContainerIndicatorParser.serviceStatus(exitCode: 2, output: ""), .unknown)
        XCTAssertEqual(ContainerIndicatorParser.serviceStatus(exitCode: 0, output: "not json"), .unknown)
    }

    func testParserReadsContainersAndMachines() {
        let containers = ContainerIndicatorParser.containers(fromJSON: """
        [
          {
            "id": "abc123",
            "configuration": {
              "id": "web",
              "image": {"reference": "docker.io/library/nginx:latest"},
              "resources": {"cpus": 4, "cpuOverhead": 1, "memoryInBytes": 1073741824},
              "platform": {"architecture": "arm64", "os": "linux"}
            },
            "status": {"state": "running"}
          },
          {"id": "def456", "status": {"state": "stopped"}}
        ]
        """)
        XCTAssertEqual(containers.count, 2)
        XCTAssertEqual(containers[0].id, "abc123")
        XCTAssertEqual(containers[0].name, "web")
        XCTAssertEqual(containers[0].image, "docker.io/library/nginx:latest")
        XCTAssertTrue(containers[0].isRunning)
        XCTAssertEqual(containers[0].cpus, 4)
        XCTAssertEqual(containers[0].memoryBytes, 1073741824)
        XCTAssertEqual(containers[0].architecture, "arm64")
        XCTAssertNil(containers[0].imageStorageBytes)
        XCTAssertEqual(containers[1].name, "def456", "A missing configuration id falls back to the container id")
        XCTAssertEqual(containers[1].cpus, 0, "A missing resources block falls back to zero")
        XCTAssertFalse(containers[1].isRunning)
        XCTAssertTrue(ContainerIndicatorParser.containers(fromJSON: "not json").isEmpty)

        let machines = ContainerIndicatorParser.machines(fromJSON: """
        [
          {"id": "default", "status": "Running", "default": true,
           "cpus": 4, "memory": 8589934592, "diskSize": 1838170112},
          {"id": "legacy", "status": "stopped"}
        ]
        """)
        XCTAssertEqual(machines.count, 2)
        XCTAssertEqual(machines[0].name, "default")
        XCTAssertTrue(machines[0].isDefault)
        XCTAssertTrue(machines[0].isRunning)
        XCTAssertEqual(machines[0].cpus, 4)
        XCTAssertEqual(machines[0].memoryBytes, 8589934592)
        XCTAssertEqual(machines[0].diskSizeBytes, 1838170112)
        XCTAssertFalse(machines[1].isDefault)
        XCTAssertEqual(machines[1].diskSizeBytes, 0, "A missing diskSize falls back to zero")
        XCTAssertTrue(ContainerIndicatorParser.machines(fromJSON: "not json").isEmpty)
    }

    func testParserReadsImageStorageSizesByArchitecture() {
        let sizes = ContainerIndicatorParser.imageStorageSizes(fromJSON: """
        [
          {
            "configuration": {"name": "docker.io/library/nginx:latest"},
            "variants": [
              {"config": {"architecture": "amd64"}, "size": 100},
              {"config": {"architecture": "arm64"}, "size": 200}
            ]
          },
          {"configuration": {"name": "no-variants"}, "variants": []}
        ]
        """)
        XCTAssertEqual(sizes["docker.io/library/nginx:latest"]?["arm64"], 200)
        XCTAssertEqual(sizes["docker.io/library/nginx:latest"]?["amd64"], 100)
        XCTAssertNil(sizes["no-variants"])
        XCTAssertTrue(ContainerIndicatorParser.imageStorageSizes(fromJSON: "not json").isEmpty)
    }

    func testByteFormattingUsesReadableUnits() {
        XCTAssertEqual(ContainerIndicatorFormatting.bytes(0), "-")
        XCTAssertEqual(ContainerIndicatorFormatting.bytes(1073741824), "1.0 GB")
        XCTAssertEqual(ContainerIndicatorFormatting.bytes(1838170112), "1.7 GB")
        XCTAssertEqual(ContainerIndicatorFormatting.bytes(229149584), "219 MB")
    }

    func testImageLabelKeepsFullReferenceWhenItFits() {
        XCTAssertEqual(
            ContainerIndicatorFormatting.imageLabel(for: "docker.io/library/nginx:latest", fits: true),
            "docker.io/library/nginx:latest",
            "A fitting reference stays complete"
        )
        XCTAssertEqual(
            ContainerIndicatorFormatting.imageLabel(for: "docker.io/library/nginx:latest", fits: false),
            "nginx:latest",
            "A too-long reference falls back to its last path segment"
        )
        XCTAssertEqual(
            ContainerIndicatorFormatting.imageLabel(for: "gaussdb507.1.0:Euler", fits: false),
            "gaussdb507.1.0:Euler",
            "A reference without a path separator has no segment to drop"
        )
    }

    func testPanelExposesOnlyWidgetCard() {
        let plugin = makePlugin(probe: CommandProbe())
        XCTAssertEqual(
            plugin.panelItems.map(\.id),
            ["overview"],
            "The product keeps a single card item; the feature row was removed"
        )
    }

    func testMissingCommandDisablesCardAndRunsNoCommands() async throws {
        let probe = CommandProbe()
        let plugin = makePlugin(probe: probe, commandPath: nil)

        let item = try XCTUnwrap(plugin.panelItems.first { $0.id == "overview" })
        guard case let .widget(widget) = item.content else {
            return XCTFail("Expected a widget item")
        }
        XCTAssertFalse(widget.state.isEnabled, "The card is disabled without the CLI")
        XCTAssertEqual(widget.state.subtitle, "未找到 container 命令")
        let invocations = await probe.recordedInvocations()
        XCTAssertTrue(invocations.isEmpty)
    }

    func testVisibilityStopsPollingWhenLastItemIsHidden() async throws {
        let probe = CommandProbe()
        let plugin = makePlugin(probe: probe)

        let widgetVisibility = try XCTUnwrap(
            plugin.panelItems.first { $0.id == "overview" }?.visibilityHandler
        )

        widgetVisibility(true)
        await waitUntil { await probe.statusQueryCountValue() >= 1 }

        widgetVisibility(false)
        await waitUntil { !plugin.controller.isMonitoring }

        let countAfterStop = await probe.statusQueryCountValue()
        try? await Task.sleep(for: .milliseconds(100))
        let finalCount = await probe.statusQueryCountValue()
        XCTAssertEqual(countAfterStop, finalCount, "A hidden panel must not keep polling the CLI")
    }

    func testCardStateShowsRunningCountsAndServiceToggleConverges() async throws {
        let probe = CommandProbe()
        await probe.stubService(exitCode: 0, output: #"{"status":"running"}"#)
        await probe.stubContainers(
            "[{\"id\":\"c1\",\"status\":{\"state\":\"running\"}},{\"id\":\"c2\",\"status\":{\"state\":\"stopped\"}}]"
        )
        await probe.stubMachines("[{\"id\":\"default\",\"status\":\"Running\",\"default\":true}]")
        let plugin = makePlugin(probe: probe)

        plugin.activate(context: PluginRuntimeContext(pluginID: "container-indicator"))
        await waitUntil { plugin.controller.snapshot.status == .running }

        let item = try XCTUnwrap(plugin.panelItems.first { $0.id == "overview" })
        guard case let .widget(widget) = item.content else {
            return XCTFail("Expected a widget item")
        }
        XCTAssertTrue(widget.state.isActive)
        XCTAssertEqual(widget.state.subtitle, "服务运行中 · 2 个容器 · 1 个虚拟机")

        // The card's service control reports the real outcome instead of
        // flipping optimistically.
        plugin.controller.setServiceRunning(false)
        await waitUntil { await probe.recordedInvocations().contains(["system", "stop"]) }
        await waitUntil { plugin.controller.snapshot.status == .stopped }

        let updated = try XCTUnwrap(plugin.panelItems.first { $0.id == "overview" })
        guard case let .widget(updatedWidget) = updated.content else {
            return XCTFail("Expected a widget item after the toggle")
        }
        XCTAssertFalse(updatedWidget.state.isActive)
        XCTAssertEqual(updatedWidget.state.subtitle, "服务未运行")
    }

    func testFailedOperationSurfacesCommandError() async {
        let probe = CommandProbe()
        await probe.stubCommandResult(
            arguments: ["system", "start"],
            exitCode: 64,
            error: "error: unknown command start"
        )
        let plugin = makePlugin(probe: probe)

        plugin.controller.setServiceRunning(true)
        await waitUntil { plugin.controller.lastErrorMessage != nil }
        XCTAssertEqual(plugin.controller.lastErrorMessage, "操作失败：error: unknown command start")
        XCTAssertFalse(plugin.controller.isPerformingAction)
    }

    func testWidgetRendersListInlineWithoutDetailPopup() throws {
        let probe = CommandProbe()
        let plugin = makePlugin(probe: probe)

        let item = try XCTUnwrap(plugin.panelItems.first { $0.id == "overview" })
        guard case let .widget(widget) = item.content else {
            return XCTFail("Expected a widget item")
        }
        XCTAssertNil(
            widget.makeDetail,
            "The container list renders inline in the panel, so the widget has no detail popup"
        )
    }

    func testRefreshResolvesContainerImageStorage() async throws {
        let probe = CommandProbe()
        await probe.stubService(exitCode: 0, output: #"{"status":"running"}"#)
        await probe.stubContainers(
            """
            [{"id":"c1","configuration":{"id":"web",\
            "image":{"reference":"docker.io/library/nginx:latest"},\
            "resources":{"cpus":2,"memoryInBytes":536870912},\
            "platform":{"architecture":"arm64"}},\
            "status":{"state":"running"}}]
            """
        )
        await probe.stubImages(
            """
            [{"configuration":{"name":"docker.io/library/nginx:latest"},\
            "variants":[{"config":{"architecture":"arm64"},"size":229149584}]}]
            """
        )
        let plugin = makePlugin(probe: probe)

        plugin.activate(context: PluginRuntimeContext(pluginID: "container-indicator"))
        await waitUntil { plugin.controller.snapshot.containers.first?.imageStorageBytes != nil }

        let container = try XCTUnwrap(plugin.controller.snapshot.containers.first)
        XCTAssertEqual(container.imageStorageBytes, 229149584)
        XCTAssertEqual(container.cpus, 2)
        XCTAssertEqual(container.memoryBytes, 536870912)
    }

    func testRefreshResolvesMachineImageFromInspect() async throws {
        let probe = CommandProbe()
        await probe.stubService(exitCode: 0, output: #"{"status":"running"}"#)
        await probe.stubMachines(
            """
            [{"id":"default","status":"Running","default":true,\
            "cpus":4,"memory":8589934592,"diskSize":1838170112}]
            """
        )
        await probe.stubMachineInspect(
            "default",
            """
            [{"id":"default",\
            "image":{"reference":"cr.kylinos.cn/kylin/kylin-server-init:v11-2503"}}]
            """
        )
        let plugin = makePlugin(probe: probe)

        plugin.activate(context: PluginRuntimeContext(pluginID: "container-indicator"))
        await waitUntil { plugin.controller.snapshot.machines.first?.image.isEmpty == false }

        let machine = try XCTUnwrap(plugin.controller.snapshot.machines.first)
        XCTAssertEqual(
            machine.image,
            "cr.kylinos.cn/kylin/kylin-server-init:v11-2503",
            "The machine subtitle shows the boot image resolved from inspect"
        )
    }

    func testContainerRestartRunsStopThenStart() async {
        let probe = CommandProbe()
        let controller = makeController(probe: probe)

        controller.restartContainer(id: "c1")
        await waitUntil {
            let invocations = await probe.recordedInvocations()
            return invocations.contains(["stop", "c1"]) && invocations.contains(["start", "c1"])
        }

        let invocations = await probe.recordedInvocations()
        XCTAssertEqual(
            Array(invocations.prefix(2)),
            [["stop", "c1"], ["start", "c1"]],
            "Restart must stop first and only then start"
        )
    }

    func testContainerRestartAbortsWhenStopFails() async {
        let probe = CommandProbe()
        await probe.stubCommandResult(
            arguments: ["stop", "c1"],
            exitCode: 64,
            error: "error: container is not running"
        )
        let controller = makeController(probe: probe)

        controller.restartContainer(id: "c1")
        await waitUntil { controller.lastErrorMessage != nil }

        let invocations = await probe.recordedInvocations()
        XCTAssertEqual(invocations.first, ["stop", "c1"])
        XCTAssertFalse(
            invocations.contains(["start", "c1"]),
            "A failed stop must abort the sequence instead of starting anyway"
        )
        XCTAssertEqual(controller.lastErrorMessage, "操作失败：error: container is not running")
        XCTAssertFalse(controller.isPerformingAction)
    }

    // MARK: - Helpers

    private func makeController(
        probe: CommandProbe,
        commandPath: String? = "/opt/homebrew/bin/container"
    ) -> ContainerIndicatorController {
        ContainerIndicatorController(
            commandRunner: probe,
            localization: PluginLocalization(bundle: .main),
            commandPathProvider: { commandPath }
        )
    }

    private func makePlugin(
        probe: CommandProbe,
        commandPath: String? = "/opt/homebrew/bin/container"
    ) -> ContainerIndicatorPlugin {
        let controller = makeController(probe: probe, commandPath: commandPath)
        return ContainerIndicatorPlugin(
            controller: controller,
            localization: PluginLocalization(bundle: .main)
        )
    }

    private func waitUntil(
        _ condition: @MainActor () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<40 {
            if await condition() {
                return
            }
            await Task.yield()
        }

        try? await Task.sleep(for: .milliseconds(50))
        let stillPending = await condition()
        XCTAssertTrue(stillPending, file: file, line: line)
    }
}

/// Scripted CLI stand-in that records every invocation. Successful service
/// start/stop commands flip the stubbed status so follow-up refreshes converge.
private actor CommandProbe: ContainerCommandRunning {
    private var invocations: [[String]] = []
    private var serviceExitCode: Int32 = 1
    private var serviceOutput = ""
    private var containersOutput = "[]"
    private var machinesOutput = "[]"
    private var imagesOutput = "[]"
    private var machineInspectOutputs: [String: String] = [:]
    private var overrides: [String: ContainerCommandResult] = [:]

    func stubService(exitCode: Int32, output: String) {
        serviceExitCode = exitCode
        serviceOutput = output
    }

    func stubContainers(_ output: String) {
        containersOutput = output
    }

    func stubMachines(_ output: String) {
        machinesOutput = output
    }

    func stubImages(_ output: String) {
        imagesOutput = output
    }

    func stubMachineInspect(_ id: String, _ output: String) {
        machineInspectOutputs[id] = output
    }

    func stubCommandResult(arguments: [String], exitCode: Int32, error: String = "") {
        overrides[arguments.joined(separator: " ")] = ContainerCommandResult(
            exitCode: exitCode,
            standardOutput: "",
            standardError: error
        )
    }

    nonisolated func run(executable: String, arguments: [String]) async throws -> ContainerCommandResult {
        await record(arguments)
        if let override = await resultOverride(for: arguments) {
            return override
        }
        if arguments.count == 3, arguments[0] == "machine", arguments[1] == "inspect" {
            return ContainerCommandResult(
                exitCode: 0,
                standardOutput: await machineInspectValue(for: arguments[2]),
                standardError: ""
            )
        }
        switch arguments {
        case ["system", "status", "--format", "json"]:
            return ContainerCommandResult(
                exitCode: await serviceExitCodeValue(),
                standardOutput: await serviceOutputValue(),
                standardError: ""
            )
        case ["list", "--all", "--format", "json"]:
            return ContainerCommandResult(exitCode: 0, standardOutput: await containersOutputValue(), standardError: "")
        case ["machine", "list", "--format", "json"]:
            return ContainerCommandResult(exitCode: 0, standardOutput: await machinesOutputValue(), standardError: "")
        case ["image", "list", "--format", "json"]:
            return ContainerCommandResult(exitCode: 0, standardOutput: await imagesOutputValue(), standardError: "")
        case ["system", "stop"]:
            await applyServiceState(exitCode: 1, output: "")
            return ContainerCommandResult(exitCode: 0, standardOutput: "", standardError: "")
        case ["system", "start"]:
            await applyServiceState(exitCode: 0, output: #"{"status":"running"}"#)
            return ContainerCommandResult(exitCode: 0, standardOutput: "", standardError: "")
        default:
            return ContainerCommandResult(exitCode: 0, standardOutput: "", standardError: "")
        }
    }

    func recordedInvocations() -> [[String]] {
        invocations
    }

    func statusQueryCountValue() -> Int {
        invocations.filter { $0 == ["system", "status", "--format", "json"] }.count
    }

    private func record(_ arguments: [String]) {
        invocations.append(arguments)
    }

    private func resultOverride(for arguments: [String]) -> ContainerCommandResult? {
        overrides[arguments.joined(separator: " ")]
    }

    private func applyServiceState(exitCode: Int32, output: String) {
        serviceExitCode = exitCode
        serviceOutput = output
    }

    private func serviceExitCodeValue() -> Int32 { serviceExitCode }
    private func serviceOutputValue() -> String { serviceOutput }
    private func containersOutputValue() -> String { containersOutput }
    private func machinesOutputValue() -> String { machinesOutput }
    private func imagesOutputValue() -> String { imagesOutput }
    private func machineInspectValue(for id: String) -> String {
        machineInspectOutputs[id] ?? ""
    }
}
