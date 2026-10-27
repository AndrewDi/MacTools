import AppKit
import Foundation
import MacToolsPluginKit

struct NotchHoverPanelSnapshot: Equatable, Sendable {
    let isEnabled: Bool
    let hasSupportedDisplay: Bool
    let showsMenuBarIcon: Bool
    let triggerWidth: Double
    let verticalTriggerReach: Double
    let showDelay: Double
    let hideDelay: Double
    let isPanelVisible: Bool
}

@MainActor
protocol NotchHoverPanelControlling: AnyObject, PluginMenuBarPanelPresenting,
    PluginAppMenuBarIconVisibilityControlling {
    var onStateChange: (() -> Void)? { get set }
    var snapshot: NotchHoverPanelSnapshot { get }

    func activate()
    func deactivate()
    func refresh()
    func setEnabled(_ isEnabled: Bool)
    func setShowsMenuBarIcon(_ showsMenuBarIcon: Bool)
    func setTriggerWidth(_ width: Double)
    func setVerticalTriggerReach(_ reach: Double)
    func setShowDelay(_ delay: Double)
    func setHideDelay(_ delay: Double)
}

@MainActor
final class NotchHoverPanelController: NotchHoverPanelControlling {
    private enum StorageKey {
        static let enabled = "notch-hover.enabled"
        static let showsMenuBarIcon = "notch-hover.show-menu-bar-icon"
        static let triggerWidth = "notch-hover.trigger-width"
        static let verticalTriggerReach = "notch-hover.vertical-reach"
        static let showDelay = "notch-hover.show-delay"
        static let hideDelay = "notch-hover.hide-delay"
    }

    private static let panelHitInset: CGFloat = 8
    private static let mouseEventMask: NSEvent.EventTypeMask = [
        .mouseMoved,
        .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        .leftMouseUp, .rightMouseUp, .otherMouseUp,
    ]

    var onStateChange: (() -> Void)?
    var requestMenuBarPanelPresentation:
        ((PluginMenuBarPanelPresentationRequest) -> Bool)?
    var requestMenuBarPanelDismissal: ((_ animated: Bool) -> Void)?
    var presentedMenuBarPanelScreenFrame: (() -> NSRect?)?
    var isPresentedMenuBarPanelVisible: (() -> Bool)?
    var requestAppMenuBarIconVisibility: ((Bool) -> Void)?

    private let storage: any PluginStorage
    private let screensProvider: @MainActor () -> [NotchHoverScreenSnapshot]
    private let mouseLocationProvider: @MainActor () -> NSPoint
    private let logger = NotchHoverPanelLog.controller

    private var isEnabled: Bool
    private var showsMenuBarIcon: Bool
    private var triggerWidth: Double
    private var verticalTriggerReach: Double
    private var showDelay: Double
    private var hideDelay: Double
    private var displays: [NotchHoverDisplay] = []
    private var activeDisplay: NotchHoverDisplay?
    private var ownsPanelPresentation = false
    private var showWorkItem: DispatchWorkItem?
    private var hideWorkItem: DispatchWorkItem?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var menuTrackingObservers: [NSObjectProtocol] = []
    private var menuTrackingCount = 0

