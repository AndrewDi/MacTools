import Foundation
import MacToolsPluginKit

@MainActor
final class SharedMultitouchFrameListener: MultitouchFrameListening {
    var service: (any TrackpadInputService)?
    private var subscriptionID: UUID?
    var devices: [TrackpadSensorDevice] { service?.devices ?? [] }
    var deviceCount: Int { devices.count }
    var connectedDeviceIDs: Set<UInt64> { Set(devices.map(\.deviceID)) }

    func start(handler: @escaping @Sendable (TrackpadContactFrame) -> Void) -> Bool {
        stop()
        subscriptionID = service?.subscribe(purpose: .gestures) { event in
            if case let .frame(frame) = event { handler(frame) }
        }
        return subscriptionID != nil
    }

    func stop() {
        if let subscriptionID { service?.unsubscribe(subscriptionID) }
        subscriptionID = nil
    }
}
