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

    func testFailedListReadKeepsPreviousEntriesAndReportsWhy() async {
        let probe = CommandProbe()
        await probe.stubService(exitCode: 0, output: #"{"status":"running"}"#)
        await probe.stubContainers(
            "[{\"id\":\"c1\",\"configuration\":{\"id\":\"web\"},\"status\":{\"state\":\"running\"}}]"
        )
        await probe.stubMachines("[{\"id\":\"kylin\",\"status\":\"Running\"}]")
        let controller = makeController(probe: probe)

        await controller.refresh()
        XCTAssertEqual(controller.snapshot.containers.count, 1)
        XCTAssertEqual(controller.snapshot.machines.count, 1)
        XCTAssertNil(controller.snapshot.containersFailure)
        XCTAssertNil(controller.snapshot.machinesFailure)

        // The daemon still reports the service as running but stops answering
        // the list commands.
        await probe.stubCommandResult(
            arguments: ["list", "--all", "--format", "json"],
            exitCode: 1,
            error: "error: daemon not reachable"
        )
        await probe.stubCommandResult(
            arguments: ["machine", "list", "--format", "json"],
            exitCode: 1,
            error: "error: daemon not reachable"
        )
        await controller.refresh()

        XCTAssertEqual(
            controller.snapshot.containers.count,
            1,
            "A failed read must keep the last successful entries, not blank the list"
        )
        XCTAssertEqual(controller.snapshot.machines.count, 1)
        XCTAssertEqual(
            controller.snapshot.containersFailure,
            "容器列表读取失败：error: daemon not reachable",
            "The card explains the failure instead of presenting an empty list"
        )
        XCTAssertEqual(
            controller.snapshot.machinesFailure,
            "虚拟机列表读取失败：error: daemon not reachable"
        )
    }

    func testNewerRefreshDiscardsResultsFromAnOlderOne() async throws {
        let probe = CommandProbe()
        await probe.stubService(exitCode: 0, output: #"{"status":"running"}"#)
        await probe.stubContainers(
            "[{\"id\":\"c1\",\"configuration\":{\"id\":\"web\"},\"status\":{\"state\":\"running\"}}]"
        )
        await probe.holdCommand(["list", "--all", "--format", "json"])
        let controller = makeController(probe: probe)

        let olderRefresh = Task { await controller.refresh() }
        await waitUntil {
            await probe.invocationCount(for: ["list", "--all", "--format", "json"]) >= 1
        }

        // The service stops while the older refresh is still waiting on its list.
        await probe.stubService(exitCode: 1, output: "")
        await controller.refresh()

        XCTAssertEqual(controller.snapshot.status, .stopped)
        XCTAssertTrue(controller.snapshot.containers.isEmpty)

        // Releasing the held read must not resurrect the older snapshot.
        await probe.releaseCommand(["list", "--all", "--format", "json"])
        await olderRefresh.value

        XCTAssertEqual(
            controller.snapshot.status,
            .stopped,
            "A superseded refresh must not publish its outdated result"
        )
        XCTAssertTrue(controller.snapshot.containers.isEmpty)
    }

    func testHidingThePanelCancelsTheRunningStatusCommand() async {
        let probe = CommandProbe()
        await probe.stubService(exitCode: 0, output: #"{"status":"running"}"#)
        await probe.holdCommand(["system", "status", "--format", "json"])
        let controller = makeController(probe: probe)

        controller.startMonitoring()
        await waitUntil {
            await probe.invocationCount(for: ["system", "status", "--format", "json"]) >= 1
        }

        controller.stopMonitoring()
        await waitUntil {
            await probe.wasCancelled(["system", "status", "--format", "json"])
        }

        // Releasing the held command must not publish a hidden panel's refresh.
        await probe.releaseCommand(["system", "status", "--format", "json"])
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(
            controller.snapshot.status,
            .unknown,
            "A cancelled refresh must not publish after the panel is hidden"
        )
        XCTAssertFalse(controller.isChecking)
        XCTAssertFalse(controller.isMonitoring)
    }

    // MARK: - Configuration and live performance

    func testParserReadsFullContainerConfiguration() throws {
        let containers = ContainerIndicatorParser.containers(fromJSON: """
        [{
          "id": "abc123",
          "configuration": {
            "id": "web",
            "image": {
              "reference": "docker.io/library/nginx:latest",
              "descriptor": {"digest": "sha256:deadbeef"}
            },
            "initProcess": {
              "executable": "/usr/sbin/nginx",
              "arguments": ["-g", "daemon off;"],
              "environment": ["PATH=/usr/bin", "DB_PASSWORD=secret"],
              "workingDirectory": "/app",
              "user": {"raw": {"userString": "www-data"}}
            },
            "publishedPorts": [
              {"hostAddress": "127.0.0.1", "hostPort": 8080, "containerPort": 80, "proto": "tcp"}
            ],
            "mounts": [{"type": "bind", "source": "/tmp/data", "destination": "/data"}],
            "networks": [{"network": "default", "options": {"hostname": "web-host", "mtu": 1500}}],
            "dns": {"domain": "example.test", "nameservers": ["1.1.1.1"]},
            "platform": {"os": "linux", "architecture": "arm64"},
            "runtimeHandler": "container-runtime",
            "readOnly": true,
            "rosetta": false,
            "ssh": true,
            "creationDate": "2026-10-01T12:00:00Z",
            "resources": {"cpus": 4, "memoryInBytes": 1073741824, "storage": 10737418240}
          },
          "status": {"state": "running"}
        }]
        """)

        let configuration = try XCTUnwrap(containers.first).configuration
        XCTAssertEqual(configuration.command, "/usr/sbin/nginx -g daemon off;")
        XCTAssertEqual(configuration.workingDirectory, "/app")
        XCTAssertEqual(configuration.user, "www-data")
        XCTAssertEqual(
            configuration.environmentKeys,
            ["PATH", "DB_PASSWORD"],
            "Only variable names are kept so secrets never reach the UI"
        )
        XCTAssertEqual(configuration.ports, ["127.0.0.1:8080 → 80/tcp"])
        XCTAssertEqual(configuration.mounts, ["/tmp/data → /data"])
        XCTAssertEqual(configuration.networks, ["default"])
        XCTAssertEqual(configuration.hostname, "web-host")
        XCTAssertEqual(configuration.dnsDomain, "example.test")
        XCTAssertEqual(configuration.dnsServers, ["1.1.1.1"])
        XCTAssertEqual(configuration.platform, "linux/arm64")
        XCTAssertEqual(configuration.runtimeHandler, "container-runtime")
        XCTAssertTrue(configuration.readOnly)
        XCTAssertFalse(configuration.rosetta)
        XCTAssertTrue(configuration.ssh)
        XCTAssertEqual(configuration.imageDigest, "sha256:deadbeef")
        XCTAssertNotNil(configuration.createdAt)
        XCTAssertEqual(configuration.storageQuotaBytes, 10737418240)
    }

    func testParserReadsStatsCounters() throws {
        let counters = ContainerIndicatorParser.stats(fromJSON: """
        [{
          "id": "abc123",
          "cpuUsageUsec": 1500000,
          "memoryUsageBytes": 2048,
          "memoryLimitBytes": 4096,
          "blockReadBytes": 100,
          "blockWriteBytes": 200,
          "networkRxBytes": 300,
          "networkTxBytes": 400,
          "numProcesses": 5
        }]
        """)

        let counter = try XCTUnwrap(counters["abc123"])
        XCTAssertEqual(counter.cpuUsageUsec, 1_500_000)
        XCTAssertEqual(counter.memoryUsageBytes, 2048)
        XCTAssertEqual(counter.memoryLimitBytes, 4096)
        XCTAssertEqual(counter.blockReadBytes, 100)
        XCTAssertEqual(counter.blockWriteBytes, 200)
        XCTAssertEqual(counter.networkRxBytes, 300)
        XCTAssertEqual(counter.networkTxBytes, 400)
        XCTAssertEqual(counter.numProcesses, 5)
        XCTAssertTrue(ContainerIndicatorParser.stats(fromJSON: "not json").isEmpty)
    }

    func testStatsMathDerivesQuotaRelativeCPUAndRates() {
        // Four CPU seconds used over four wall seconds on two cores: both
        // allotted cores were busy half the time.
        XCTAssertEqual(
            ContainerIndicatorStatsMath.cpuPercent(
                previous: 1_000_000,
                current: 5_000_000,
                elapsed: 4,
                cores: 2
            ) ?? -1,
            50,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ContainerIndicatorStatsMath.rate(previous: 1000, current: 5000, elapsed: 2) ?? -1,
            2000,
            accuracy: 0.001
        )
    }

    func testStatsMathRejectsFirstSampleResetsAndEmptyInterval() {
        XCTAssertNil(
            ContainerIndicatorStatsMath.cpuPercent(
                previous: nil, current: 1_000_000, elapsed: 5, cores: 2
            ),
            "The first sample has no baseline"
        )
        XCTAssertNil(
            ContainerIndicatorStatsMath.cpuPercent(
                previous: 5_000_000, current: 1_000_000, elapsed: 5, cores: 2
            ),
            "A counter reset must not turn into a negative percentage"
        )
        XCTAssertNil(
            ContainerIndicatorStatsMath.cpuPercent(
                previous: 1_000_000, current: 2_000_000, elapsed: 0, cores: 2
            )
        )
        XCTAssertNil(
            ContainerIndicatorStatsMath.rate(previous: 5000, current: 1000, elapsed: 2)
        )
    }

    func testSecondRefreshAddsLivePerformance() async throws {
        let probe = CommandProbe()
        await probe.stubService(exitCode: 0, output: #"{"status":"running"}"#)
        await probe.stubContainers(
            """
            [{"id":"c1","configuration":{"id":"web","resources":{"cpus":2}},\
            "status":{"state":"running"}}]
            """
        )
        await probe.stubStats(output: statsJSON(cpu: 1_000_000, read: 1000, write: 2000))
        var clock = Date(timeIntervalSince1970: 1000)
        let controller = makeController(probe: probe, now: { clock })

        await controller.refresh()
        let first = try XCTUnwrap(controller.snapshot.containers.first?.performance)
        XCTAssertEqual(first.memoryBytes, 2048)
        XCTAssertNil(first.cpuPercent, "CPU needs two samples before it can be derived")
        XCTAssertNil(first.diskReadBytesPerSecond)

        clock.addTimeInterval(4)
        await probe.stubStats(output: statsJSON(cpu: 5_000_000, read: 5000, write: 10_000))
        await controller.refresh()

        let second = try XCTUnwrap(controller.snapshot.containers.first?.performance)
        XCTAssertEqual(second.cpuPercent ?? -1, 50, accuracy: 0.001)
        XCTAssertEqual(second.diskReadBytesPerSecond ?? -1, 1000, accuracy: 0.001)
        XCTAssertEqual(second.diskWriteBytesPerSecond ?? -1, 2000, accuracy: 0.001)
        XCTAssertNil(controller.snapshot.statsFailure)
    }

    func testStatsFailureKeepsPreviousPerformanceAndReportsWhy() async throws {
        let probe = CommandProbe()
        await probe.stubService(exitCode: 0, output: #"{"status":"running"}"#)
        await probe.stubContainers(
            """
            [{"id":"c1","configuration":{"id":"web","resources":{"cpus":2}},\
            "status":{"state":"running"}}]
            """
        )
        await probe.stubStats(output: statsJSON(cpu: 1_000_000, read: 1000, write: 2000))
        let controller = makeController(probe: probe)

        await controller.refresh()
        XCTAssertEqual(controller.snapshot.containers.first?.performance?.memoryBytes, 2048)

        await probe.stubStats(exitCode: 1, output: "", error: "error: stats unavailable")
        await controller.refresh()

        XCTAssertEqual(
            controller.snapshot.statsFailure,
            "性能数据读取失败：error: stats unavailable"
        )
        XCTAssertEqual(
            controller.snapshot.containers.first?.performance?.memoryBytes,
            2048,
            "A failed stats read keeps the last numbers on screen"
        )
    }

    func testStatsCommandIsSkippedWhenNothingRuns() async {
        let probe = CommandProbe()
        await probe.stubService(exitCode: 0, output: #"{"status":"running"}"#)
        await probe.stubContainers(
            "[{\"id\":\"c1\",\"configuration\":{\"id\":\"web\"},\"status\":{\"state\":\"stopped\"}}]"
        )
        let controller = makeController(probe: probe)

        await controller.refresh()

        let invocations = await probe.recordedInvocations()
        XCTAssertFalse(
            invocations.contains(["stats", "--format", "json", "--no-stream"]),
            "A stopped container must not pay the two-second stats sampling cost"
        )
        XCTAssertNil(controller.snapshot.containers.first?.performance)
    }

    // MARK: - Terminal

    func testContainerTerminalScriptPrefersBashAndFallsBackToShell() {
        let script = ContainerTerminalLauncher.script(
            for: .container(id: "web"),
            executable: "/opt/homebrew/bin/container"
        )
        XCTAssertTrue(script.contains("CONTAINER='/opt/homebrew/bin/container'"))
        XCTAssertTrue(script.contains("ID='web'"))
        XCTAssertTrue(script.contains("exec -it \"$ID\" /bin/bash"))
        XCTAssertTrue(script.contains("exec -it \"$ID\" /bin/sh"))
        XCTAssertTrue(script.contains("test -x /bin/bash"))
    }

    func testMachineTerminalScriptUsesMachineRun() {
        let script = ContainerTerminalLauncher.script(
            for: .machine(id: "default"),
            executable: "/opt/homebrew/bin/container"
        )
        XCTAssertTrue(script.contains("exec '/opt/homebrew/bin/container' machine run -n 'default'"))
        XCTAssertFalse(script.contains("exec -it"))
    }

    func testShellQuotingEscapesEmbeddedQuotes() {
        XCTAssertEqual(ContainerTerminalLauncher.shellQuoted("it's"), #"'it'\''s'"#)
        XCTAssertFalse(
            ContainerTerminalLauncher.isValidIdentifier("web; rm -rf /"),
            "Shell metacharacters never reach the generated script"
        )
        XCTAssertFalse(ContainerTerminalLauncher.isValidIdentifier(""))
        XCTAssertTrue(ContainerTerminalLauncher.isValidIdentifier("web-1.local"))
        XCTAssertFalse(ContainerTerminalLauncher.isValidExecutablePath("container"))
        XCTAssertFalse(ContainerTerminalLauncher.isValidExecutablePath("/usr/bin/container\nrm"))
    }

    func testTerminalLauncherWritesExecutableScriptAndOpensIt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var openedURL: URL?
        let launcher = ContainerTerminalLauncher(
            directory: directory,
            openURL: { url in
                openedURL = url
                return true
            }
        )

        try launcher.launch(
            target: .container(id: "web"),
            executable: "/opt/homebrew/bin/container"
        )

        let url = try XCTUnwrap(openedURL)
        XCTAssertEqual(url.lastPathComponent, "container-web.command")
        let script = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(script.contains("ID='web'"))
        XCTAssertTrue(script.contains("exec -it \"$ID\""))
        let permissions = try FileManager.default
            .attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o755, "The script must be executable by the terminal")
    }

    func testTerminalLauncherRejectsInvalidIdentifierBeforeWriting() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let launcher = ContainerTerminalLauncher(
            directory: directory,
            openURL: { _ in true }
        )

        XCTAssertThrowsError(
            try launcher.launch(
                target: .container(id: "web; rm -rf /"),
                executable: "/opt/homebrew/bin/container"
            )
        ) { error in
            XCTAssertEqual(error as? ContainerTerminalLaunchError, .invalidIdentifier)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testTerminalOpenFailureSurfacesMessage() {
        let probe = CommandProbe()
        let launcher = ContainerTerminalLauncher(openURL: { _ in false })
        let controller = ContainerIndicatorController(
            commandRunner: probe,
            localization: PluginLocalization(bundle: .main),
            commandPathProvider: { "/opt/homebrew/bin/container" },
            terminalLauncher: launcher
        )

        controller.openTerminal(target: .container(id: "web"))

        XCTAssertEqual(controller.lastErrorMessage, "无法打开终端")
    }

    func testTerminalOpenRejectsInvalidIdentifierWithClearMessage() {
        let probe = CommandProbe()
        let controller = ContainerIndicatorController(
            commandRunner: probe,
            localization: PluginLocalization(bundle: .main),
            commandPathProvider: { "/opt/homebrew/bin/container" }
        )

        controller.openTerminal(target: .container(id: "web; rm -rf /"))

        XCTAssertEqual(controller.lastErrorMessage, "容器标识无效")
    }

    // MARK: - Helpers

    private func statsJSON(
        cpu: UInt64,
        read: UInt64,
        write: UInt64,
        memory: UInt64 = 2048,
        limit: UInt64 = 4096
    ) -> String {
        """
        [{"id":"c1","cpuUsageUsec":\(cpu),"memoryUsageBytes":\(memory),\
        "memoryLimitBytes":\(limit),"blockReadBytes":\(read),\
        "blockWriteBytes":\(write),"networkRxBytes":0,"networkTxBytes":0,\
        "numProcesses":3}]
        """
    }

    private func makeController(
        probe: CommandProbe,
        commandPath: String? = "/opt/homebrew/bin/container",
        now: @escaping () -> Date = Date.init
    ) -> ContainerIndicatorController {
        ContainerIndicatorController(
            commandRunner: probe,
            localization: PluginLocalization(bundle: .main),
            commandPathProvider: { commandPath },
            now: now
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
    private var statsOutput = "[]"
    private var statsExitCode: Int32 = 0
    private var statsError = ""
    private var machineInspectOutputs: [String: String] = [:]
    private var overrides: [String: ContainerCommandResult] = [:]
    private var heldCommands: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var cancelledCommands: Set<String> = []

    /// Blocks the command until `releaseCommand` is called, so a test can
    /// interleave a newer refresh with one that is still in flight.
    func holdCommand(_ arguments: [String]) {
        heldCommands.insert(Self.key(arguments))
    }

    func releaseCommand(_ arguments: [String]) {
        let key = Self.key(arguments)
        heldCommands.remove(key)
        let pending = waiters.removeValue(forKey: key) ?? []
        pending.forEach { $0.resume() }
    }

    func invocationCount(for arguments: [String]) -> Int {
        invocations.filter { $0 == arguments }.count
    }

    func wasCancelled(_ arguments: [String]) -> Bool {
        cancelledCommands.contains(Self.key(arguments))
    }

    private static func key(_ arguments: [String]) -> String {
        arguments.joined(separator: " ")
    }

    /// The hold records cancellation but keeps the command suspended, so a test
    /// can prove the refresh discarded a result it no longer owned.
    private func waitWhileHeld(_ arguments: [String]) async {
        let key = Self.key(arguments)
        guard heldCommands.contains(key) else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiters[key, default: []].append(continuation)
            }
        } onCancel: {
            Task { await self.noteCancellation(key) }
        }
    }

    private func noteCancellation(_ key: String) {
        cancelledCommands.insert(key)
    }

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

    func stubStats(exitCode: Int32 = 0, output: String, error: String = "") {
        statsExitCode = exitCode
        statsOutput = output
        statsError = error
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
        await waitWhileHeld(arguments)
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
        case ["stats", "--format", "json", "--no-stream"]:
            return ContainerCommandResult(
                exitCode: await statsExitCodeValue(),
                standardOutput: await statsOutputValue(),
                standardError: await statsErrorValue()
            )
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
    private func statsExitCodeValue() -> Int32 { statsExitCode }
    private func statsOutputValue() -> String { statsOutput }
    private func statsErrorValue() -> String { statsError }
    private func machineInspectValue(for id: String) -> String {
        machineInspectOutputs[id] ?? ""
    }
}