    init(
        storage: any PluginStorage,
        screensProvider: @escaping @MainActor () -> [NotchHoverScreenSnapshot] = {
            NotchHoverScreenCatalog.snapshots()
        },
        mouseLocationProvider: @escaping @MainActor () -> NSPoint = {
            NSEvent.mouseLocation
        }
    ) {
        self.storage = storage
        self.screensProvider = screensProvider
        self.mouseLocationProvider = mouseLocationProvider

        if storage.object(forKey: StorageKey.enabled) == nil {
            isEnabled = true
        } else {
            isEnabled = storage.bool(forKey: StorageKey.enabled)
        }

        if storage.object(forKey: StorageKey.showsMenuBarIcon) == nil {
            showsMenuBarIcon = false
        } else {
            showsMenuBarIcon = storage.bool(forKey: StorageKey.showsMenuBarIcon)
        }

        if storage.object(forKey: StorageKey.triggerWidth) == nil {
            triggerWidth = Double(NotchHoverGeometry.defaultTriggerWidth)
        } else {
            triggerWidth = Self.clampedTriggerWidth(
                Double(storage.integer(forKey: StorageKey.triggerWidth))
            )
        }

        if storage.object(forKey: StorageKey.verticalTriggerReach) == nil {
            verticalTriggerReach = Double(NotchHoverGeometry.defaultVerticalTriggerReach)
        } else {
            verticalTriggerReach = Self.clampedVerticalTriggerReach(
                Double(storage.integer(forKey: StorageKey.verticalTriggerReach))
            )
        }

        if storage.object(forKey: StorageKey.showDelay) == nil {
            showDelay = 0.18
        } else {
            showDelay = Self.clampedShowDelay(storage.object(forKey: StorageKey.showDelay) as? Double ?? 0.18)
        }

        if storage.object(forKey: StorageKey.hideDelay) == nil {
            hideDelay = 0.28
        } else {
            hideDelay = Self.clampedHideDelay(storage.object(forKey: StorageKey.hideDelay) as? Double ?? 0.28)
        }

        refreshDisplays()
    }

