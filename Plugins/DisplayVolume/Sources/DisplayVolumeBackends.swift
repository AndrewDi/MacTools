import AppKit
import CoreGraphics
import Foundation
import MacToolsPluginKit
import OSLog

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

final class SystemDisplayVolumeBackendBuilder: DisplayVolumeBackendBuilding {
    typealias Arm64ServiceResolver = ([DisplayInfo]) -> [CGDirectDisplayID: CFTypeRef]
    typealias DDCBackendFactory = (DisplayInfo, CFTypeRef?) -> (any DisplayVolumeBackend)?

    private let resolveArm64Services: Arm64ServiceResolver
    private let ddcFactory: DDCBackendFactory

    init(
        resolveArm64Services: @escaping Arm64ServiceResolver = Arm64DDCServiceMatcher.resolveServices,
        ddcFactory: DDCBackendFactory? = nil
    ) {
        self.resolveArm64Services = resolveArm64Services
        self.ddcFactory = ddcFactory ?? { display, matchedService in
            if let transport = Arm64DDCTransport(display: display, service: nil) {
                return DDCVolumeBackend(display: display, transport: transport)
            }

            if let matchedService,
               let transport = Arm64DDCTransport(display: display, service: matchedService) {
                return DDCVolumeBackend(display: display, transport: transport)
            }

            return nil
        }
    }

    func backends(
        for displays: [DisplayInfo],
        previous: [CGDirectDisplayID: any DisplayVolumeBackend]
    ) -> [CGDirectDisplayID: any DisplayVolumeBackend] {
        var arm64Services: [CGDirectDisplayID: CFTypeRef]?
        var result: [CGDirectDisplayID: any DisplayVolumeBackend] = [:]

        for display in displays {
            guard let backend = ddcBackend(
                for: display,
                in: displays,
                previous: previous,
                cache: &arm64Services
            ) else {
                continue
            }

            result[display.id] = backend
        }

        return result
    }

    private func ddcBackend(
        for display: DisplayInfo,
        in displays: [DisplayInfo],
        previous: [CGDirectDisplayID: any DisplayVolumeBackend],
        cache arm64Services: inout [CGDirectDisplayID: CFTypeRef]?
    ) -> (any DisplayVolumeBackend)? {
        guard let backend = reuse(previous[display.id], display: display)
            ?? ddcFactory(display, resolvedArm64Service(for: display, in: displays, cache: &arm64Services)) else {
            return nil
        }

        Logger(subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools", category: "DisplayVolumeBackend").debug(
            "selected DDC volume backend for \(display.name, privacy: .public)"
        )
        return backend
    }

    private func resolvedArm64Service(
        for display: DisplayInfo,
        in displays: [DisplayInfo],
        cache arm64Services: inout [CGDirectDisplayID: CFTypeRef]?
    ) -> CFTypeRef? {
        if arm64Services == nil {
            arm64Services = resolveArm64Services(displays)
        }

        return arm64Services?[display.id]
    }

    private func reuse(
        _ previous: (any DisplayVolumeBackend)?,
        display: DisplayInfo
    ) -> (any DisplayVolumeBackend)? {
        guard let backend = previous else {
            return nil
        }

        backend.display = display
        return backend
    }
}

final class DDCVolumeBackend: DisplayVolumeBackend, @unchecked Sendable {
    let kind: DisplayVolumeBackendKind = .ddc

    private let lock = NSLock()
    private var _display: DisplayInfo
    var display: DisplayInfo {
        get { lock.withLock { _display } }
        set { lock.withLock { _display = newValue } }
    }

    private let transport: any DDCVolumeTransport
    private var maximumValue: UInt16
    private var localVolume: Double
    private let cacheKey: String

    init?(display: DisplayInfo, transport: any DDCVolumeTransport) {
        guard !display.isBuiltin else {
            return nil
        }

        self._display = display
        self.transport = transport
        self.maximumValue = 100
        self.cacheKey = "ddc-volume-\(display.id)"

        let cached = UserDefaults.standard.double(forKey: cacheKey)
        self.localVolume = cached != 0 ? cached : 0.15

        if let volume = try? transport.readVolume(),
           let max = Self.validMaximum(volume.maximum) {
            self.maximumValue = max
            self.localVolume = max == 0 ? 1 : Double(volume.current) / Double(max)
            UserDefaults.standard.set(self.localVolume, forKey: cacheKey)
        }

    }

    func readVolume() throws -> Double {
        if let volume = try? transport.readVolume(),
           let max = Self.validMaximum(volume.maximum) {
            lock.withLock {
                maximumValue = max
                localVolume = max == 0 ? 1 : Double(volume.current) / Double(max)
                UserDefaults.standard.set(localVolume, forKey: cacheKey)
            }
            return localVolume
        }
        return localVolume
    }

    func writeVolume(_ value: Double) throws {
        let clampedValue = max(0, min(value, 1))
        lock.withLock {
            localVolume = clampedValue
            UserDefaults.standard.set(localVolume, forKey: cacheKey)
        }
        let rawValue = lock.withLock {
            UInt16((Double(maximumValue) * clampedValue).rounded())
        }
        try transport.writeVolume(rawValue)
    }

    func cleanup() {}

    private static func validMaximum(_ maximum: UInt16) -> UInt16? {
        maximum == 0 ? nil : maximum
    }
}
