import AppKit
import MacToolsPluginKit
import SwiftUI

// MARK: - Presenter

/// Owns the single configuration window. The window observes the controller, so
/// it keeps showing live numbers while it stays open.
@MainActor
final class ContainerIndicatorDetailPresenter {
    private var window: ContainerIndicatorDetailWindow?

    /// Called when the window appears and when the user closes it, so the
    /// plugin can keep polling while the inspector is on screen.
    var onVisibilityChange: ((Bool) -> Void)?

    var isPresenting: Bool {
        window?.isVisible == true
    }

    func present(
        container: ContainerInstance,
        controller: ContainerIndicatorController,
        localization: PluginLocalization
    ) {
        close()

        let window = ContainerIndicatorDetailWindow(
            containerID: container.id,
            title: container.name,
            controller: controller,
            localization: localization
        )
        window.onDismiss = { [weak self] in
            self?.window = nil
            self?.onVisibilityChange?(false)
        }

        PluginPresentationSafety.prepareForWindowOrdering(window)
        position(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        onVisibilityChange?(true)
    }

    /// Programmatic close (plugin deactivation); does not report visibility,
    /// because the caller already owns the monitoring decision.
    func close() {
        guard let window else { return }
        window.onDismiss = nil
        window.orderOut(nil)
        self.window = nil
    }

    private func position(_ window: NSWindow) {
        let pointerLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointerLocation) } ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2
        ))
    }
}

// MARK: - Window

@MainActor
final class ContainerIndicatorDetailWindow: NSPanel {
    var onDismiss: (() -> Void)?

    init(
        containerID: String,
        title: String,
        controller: ContainerIndicatorController,
        localization: PluginLocalization
    ) {
        let size = NSSize(width: 520, height: 620)
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )

        self.title = title
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .windowBackgroundColor
        minSize = NSSize(width: 440, height: 420)
        setContentSize(size)

        contentView = NSHostingView(
            rootView: ContainerIndicatorDetailView(
                containerID: containerID,
                controller: controller,
                localization: localization
            )
        )
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performClose(_ sender: Any?) {
        orderOut(nil)
        onDismiss?()
    }

    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}

// MARK: - Content

private struct ContainerIndicatorDetailView: View {
    let containerID: String
    @ObservedObject var controller: ContainerIndicatorController
    let localization: PluginLocalization

    @ObservedObject private var runtimeLocale = PluginRuntimeLocalization.source

    private var container: ContainerInstance? {
        controller.snapshot.containers.first { $0.id == containerID }
    }

    var body: some View {
        let _ = runtimeLocale.revision
        Group {
            if let container {
                VStack(spacing: 0) {
                    header(container)
                    Divider()
                    Form {
                        overviewSection(container)
                        resourcesSection(container)
                        runtimeSection(container)
                        networkSection(container)
                        processSection(container)
                        if container.isRunning {
                            liveSection(container)
                        }
                    }
                    .formStyle(.grouped)
                }
            } else {
                missingState
            }
        }
        .environment(\.locale, runtimeLocale.locale)
        .environment(
            \.layoutDirection,
            runtimeLocale.locale.language.characterDirection == .rightToLeft
                ? .rightToLeft
                : .leftToRight
        )
    }

    // MARK: Header