    isolated deinit {
        stopMouseMonitoring()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    var snapshot: NotchHoverPanelSnapshot {
        NotchHoverPanelSnapshot(
            isEnabled: isEnabled,
            hasSupportedDisplay: !displays.isEmpty,
            showsMenuBarIcon: showsMenuBarIcon,
            triggerWidth: triggerWidth,
            verticalTriggerReach: verticalTriggerReach,
            showDelay: showDelay,
            hideDelay: hideDelay,
            isPanelVisible: ownsPanelPresentation
        )
    }

    // MARK: - Lifecycle

    func activate() {
        installScreenObserver()
        installMenuTrackingObserver()
        refreshDisplays()
        applyMenuBarIconVisibility()
        if isEnabled {
            startMouseMonitoring()
        }
    }

    func deactivate() {
        cancelScheduledInteractions()
        stopMouseMonitoring()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        menuTrackingObservers.forEach(NotificationCenter.default.removeObserver)
        menuTrackingObservers.removeAll()
        menuTrackingCount = 0
        dismissOwnedPanel(animated: false)
        requestAppMenuBarIconVisibility?(true)
    }

    func refresh() {
        refreshDisplays()
        if ownsPanelPresentation,
           let activeDisplay,
           !displays.contains(where: { $0.displayID == activeDisplay.displayID }) {
            dismissOwnedPanel(animated: true)
        }
        onStateChange?()
    }

    // MARK: - Preferences

    func setEnabled(_ isEnabled: Bool) {
        guard self.isEnabled != isEnabled else { return }
        self.isEnabled = isEnabled
        storage.set(isEnabled, forKey: StorageKey.enabled)

        if isEnabled {
            refreshDisplays()
            startMouseMonitoring()
        } else {
            cancelScheduledInteractions()
            stopMouseMonitoring()
            dismissOwnedPanel(animated: true)
        }
        applyMenuBarIconVisibility()
        onStateChange?()
    }

    func setShowsMenuBarIcon(_ showsMenuBarIcon: Bool) {
        guard self.showsMenuBarIcon != showsMenuBarIcon else { return }
        self.showsMenuBarIcon = showsMenuBarIcon
        storage.set(showsMenuBarIcon, forKey: StorageKey.showsMenuBarIcon)
        applyMenuBarIconVisibility()
        onStateChange?()
    }

    func setTriggerWidth(_ width: Double) {
        let clamped = Self.clampedTriggerWidth(width)
        guard triggerWidth != clamped else { return }
        triggerWidth = clamped
        storage.set(Int(clamped.rounded()), forKey: StorageKey.triggerWidth)
        refreshDisplays()
        onStateChange?()
    }

    func setVerticalTriggerReach(_ reach: Double) {
        let clamped = Self.clampedVerticalTriggerReach(reach)
        guard verticalTriggerReach != clamped else { return }
        verticalTriggerReach = clamped
        storage.set(Int(clamped.rounded()), forKey: StorageKey.verticalTriggerReach)
        refreshDisplays()
        onStateChange?()
    }

    func setShowDelay(_ delay: Double) {
        let clamped = Self.clampedShowDelay(delay)
        guard showDelay != clamped else { return }
        showDelay = clamped
        storage.set(clamped, forKey: StorageKey.showDelay)
        onStateChange?()
    }

    func setHideDelay(_ delay: Double) {
        let clamped = Self.clampedHideDelay(delay)
        guard hideDelay != clamped else { return }
        hideDelay = clamped
        storage.set(clamped, forKey: StorageKey.hideDelay)
        onStateChange?()
    }

    // MARK: - Pointer handling

    func handlePointerLocation(_ point: NSPoint) {
        guard isEnabled else { return }

        syncOwnedPanelVisibility()

        let triggerDisplay = displayContainingTrigger(point)
        if let triggerDisplay {
            activeDisplay = triggerDisplay
        }

        let panelFrame = presentedMenuBarPanelScreenFrame?()
        let isInsideTrigger = triggerDisplay != nil
        let isInsideActiveArea = pointerIsActive(
            point,
            triggerDisplay: triggerDisplay,
            panelFrame: panelFrame
        )

        if isInsideActiveArea {
            cancelScheduledHide()
            if isInsideTrigger, !ownsPanelPresentation, isPresentedMenuBarPanelVisible?() != true {
                scheduleShow()
            } else {
                cancelScheduledShow()
            }
            if ownsPanelPresentation,
               let activeDisplay,
               isPresentedMenuBarPanelVisible?() == true {
                // Cancel any in-flight hide animation when the pointer returns.
                _ = requestMenuBarPanelPresentation?(
                    PluginMenuBarPanelPresentationRequest(anchorRect: activeDisplay.notchFrame)
                )
            }
        } else {
            cancelScheduledShow()
            if ownsPanelPresentation {
                scheduleHide()
            }
        }
    }

    private func pointerIsActive(
        _ point: NSPoint,
        triggerDisplay: NotchHoverDisplay?,
        panelFrame: NSRect?
    ) -> Bool {
        if let triggerDisplay,
           NotchHoverGeometry.isPointerActive(
               point,
               triggers: triggerDisplay.triggerRects,
               notchFrame: triggerDisplay.notchFrame,
               panelFrame: nil
           ) {
            return true
        }

        if let panelFrame,
           panelFrame.insetBy(dx: -Self.panelHitInset, dy: -Self.panelHitInset).contains(point) {
            return true
        }

        guard let activeDisplay else { return false }
        return NotchHoverGeometry.isPointerActive(
            point,
            triggers: activeDisplay.triggerRects,
            notchFrame: activeDisplay.notchFrame,
            panelFrame: panelFrame
        )
    }

    private func displayContainingTrigger(_ point: NSPoint) -> NotchHoverDisplay? {
        displays.first { display in
            display.triggerRects.contains(where: { $0.contains(point) })
        }
    }

    // MARK: - Scheduled presentation

    private func scheduleShow() {
        guard showWorkItem == nil else { return }
        cancelScheduledHide()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.showWorkItem = nil
                self?.presentPanelIfNeeded()
            }
        }
        showWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + showDelay, execute: workItem)
    }

    private func cancelScheduledShow() {
        showWorkItem?.cancel()
        showWorkItem = nil
    }

    private func scheduleHide() {
        guard hideWorkItem == nil else { return }
        cancelScheduledShow()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.hideWorkItem = nil
                self?.dismissPanelIfPointerLeft()
            }
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + hideDelay, execute: workItem)
    }

    private func cancelScheduledHide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
    }

    private func cancelScheduledInteractions() {
        cancelScheduledShow()
        cancelScheduledHide()
    }

    private func presentPanelIfNeeded() {
        guard isEnabled, !ownsPanelPresentation else { return }
        guard isPresentedMenuBarPanelVisible?() != true else { return }

        let point = mouseLocationProvider()
        guard let display = displayContainingTrigger(point) else { return }
        activeDisplay = display

        let request = PluginMenuBarPanelPresentationRequest(anchorRect: display.notchFrame)
        guard requestMenuBarPanelPresentation?(request) == true else {
            logger.debug("host declined notch panel presentation")
            return
        }

        ownsPanelPresentation = true
        onStateChange?()
    }

    private func dismissPanelIfPointerLeft() {
        guard ownsPanelPresentation else { return }
        guard menuTrackingCount == 0, NSApp.modalWindow == nil else { return }
        guard NSEvent.pressedMouseButtons == 0 else {
            scheduleHide()
            return
        }

        let point = mouseLocationProvider()
        guard !pointerIsActive(
            point,
            triggerDisplay: displayContainingTrigger(point),
            panelFrame: presentedMenuBarPanelScreenFrame?()
        ) else { return }

        dismissOwnedPanel(animated: true)
    }

    private func dismissOwnedPanel(animated: Bool) {
        guard ownsPanelPresentation else { return }
        ownsPanelPresentation = false
        activeDisplay = nil
        cancelScheduledInteractions()
        requestMenuBarPanelDismissal?(animated)
        onStateChange?()
    }

    private func syncOwnedPanelVisibility() {
        guard ownsPanelPresentation, isPresentedMenuBarPanelVisible?() == false else { return }
        ownsPanelPresentation = false
        activeDisplay = nil
        cancelScheduledInteractions()
        onStateChange?()
    }

    // MARK: - Environment

    private func refreshDisplays() {
        displays = NotchHoverGeometry.displays(
            from: screensProvider(),
            triggerWidth: CGFloat(triggerWidth),
            verticalTriggerReach: CGFloat(verticalTriggerReach)
        )
    }

    private func applyMenuBarIconVisibility() {
        // A disabled plugin must not keep the host icon hidden.
        // Also restore the icon if there is no display that supports the hover trigger.
        let hasSupportedDisplay = !displays.isEmpty
        requestAppMenuBarIconVisibility?(isEnabled ? showsMenuBarIcon && hasSupportedDisplay : true)
    }

    private func installScreenObserver() {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    private func installMenuTrackingObserver() {
        guard menuTrackingObservers.isEmpty else { return }
        let center = NotificationCenter.default
        menuTrackingObservers.append(center.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.menuTrackingCount += 1
                self?.cancelScheduledHide()
            }
        })
        menuTrackingObservers.append(center.addObserver(
            forName: NSMenu.didEndTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.menuTrackingCount = max(0, self.menuTrackingCount - 1)
                self.handlePointerLocation(self.mouseLocationProvider())
            }
        })
    }

    private func startMouseMonitoring() {
        guard localMouseMonitor == nil, globalMouseMonitor == nil else { return }

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: Self.mouseEventMask
        ) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handlePointerLocation(NSEvent.mouseLocation)
            }
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: Self.mouseEventMask
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handlePointerLocation(NSEvent.mouseLocation)
            }
        }
    }

    private func stopMouseMonitoring() {
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
    }

    // MARK: - Clamping

    private static func clampedTriggerWidth(_ value: Double) -> Double {
        min(
            max(value, NotchHoverGeometry.allowedTriggerWidthRange.lowerBound),
            NotchHoverGeometry.allowedTriggerWidthRange.upperBound
        )
    }

    private static func clampedVerticalTriggerReach(_ value: Double) -> Double {
        min(
            max(value, NotchHoverGeometry.allowedVerticalTriggerReachRange.lowerBound),
            NotchHoverGeometry.allowedVerticalTriggerReachRange.upperBound
        )
    }

    private static func clampedShowDelay(_ value: Double) -> Double {
        min(max(value, 0), 0.8)
    }

    private static func clampedHideDelay(_ value: Double) -> Double {
        min(max(value, 0.05), 1)
    }
}
