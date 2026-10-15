import Foundation

/// Copied values only. No callback-owned native memory crosses this boundary.
public struct TrackpadSensorContact: Equatable, Sendable {
    public let identifier: Int
    public let x: Double
    public let y: Double
    public let pressure: Double

    public init(identifier: Int, x: Double, y: Double, pressure: Double = 0) {
        self.identifier = identifier
        self.x = x
        self.y = y
        self.pressure = pressure
    }
}

public struct TrackpadSensorFrame: Equatable, Sendable {
    public let deviceID: UInt64
    public let timestamp: TimeInterval
    public let contacts: [TrackpadSensorContact]

    public init(deviceID: UInt64, timestamp: TimeInterval, contacts: [TrackpadSensorContact]) {
        self.deviceID = deviceID
        self.timestamp = timestamp
        self.contacts = contacts
    }
}

public enum TrackpadSensorTransport: String, Equatable, Sendable {
    case builtIn, bluetooth, usb, external, unknown
}

public struct TrackpadSensorDevice: Equatable, Sendable {
    public let deviceID: UInt64
    public let isBuiltIn: Bool?
    public let transport: TrackpadSensorTransport
    public let supportsForce: Bool?
    public let hasPersistentIdentity: Bool

    public init(deviceID: UInt64, isBuiltIn: Bool?, transport: TrackpadSensorTransport,
                supportsForce: Bool? = nil, hasPersistentIdentity: Bool = false) {
        self.deviceID = deviceID
        self.isBuiltIn = isBuiltIn
        self.transport = transport
        self.supportsForce = supportsForce
        self.hasPersistentIdentity = hasPersistentIdentity
    }

    public var supportsWeighing: Bool { isBuiltIn == true && supportsForce == true }
}

public enum TrackpadSensorEvent: Sendable {
    case frame(TrackpadSensorFrame)
    case interrupted
}

public enum TrackpadInputPurpose: Sendable {
    case gestures, weighing
}

/// The host owns the single native listener and its process lease. Subscriptions
/// must be explicitly cancelled. Weighing temporarily pauses gesture consumers.
@MainActor
public protocol TrackpadInputService: AnyObject {
    var devices: [TrackpadSensorDevice] { get }
    var gesturesArePaused: Bool { get }
    func subscribe(purpose: TrackpadInputPurpose,
                   handler: @escaping @Sendable (TrackpadSensorEvent) -> Void) -> UUID?
    func unsubscribe(_ subscriptionID: UUID)
}

/// An additive host capability, keeping PluginRuntimeContext's existing ABI intact.
@MainActor
public protocol TrackpadInputServiceConsuming: AnyObject {
    func setTrackpadInputService(_ service: any TrackpadInputService)
    func trackpadInputPauseDidChange(_ isPaused: Bool)
}

public extension TrackpadInputServiceConsuming {
    func trackpadInputPauseDidChange(_ isPaused: Bool) {}
}