    private func header(_ container: ContainerInstance) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "shippingbox")
                    .font(.title3)
                    .foregroundStyle(Color(nsColor: .systemBlue))
                Text(container.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                statusBadge(container)
                Spacer(minLength: 0)
            }
            if !container.image.isEmpty {
                Text(container.image)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    private func statusBadge(_ container: ContainerInstance) -> some View {
        let text = container.isRunning
            ? localization.string("panel.status.running", defaultValue: "运行中")
            : localization.string("panel.status.stopped", defaultValue: "已停止")
        let color = container.isRunning ? Color(nsColor: .systemGreen) : Color.secondary
        return Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.15)))
            .fixedSize()
    }

    // MARK: Sections

    private func overviewSection(_ container: ContainerInstance) -> some View {
        Section {
            field(
                localization.string("detail.field.status", defaultValue: "状态"),
                container.isRunning
                    ? localization.string("panel.status.running", defaultValue: "运行中")
                    : localization.string("panel.status.stopped", defaultValue: "已停止")
            )
            field(
                localization.string("detail.field.containerID", defaultValue: "容器 ID"),
                container.id
            )
            field(
                localization.string("detail.field.imageDigest", defaultValue: "镜像摘要"),
                container.configuration.imageDigest.isEmpty
                    ? none
                    : container.configuration.imageDigest
            )
            field(
                localization.string("detail.field.createdAt", defaultValue: "创建时间"),
                formattedDate(container.configuration.createdAt)
            )
        } header: {
            sectionTitle(localization.string("detail.section.overview", defaultValue: "概览"))
        }
    }

    private func resourcesSection(_ container: ContainerInstance) -> some View {
        Section {
            field(
                localization.string("detail.field.cpu", defaultValue: "CPU"),
                container.cpus > 0
                    ? localization.format("detail.value.coresFormat", defaultValue: "%d 核", container.cpus)
                    : none
            )
            field(
                localization.string("detail.field.memory", defaultValue: "内存"),
                container.memoryBytes > 0
                    ? ContainerIndicatorFormatting.bytes(container.memoryBytes)
                    : none
            )
            field(
                localization.string("detail.field.storageQuota", defaultValue: "存储配额"),
                container.configuration.storageQuotaBytes.map(ContainerIndicatorFormatting.bytes)
                    ?? localization.string("detail.value.notSet", defaultValue: "未设置")
            )
            field(
                localization.string("detail.field.imageSize", defaultValue: "镜像大小"),
                container.imageStorageBytes.map(ContainerIndicatorFormatting.bytes) ?? none
            )
        } header: {
            sectionTitle(localization.string("detail.section.resources", defaultValue: "资源"))
        }
    }

    private func runtimeSection(_ container: ContainerInstance) -> some View {
        let configuration = container.configuration
        return Section {
            field(
                localization.string("detail.field.platform", defaultValue: "平台"),
                configuration.platform.isEmpty ? none : configuration.platform
            )
            field(
                localization.string("detail.field.runtime", defaultValue: "运行时"),
                configuration.runtimeHandler.isEmpty ? none : configuration.runtimeHandler
            )
            field(
                localization.string("detail.field.readOnly", defaultValue: "只读"),
                boolean(configuration.readOnly)
            )
            field(
                localization.string("detail.field.rosetta", defaultValue: "Rosetta"),
                boolean(configuration.rosetta)
            )
            field(
                localization.string("detail.field.ssh", defaultValue: "SSH"),
                boolean(configuration.ssh)
            )
        } header: {
            sectionTitle(localization.string("detail.section.runtime", defaultValue: "运行时"))
        }
    }

    private func networkSection(_ container: ContainerInstance) -> some View {
        let configuration = container.configuration
        return Section {
            field(
                localization.string("detail.field.network", defaultValue: "网络"),
                configuration.networks.isEmpty ? none : configuration.networks.joined(separator: ", ")
            )
            field(
                localization.string("detail.field.hostname", defaultValue: "主机名"),
                configuration.hostname.isEmpty ? none : configuration.hostname
            )
            field(
                localization.string("detail.field.ports", defaultValue: "端口"),
                configuration.ports.isEmpty ? none : configuration.ports.joined(separator: "\n")
            )
            field(
                localization.string("detail.field.dnsDomain", defaultValue: "DNS 域"),
                configuration.dnsDomain.isEmpty ? none : configuration.dnsDomain
            )
            field(
                localization.string("detail.field.dnsServers", defaultValue: "DNS 服务器"),
                configuration.dnsServers.isEmpty ? none : configuration.dnsServers.joined(separator: ", ")
            )
        } header: {
            sectionTitle(localization.string("detail.section.network", defaultValue: "网络"))
        }
    }

    private func processSection(_ container: ContainerInstance) -> some View {
        let configuration = container.configuration
        return Section {
            field(
                localization.string("detail.field.command", defaultValue: "命令"),
                configuration.command.isEmpty ? none : configuration.command
            )
            field(
                localization.string("detail.field.workdir", defaultValue: "工作目录"),
                configuration.workingDirectory.isEmpty ? none : configuration.workingDirectory
            )
            field(
                localization.string("detail.field.user", defaultValue: "用户"),
                configuration.user.isEmpty ? none : configuration.user
            )
            field(
                localization.string("detail.field.environment", defaultValue: "环境变量"),
                configuration.environmentKeys.isEmpty
                    ? none
                    : localization.format(
                        "detail.value.environmentCountFormat",
                        defaultValue: "%d 项（值已隐藏）",
                        configuration.environmentKeys.count
                    )
            )
            if !configuration.environmentKeys.isEmpty {
                field(
                    localization.string("detail.field.environmentKeys", defaultValue: "变量名"),
                    configuration.environmentKeys.joined(separator: "\n")
                )
            }
        } header: {
            sectionTitle(localization.string("detail.section.process", defaultValue: "进程"))
        }
    }

    private func liveSection(_ container: ContainerInstance) -> some View {
        Section {
            field(
                localization.string("detail.field.cpu", defaultValue: "CPU"),
                container.performance?.cpuPercent.map(ContainerIndicatorFormatting.percent) ?? placeholder
            )
            field(
                localization.string("detail.field.memory", defaultValue: "内存"),
                memoryUsage(container.performance)
            )
            field(
                localization.string("detail.field.disk", defaultValue: "磁盘"),
                diskUsage(container.performance)
            )
        } header: {
            sectionTitle(localization.string("detail.section.live", defaultValue: "实时"))
        }
    }

    // MARK: Rows

    private func field(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .font(.subheadline)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private var missingState: some View {
        VStack(spacing: 8) {
            Image(systemName: "shippingbox")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(localization.string("detail.containerMissing", defaultValue: "容器已不存在"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Values

    private var none: String {
        localization.string("detail.value.none", defaultValue: "无")
    }

    private var placeholder: String {
        "—"
    }

    private func boolean(_ value: Bool) -> String {
        value
            ? localization.string("detail.value.yes", defaultValue: "是")
            : localization.string("detail.value.no", defaultValue: "否")
    }

    private func formattedDate(_ date: Date?) -> String {
        guard let date else { return none }
        return date.formatted(
            Date.FormatStyle(date: .abbreviated, time: .shortened)
                .locale(runtimeLocale.locale)
        )
    }

    private func memoryUsage(_ performance: ContainerPerformance?) -> String {
        guard let performance, let usage = performance.memoryBytes else {
            return placeholder
        }
        let used = ContainerIndicatorFormatting.bytes(usage)
        guard let limit = performance.memoryLimitBytes, limit > 0 else {
            return used
        }
        return localization.format(
            "detail.value.memoryUsageFormat",
            defaultValue: "%1$@ / %2$@",
            used,
            ContainerIndicatorFormatting.bytes(limit)
        )
    }

    private func diskUsage(_ performance: ContainerPerformance?) -> String {
        guard let performance,
              let read = performance.diskReadBytesPerSecond,
              let write = performance.diskWriteBytesPerSecond else {
            return placeholder
        }
        return localization.format(
            "detail.value.diskUsageFormat",
            defaultValue: "读 %1$@ · 写 %2$@",
            ContainerIndicatorFormatting.rate(read),
            ContainerIndicatorFormatting.rate(write)
        )
    }
}
