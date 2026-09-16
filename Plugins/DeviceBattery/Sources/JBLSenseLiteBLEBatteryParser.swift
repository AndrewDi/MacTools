import Foundation

/// Parser for JBL Sense Lite (and compatible) earbuds battery levels
/// using the proprietary ExcelPoint BLE GATT service.
///
/// Protocol discovered via BLE reverse engineering:
/// - Service UUID: 65786365-6C70-6F69-6E74-2E636F6D0000 ("excelpoint.com")
/// - RX (notify): 65786365-6C70-6F69-6E74-2E636F6D0001
/// - TX (write):  65786365-6C70-6F69-6E74-2E636F6D0002
///
/// Notification packet structure (confirmed via multiple samples):
/// ┌─────────────────────────────────────────────────────────────┐
/// │ Header: 00 DD 03 00 01 00 [len] 00 00 00                   │
/// ├─────────────────────────────────────────────────────────────┤
/// │ Feature 0x0D: [XX] 0D 00 01 00 [left_battery]   (0~100%)  │
/// │ Feature 0x0E: [XX] 0E 00 01 00 [right_battery]  (0~100%)  │
/// │ Feature 0x1F: 03 1F 01 00    [case_battery]     (0~100%)  │
/// │ Feature 0x34: 34 00 01 00    [status]           (unknown) │
/// ├─────────────────────────────────────────────────────────────┤
/// │ Footer: 01 1F 03 00 19 0A 0A                               │
/// └─────────────────────────────────────────────────────────────┘
enum JBLSenseLiteBLEBatteryParser {

    // MARK: - Service UUIDs

    /// ExcelPoint service UUID ("excelpoint.com")
    static let excelPointServiceUUID = "65786365-6C70-6F69-6E74-2E636F6D0000"

    /// RX characteristic (notifications from device)
    static let rxCharacteristicUUID = "65786365-6C70-6F69-6E74-2E636F6D0001"

    /// TX characteristic (commands to device)
    static let txCharacteristicUUID = "65786365-6C70-6F69-6E74-2E636F6D0002"

    // MARK: - Feature IDs

    private static let leftBatteryFeatureID: UInt8 = 0x0D
    private static let rightBatteryFeatureID: UInt8 = 0x0E
    private static let caseBatteryFeatureID: UInt8 = 0x03
    private static let statusFeatureID: UInt8 = 0x34

    // MARK: - Battery Reading

    struct BatteryReading: Equatable, Sendable {
        let leftBattery: Int?
        let rightBattery: Int?
        let caseBattery: Int?
        let isValid: Bool

        static let empty = BatteryReading(
            leftBattery: nil,
            rightBattery: nil,
            caseBattery: nil,
            isValid: false
        )
    }

    // MARK: - Parsing

    /// Parse a JBL ExcelPoint notification packet to extract battery levels.
    /// - Parameter data: Raw notification data from RX characteristic
    /// - Returns: Parsed battery reading, or nil if data is invalid
    static func parseBatteryNotification(_ data: Data) -> BatteryReading? {
        guard data.count >= 10 else { return nil }

        // Verify header: 00 DD 03 00 01 00
        let header: [UInt8] = [0x00, 0xDD, 0x03, 0x00, 0x01, 0x00]
        guard data.prefix(6).elementsEqual(header) else { return nil }

        let bytes = [UInt8](data)
        var leftBattery: Int?
        var rightBattery: Int?
        var caseBattery: Int?

        // Scan for feature patterns in the packet
        var i = 6 // Skip header
        while i + 4 < bytes.count {
            // Pattern: [XX] 0D 00 01 00 [level] - Left battery
            if i + 5 <= bytes.count,
               bytes[i + 1] == leftBatteryFeatureID,
               bytes[i + 2] == 0x00,
               bytes[i + 3] == 0x01,
               bytes[i + 4] == 0x00 {
                leftBattery = Int(bytes[i + 5])
                i += 6
                continue
            }

            // Pattern: [XX] 0E 00 01 00 [level] - Right battery
            if i + 5 <= bytes.count,
               bytes[i + 1] == rightBatteryFeatureID,
               bytes[i + 2] == 0x00,
               bytes[i + 3] == 0x01,
               bytes[i + 4] == 0x00 {
                rightBattery = Int(bytes[i + 5])
                i += 6
                continue
            }

            // Pattern: 03 1F 01 00 [level] - Case battery
            if i + 4 <= bytes.count,
               bytes[i] == caseBatteryFeatureID,
               bytes[i + 1] == 0x1F,
               bytes[i + 2] == 0x01,
               bytes[i + 3] == 0x00 {
                caseBattery = Int(bytes[i + 4])
                i += 5
                continue
            }

            i += 1
        }

        // Validate battery levels (0-100%)
        let validLeft = leftBattery.map { (0...100).contains($0) }
        let validRight = rightBattery.map { (0...100).contains($0) }
        let validCase = caseBattery.map { (0...100).contains($0) }

        // At least one battery level must be present and valid
        guard validLeft == true || validRight == true || validCase == true else {
            return nil
        }

        return BatteryReading(
            leftBattery: leftBattery,
            rightBattery: rightBattery,
            caseBattery: caseBattery,
            isValid: true
        )
    }

    /// Check if a device name matches JBL earbuds pattern.
    static func isJBLEarbuds(_ name: String) -> Bool {
        name.lowercased().hasPrefix("jbl")
    }
}
