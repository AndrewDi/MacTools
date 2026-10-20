import MacToolsPluginKit
import XCTest
@testable import KeyStatsPlugin

final class KeyStatsTrackpadSessionDetectorTests: XCTestCase {
    func testCountsOnlySessionStartsAndTracksDevicesIndependently() {
        let detector = KeyStatsTrackpadSessionDetector()
        let contact = TrackpadSensorContact(identifier: 1, x: 0.5, y: 0.5)

        XCTAssertTrue(detector.observe(TrackpadSensorFrame(deviceID: 1, timestamp: 0, contacts: [contact])))
        XCTAssertFalse(detector.observe(TrackpadSensorFrame(deviceID: 1, timestamp: 0.1, contacts: [contact])))
        XCTAssertFalse(detector.observe(TrackpadSensorFrame(deviceID: 1, timestamp: 0.2, contacts: [])))
        XCTAssertTrue(detector.observe(TrackpadSensorFrame(deviceID: 1, timestamp: 0.3, contacts: [contact])))
        XCTAssertTrue(detector.observe(TrackpadSensorFrame(deviceID: 2, timestamp: 0.3, contacts: [contact])))
    }
}
