import Darwin
import Foundation
import IOKit

/// A component that exposes a temperature sensor, a power value, or both.
enum PowerStatusSensorComponent: String, CaseIterable, Identifiable, Sendable {
    case cpu
    case gpu
    case memory
    case neuralEngine
    case storage
    case mainboard
    case battery
    case ambient
    case wireless

    var id: String { rawValue }

    /// Catalog key for the component name.
    var titleKey: String {
        switch self {
        case .cpu: "sensors.cpu"
        case .gpu: "sensors.gpu"
        case .memory: "sensors.memory"
        case .neuralEngine: "sensors.neuralEngine"
        case .storage: "sensors.storage"
        case .mainboard: "sensors.mainboard"
        case .battery: "sensors.battery"
        case .ambient: "sensors.ambient"
        case .wireless: "sensors.wireless"
        }
    }

    var defaultTitle: String {
        switch self {
        case .cpu: "处理器"
        case .gpu: "图形处理器"
        case .memory: "内存"
        case .neuralEngine: "神经网络引擎"
        case .storage: "存储"
        case .mainboard: "主板"
        case .battery: "电池"
        case .ambient: "环境"
        case .wireless: "无线网络"
        }
    }

    var iconName: String {
        switch self {
        case .cpu: "cpu"
        case .gpu: "rectangle.3.group"
        case .memory: "memorychip"
        case .neuralEngine: "brain"
        case .storage: "internaldrive"
        case .mainboard: "square.grid.3x3"
        case .battery: "battery.50percent"
        case .ambient: "thermometer.medium"
        case .wireless: "wifi"
        }
    }
}

/// One row in the temperature and power table. A missing value stays `nil` so
/// the view can print an em dash instead of a false measured zero.
struct PowerStatusComponentReading: Identifiable, Equatable, Sendable {
    let component: PowerStatusSensorComponent
    let temperatureC: Double?
    let powerW: Double?

    var id: String { component.rawValue }
}

struct PowerStatusSensorSnapshot: Equatable, Sendable {
    var components: [PowerStatusComponentReading] = []
    /// Distinguishes "not sampled yet" from a completed sample with no sensors.
    var isSampled = false

    var isAvailable: Bool { !components.isEmpty }

    static let empty = PowerStatusSensorSnapshot()
}

/// Pure classification and conversion helpers, kept separate from the live
/// readers so they can be verified without hardware access.
enum PowerStatusSensorMath {
    /// Maps an SMC temperature key to the component it belongs to.
    ///
    /// The prefixes cover the common Intel names (TC0*, TG0*, TB0*, TA0*,
    /// TH0*, TM0*) and the Apple silicon families (Tp/Te/TCM for CPU, Tg for
    /// GPU, TRD for unified memory, TH/TN for storage, TPD/Ts for board and
    /// skin, Ta for ambient, TW for wireless).
    static func component(forTemperatureKey key: String) -> PowerStatusSensorComponent? {
        guard key.count == 4, key.hasPrefix("T") else { return nil }

        if key.hasPrefix("Tp") || key.hasPrefix("Te") || key.hasPrefix("TCM")
            || key.hasPrefix("TC0") || key.hasPrefix("TCAD") {
            return .cpu
        }
        if key.hasPrefix("Tg") || key.hasPrefix("TG0") || key.hasPrefix("TG1")
            || key.hasPrefix("TCGC") {
            return .gpu
        }
        if key.hasPrefix("TRD") || key.hasPrefix("TM0") || key.hasPrefix("TM1")
            || key.hasPrefix("TM2") {
            return .memory
        }
        if key.hasPrefix("TH0") || key.hasPrefix("TH1") || key.hasPrefix("TN0")
            || key.hasPrefix("TN1") {
            return .storage
        }
        if key.hasPrefix("TB0") || key.hasPrefix("TB1") || key.hasPrefix("TB2") {
            return .battery
        }
        if key.hasPrefix("TPD") || key.hasPrefix("TCHP") || key.hasPrefix("TMVR")
            || key.hasPrefix("TVm") || key.hasPrefix("Ts0") || key.hasPrefix("Ts1") {
            return .mainboard
        }
        if key.hasPrefix("Ta0") || key.hasPrefix("TA0") {
            return .ambient
        }
        if key.hasPrefix("TW0") || key.hasPrefix("TW1") {
            return .wireless
        }
        return nil
    }

    /// Rejects unpopulated sensors, which can report a few degrees before the
    /// die warms up, while still allowing cold ambient and battery readings.
    static func isValidTemperature(
        _ value: Double,
        for component: PowerStatusSensorComponent
    ) -> Bool {
        guard value.isFinite else { return false }
        switch component {
        case .ambient:
            return value > -30 && value < 60
        case .battery:
            return value > 0 && value < 100
        case .cpu, .gpu, .memory, .storage, .mainboard, .wireless:
            return value >= 10 && value < 125
        case .neuralEngine:
            return false
        }
    }

    /// Reads the Apple silicon marketing name (for example, "Apple M2 Max").
    /// Intel Macs return their CPU brand string instead, which is not matched
    /// by the Neural Engine support check.
    static func currentChipName() -> String? {
        var size = 0
        guard
            sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0,
            size > 1
        else {
            return nil
        }

        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// M1 and M2 Macs do not expose a usable Neural Engine temperature/power
    /// component in this panel, so the row is hidden instead of showing only
    /// an em dash and a zero. M3 and newer keep the row.
    static func supportsNeuralEngineComponent(chipName: String?) -> Bool {
        guard let chipName, chipName.hasPrefix("Apple M") else { return false }
        let generation = chipName.dropFirst("Apple M".count).first?.wholeNumberValue
        return (generation ?? 0) >= 3
    }

    /// Maps an IOReport "Energy Model" channel to the component it powers.
    /// Only aggregate channels are used so the per-cluster or per-SRAM
    /// counters are not counted twice.
    static func component(forPowerChannel name: String) -> PowerStatusSensorComponent? {
        if name == "CPU Energy" { return .cpu }
        if name == "GPU Energy" { return .gpu }
        if name.hasPrefix("DRAM") { return .memory }
        if name.hasPrefix("ANE") { return .neuralEngine }
        return nil
    }

    /// IOReport labels the same joule counter in different units depending on
    /// the channel and SoC generation.
    static func joules(from value: Int64, unit: String) -> Double? {
        guard value >= 0 else { return nil }
        let magnitude = Double(value)
        switch unit {
        case "J": return magnitude
        case "mJ": return magnitude / 1_000
        case "uJ": return magnitude / 1_000_000
        case "nJ": return magnitude / 1_000_000_000
        default: return nil
        }
    }

    /// Converts cumulative energy counters into watts. A counter that went
    /// backwards means the sample baseline is no longer comparable.
    static func watts(
        previous: [PowerStatusSensorComponent: Double],
        current: [PowerStatusSensorComponent: Double],
        elapsed: TimeInterval
    ) -> [PowerStatusSensorComponent: Double] {
        guard elapsed > 0 else { return [:] }
        var result: [PowerStatusSensorComponent: Double] = [:]
        for (component, joules) in current {
            guard let before = previous[component], joules >= before else { continue }
            let watts = (joules - before) / elapsed
            guard watts.isFinite, watts >= 0, watts < 500 else { continue }
            result[component] = watts
        }
        return result
    }

    /// Resolves memory power from the Energy Model first and the SMC DRAM
    /// fallback second. A zero or unavailable source is not a usable reading:
    /// unified memory cannot draw no power while the machine is running, and
    /// the Energy Model counter can be frozen without Apple's private
    /// entitlement. Returning `nil` lets the panel show a dash instead of
    /// `0.00 W`.
    static func memoryPowerWatts(
        energyModel: Double?,
        smcFallback: Double?
    ) -> Double? {
        if let energyModel, energyModel.isFinite, energyModel > 0 {
            return energyModel
        }
        if let smcFallback, smcFallback.isFinite, smcFallback > 0 {
            return smcFallback
        }
        return nil
    }
}

/// Samples the SMC temperature sensors and the IOReport energy model off the
/// main actor. The first temperature sample discovers the populated key set;
/// later samples only read the matching sensors.
actor PowerStatusSensorMonitor {
    private lazy var smcReader: PowerStatusSMCReader? = PowerStatusSMCReader()
    private lazy var powerReader = PowerStatusComponentPowerReader()
    private let supportsNeuralEngine = PowerStatusSensorMath.supportsNeuralEngineComponent(
        chipName: PowerStatusSensorMath.currentChipName()
    )
    private var temperatureKeys: [String]?

    func sample(
        batteryTemperatureC: Double?,
        batteryPowerW: Double?
    ) -> PowerStatusSensorSnapshot {
        let temperatures = readTemperatures()
        let power = powerReader.sample()
        var readings: [PowerStatusComponentReading] = []

        for component in PowerStatusSensorComponent.allCases {
            if component == .neuralEngine, !supportsNeuralEngine { continue }

            var temperature = temperatures[component]
            if component == .battery {
                temperature = batteryTemperatureC ?? temperature
            }

            let powerW = component == .battery ? batteryPowerW : power[component]
            guard temperature != nil || powerW != nil else { continue }

            readings.append(
                PowerStatusComponentReading(
                    component: component,
                    temperatureC: temperature,
                    powerW: powerW
                )
            )
        }

        return PowerStatusSensorSnapshot(components: readings, isSampled: true)
    }

    private func readTemperatures() -> [PowerStatusSensorComponent: Double] {
        if temperatureKeys == nil {
            let discovered = smcReader?.temperatureKeys() ?? []
            if !discovered.isEmpty {
                temperatureKeys = discovered
            }
        }

        guard let keys = temperatureKeys, let smcReader else { return [:] }

        var result: [PowerStatusSensorComponent: Double] = [:]
        for key in keys {
            guard let component = PowerStatusSensorMath.component(forTemperatureKey: key),
                  let value = smcReader.value(for: key),
                  PowerStatusSensorMath.isValidTemperature(value, for: component) else {
                continue
            }
            result[component] = max(result[component] ?? value, value)
        }
        return result
    }
}

/// Small Core Foundation helpers for building the synthetic CLPC channels.
/// The channel dictionaries are retained by the IOReport subscription and by
/// the dictionaries that contain them.
private enum PowerStatusCF {
    static func string(_ value: String) -> CFString {
        CFStringCreateWithCString(
            kCFAllocatorDefault,
            value,
            CFStringBuiltInEncodings.UTF8.rawValue
        )!
    }

    static func number(_ value: Int64) -> CFNumber {
        var value = value
        return CFNumberCreate(kCFAllocatorDefault, .sInt64Type, &value)!
    }

    static func dictionary() -> CFMutableDictionary {
        var keyCallbacks = kCFTypeDictionaryKeyCallBacks
        var valueCallbacks = kCFTypeDictionaryValueCallBacks
        return CFDictionaryCreateMutable(
            kCFAllocatorDefault,
            0,
            &keyCallbacks,
            &valueCallbacks
        )!
    }

    static func array() -> CFMutableArray {
        var callbacks = kCFTypeArrayCallBacks
        return CFArrayCreateMutable(kCFAllocatorDefault, 0, &callbacks)!
    }

    static func set(_ dictionary: CFMutableDictionary, _ key: String, _ value: CFTypeRef) {
        let keyReference = string(key)
        CFDictionarySetValue(
            dictionary,
            Unmanaged.passUnretained(keyReference).toOpaque(),
            Unmanaged.passUnretained(value).toOpaque()
        )
    }

    static func append(_ array: CFMutableArray, _ value: CFTypeRef) {
        CFArrayAppendValue(array, Unmanaged.passUnretained(value).toOpaque())
    }
}

/// Builds the synthetic `CLPC` / `Energy Counters` channels that macOS 27 uses
/// for aggregate CPU, GPU, and ANE energy. The Energy Model counters for those
/// components can freeze without Apple's private entitlement, while CLPC
/// remains readable. Unknown drivers and other OS versions fall back to the
/// Energy Model.
private enum PowerStatusCLPCChannels {
    private struct Keys {
        let cpu: UInt64
        let gpu: UInt64
        let ane: UInt64
    }

    private static let cpuIndex: UInt64 = 16
    private static let gpuIndex: UInt64 = 25
    private static let aneIndex: UInt64 = 24

    private static let keysByBundle: [String: Keys] = [
        "com.apple.driver.AppleT6000CLPCv3": Keys(cpu: 0x4747_9059, gpu: 0x4519_bf1e, ane: 0x9aaa_17f8),
        "com.apple.driver.AppleT6002CLPC": Keys(cpu: 0xb501_816b, gpu: 0x9e2c_3e8b, ane: 0x14d5_a574),
        "com.apple.driver.AppleT6020CLPC": Keys(cpu: 0xe301_cd75, gpu: 0x8f34_cc7a, ane: 0x7415_fb0f),
        "com.apple.driver.AppleT6022CLPC": Keys(cpu: 0x76f5_fd21, gpu: 0x9062_4499, ane: 0x3c09_7307),
        "com.apple.driver.AppleT6030CLPC": Keys(cpu: 0xbe03_a01a, gpu: 0x472d_6c9c, ane: 0xb899_0c38),
        "com.apple.driver.AppleT6031CLPC": Keys(cpu: 0xd81e_0084, gpu: 0x1085_f98b, ane: 0x313a_3be1),
        "com.apple.driver.AppleT6032CLPC": Keys(cpu: 0xf4a2_1308, gpu: 0x85e8_0513, ane: 0x63dc_8e25),
        "com.apple.driver.AppleT6041CLPC": Keys(cpu: 0x263c_f1f0, gpu: 0x22e4_cf59, ane: 0x7849_fb5c),
        "com.apple.driver.AppleT6050CLPC": Keys(cpu: 0xd3ab_60bb, gpu: 0x27cd_4ce5, ane: 0x8c0f_1c59),
        "com.apple.driver.AppleT6050dCLPC": Keys(cpu: 0x18b3_010e, gpu: 0xedec_a11a, ane: 0x188b_d883),
        "com.apple.driver.AppleT8103CLPCv3": Keys(cpu: 0x2cdd_31f2, gpu: 0x21be_cf42, ane: 0x0667_fb81),
        "com.apple.driver.AppleT8112CLPC": Keys(cpu: 0xb543_5137, gpu: 0x638d_9d52, ane: 0xea08_9c36),
        "com.apple.driver.AppleT8122CLPC": Keys(cpu: 0x54b5_1c99, gpu: 0xce2d_d9dc, ane: 0x960a_fe2f),
        "com.apple.driver.AppleT8132CLPC": Keys(cpu: 0x4a85_4d94, gpu: 0x3b3e_3b79, ane: 0x1ff4_a9ec),
        "com.apple.driver.AppleT8140CLPC": Keys(cpu: 0x9bf5_4436, gpu: 0xef70_589c, ane: 0x569d_941b),
        "com.apple.driver.AppleT8142CLPC": Keys(cpu: 0x4370_8744, gpu: 0x6a01_0933, ane: 0xbc5e_fdf0),
        "com.apple.driver.AppleT8152CLPC": Keys(cpu: 0x485d_4bfc, gpu: 0x1178_4654, ane: 0x9380_c6bb),
    ]

    static func makeSelectedChannels() -> CFMutableArray? {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27 else {
            return nil
        }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("AppleCLPC"),
            &iterator
        ) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        let selected = PowerStatusCF.array()
        var seen: Set<String> = []

        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            appendChannels(for: entry, to: selected, seen: &seen)
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }

        return CFArrayGetCount(selected) > 0 ? selected : nil
    }

    private static func appendChannels(
        for entry: io_registry_entry_t,
        to selected: CFMutableArray,
        seen: inout Set<String>
    ) {
        var driverID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(entry, &driverID) == KERN_SUCCESS else {
            return
        }

        var properties: Unmanaged<CFMutableDictionary>?
        guard
            IORegistryEntryCreateCFProperties(
                entry,
                &properties,
                kCFAllocatorDefault,
                0
            ) == KERN_SUCCESS,
            let propertyDictionary = properties?.takeRetainedValue() as? [String: Any],
            let bundle = propertyDictionary["CFBundleIdentifier"] as? String,
            let keys = keysByBundle[bundle]
        else {
            return
        }

        let reports: [(name: String, id: UInt64)] = [
            ("CPU Energy", (cpuIndex << 32) | keys.cpu),
            ("GPU Energy", (gpuIndex << 32) | keys.gpu),
            ("ANE", (aneIndex << 32) | keys.ane),
        ]

        for report in reports {
            let dedupeKey = "\(driverID)-\(report.id)"
            guard seen.insert(dedupeKey).inserted else { continue }
            let channel = makeChannel(driver: driverID, reportID: report.id, name: report.name)
            PowerStatusCF.append(selected, channel)
        }
    }

    private static func makeChannel(
        driver: UInt64,
        reportID: UInt64,
        name: String
    ) -> CFMutableDictionary {
        // IOReportTypes.h: simple integer, power category, one element; energy
        // is reported in nanojoules.
        let channelType: Int64 = 1 | (2 << 16) | (1 << 32)
        let unit: Int64 = (3 << 56) | (118 << 32)

        let legend = PowerStatusCF.array()
        PowerStatusCF.append(legend, PowerStatusCF.number(Int64(reportID)))
        PowerStatusCF.append(legend, PowerStatusCF.number(channelType))
        PowerStatusCF.append(legend, PowerStatusCF.string(name))

        let info = PowerStatusCF.dictionary()
        PowerStatusCF.set(info, "IOReportChannelUnit", PowerStatusCF.number(unit))

        let channel = PowerStatusCF.dictionary()
        PowerStatusCF.set(channel, "DriverID", PowerStatusCF.number(Int64(driver)))
        PowerStatusCF.set(channel, "DriverName", PowerStatusCF.string("AppleCLPC"))
        PowerStatusCF.set(channel, "IOReportGroupName", PowerStatusCF.string("CLPC"))
        PowerStatusCF.set(
            channel,
            "IOReportSubGroupName",
            PowerStatusCF.string("Energy Counters")
        )
        PowerStatusCF.set(channel, "IOReportChannelInfo", info)
        PowerStatusCF.set(channel, "LegendChannel", legend)
        return channel
    }
}

/// Reads the cumulative per-component energy counters from IOReport and turns
/// consecutive samples into watts.
private final class PowerStatusComponentPowerReader {
    private struct CumulativeJoules {
        var energyModel: [PowerStatusSensorComponent: Double] = [:]
        var clpc: [PowerStatusSensorComponent: Double] = [:]
    }

    private struct Baseline {
        let uptime: TimeInterval
        let joules: CumulativeJoules
    }

    /// Two samples of smoothing at the panel's 2 s cadence.
    private static let smoothingAlpha = 0.35

    /// A longer gap makes the delta an average over an unknown window, so the
    /// next sample starts a fresh baseline.
    private static let maximumSampleInterval: TimeInterval = 30

    private let functions: PowerStatusIOReportFunctions?
    private let channels: CFMutableDictionary?
    private let subscription: OpaquePointer?
    private let hasCLPCChannels: Bool
    private let smcReader: PowerStatusSMCReader?
    private var baseline: Baseline?
    private var smoothedWatts: [PowerStatusSensorComponent: Double] = [:]
    private var dramKeyCount: Int?

    init() {
        smcReader = PowerStatusSMCReader()

        guard let functions = PowerStatusIOReportFunctions() else {
            self.functions = nil
            channels = nil
            subscription = nil
            hasCLPCChannels = false
            return
        }

        var channels = PowerStatusCF.dictionary()
        var hasChannels = false
        if let baseChannels = functions.copyChannelsInGroup(
            "Energy Model" as CFString, nil, 0, 0, 0
        )?.takeRetainedValue(),
           let mutableChannels = CFDictionaryCreateMutableCopy(
               kCFAllocatorDefault, 0, baseChannels
           ) {
            channels = mutableChannels
            hasChannels = true
        }

        let clpcChannels = PowerStatusCLPCChannels.makeSelectedChannels()
        let clpcCount = clpcChannels.map { CFArrayGetCount($0) } ?? 0
        if let clpcChannels, clpcCount > 0 {
            Self.append(clpcChannels, to: channels)
            hasChannels = true
        }

        self.functions = functions
        hasCLPCChannels = clpcCount > 0

        guard hasChannels else {
            self.channels = nil
            subscription = nil
            return
        }

        var subscriptionChannels: Unmanaged<CFMutableDictionary>?
        self.channels = channels
        subscription = functions.createSubscription(nil, channels, &subscriptionChannels, 0, nil)
        subscriptionChannels?.release()
    }

    deinit {
        // The subscription owns a Mach port and must be released while the
        // dynamically loaded IOReport code is still alive.
        if let subscription {
            Unmanaged<CFTypeRef>.fromOpaque(UnsafeRawPointer(subscription)).release()
        }
    }

    func sample(now: TimeInterval = ProcessInfo.processInfo.systemUptime)
        -> [PowerStatusSensorComponent: Double] {
        guard let current = readCumulativeJoules() else {
            baseline = nil
            smoothedWatts.removeAll()
            return [:]
        }
        defer { baseline = Baseline(uptime: now, joules: current) }

        guard let baseline else { return [:] }
        let elapsed = now - baseline.uptime
        guard elapsed > 0.2, elapsed <= Self.maximumSampleInterval else {
            smoothedWatts.removeAll()
            return [:]
        }

        let energyModelWatts = PowerStatusSensorMath.watts(
            previous: baseline.joules.energyModel,
            current: current.energyModel,
            elapsed: elapsed
        )
        let clpcWatts = PowerStatusSensorMath.watts(
            previous: baseline.joules.clpc,
            current: current.clpc,
            elapsed: elapsed
        )

        var instant = energyModelWatts
        for component in [
            PowerStatusSensorComponent.cpu,
            .gpu,
            .neuralEngine,
        ] {
            if let clpcValue = clpcWatts[component] {
                instant[component] = clpcValue
            } else if hasCLPCChannels, !current.clpc.isEmpty {
                // CLPC is authoritative on macOS 27; do not resurrect a gated
                // Energy Model zero for this sample. If no CLPC counter could
                // be read at all, keep the Energy Model fallback.
                instant[component] = nil
            }
        }

        if (instant[.memory] ?? 0) <= 0 {
            instant[.memory] = PowerStatusSensorMath.memoryPowerWatts(
                energyModel: instant[.memory],
                smcFallback: readSMCDRAMPower()
            )
        }

        var smoothed: [PowerStatusSensorComponent: Double] = [:]
        for (component, watts) in instant {
            let previous = smoothedWatts[component] ?? watts
            smoothed[component] = previous + Self.smoothingAlpha * (watts - previous)
        }
        smoothedWatts = smoothed
        return smoothed
    }

    private func readCumulativeJoules() -> CumulativeJoules? {
        guard
            let functions,
            let channels,
            let subscription,
            let sample = functions.createSamples(subscription, channels, nil)?.takeRetainedValue(),
            let sampleDictionary = sample as? [String: Any],
            let rawItems = sampleDictionary["IOReportChannels"]
        else {
            return nil
        }

        let rawItemsReference = rawItems as CFTypeRef
        guard CFGetTypeID(rawItemsReference) == CFArrayGetTypeID() else {
            return nil
        }
        let items = unsafeDowncast(rawItemsReference, to: CFArray.self)
        var totals = CumulativeJoules()

        for index in 0..<CFArrayGetCount(items) {
            let rawItem = CFArrayGetValueAtIndex(items, index)
            let itemReference = unsafeBitCast(rawItem, to: CFTypeRef.self)
            guard CFGetTypeID(itemReference) == CFDictionaryGetTypeID() else {
                continue
            }
            let item = unsafeDowncast(itemReference, to: CFDictionary.self)
            guard
                let group = functions.channelGetGroup(item)?.takeUnretainedValue() as String?,
                let channelName = functions.channelGetChannelName(item)?.takeUnretainedValue() as String?,
                let component = PowerStatusSensorMath.component(forPowerChannel: channelName),
                let unit = functions.channelGetUnitLabel(item)?.takeUnretainedValue() as String?,
                let joules = PowerStatusSensorMath.joules(
                    from: functions.simpleGetIntegerValue(item, 0),
                    unit: unit
                )
            else {
                continue
            }

            switch group {
            case "Energy Model":
                totals.energyModel[component, default: 0] += joules
            case "CLPC":
                totals.clpc[component, default: 0] += joules
            default:
                continue
            }
        }

        return totals
    }

    private func readSMCDRAMPower() -> Double? {
        guard let smcReader else { return nil }

        if dramKeyCount == nil {
            var count = 0
            for index in 1...8 where smcReader.value(for: "PZD\(index)") != nil {
                count = index
            }
            dramKeyCount = count
        }

        guard let dramKeyCount, dramKeyCount > 0 else { return nil }

        var total: Double = 0
        var foundValue = false
        for index in 1...dramKeyCount {
            guard
                let value = smcReader.value(for: "PZD\(index)"),
                value.isFinite,
                value >= 0,
                value < 1_000
            else {
                continue
            }
            total += value
            foundValue = true
        }
        return foundValue && total > 0 ? total : nil
    }

    private static func append(_ additions: CFArray, to channels: CFMutableDictionary) {
        let key = PowerStatusCF.string("IOReportChannels")
        let rawExisting = CFDictionaryGetValue(
            channels,
            Unmanaged.passUnretained(key).toOpaque()
        )
        let combined: CFMutableArray
        if let rawExisting {
            let existing = Unmanaged<CFTypeRef>
                .fromOpaque(rawExisting)
                .takeUnretainedValue()
            let existingArray = unsafeDowncast(existing, to: CFArray.self)
            combined = CFArrayCreateMutableCopy(
                kCFAllocatorDefault,
                0,
                existingArray
            )!
        } else {
            combined = PowerStatusCF.array()
        }

        for index in 0..<CFArrayGetCount(additions) {
            CFArrayAppendValue(combined, CFArrayGetValueAtIndex(additions, index))
        }
        PowerStatusCF.set(channels, "IOReportChannels", combined)
    }
}

private final class PowerStatusIOReportFunctions {
    typealias CopyChannelsInGroup = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFDictionary>?
    typealias CreateSubscription = @convention(c) (
        UnsafeMutableRawPointer?,
        CFMutableDictionary?,
        UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?,
        UInt64,
        CFTypeRef?
    ) -> OpaquePointer?
    typealias CreateSamples = @convention(c) (OpaquePointer?, CFMutableDictionary?, CFTypeRef?) -> Unmanaged<CFDictionary>?
    typealias ChannelString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    typealias SimpleGetIntegerValue = @convention(c) (CFDictionary, Int32) -> Int64

    let handle: UnsafeMutableRawPointer
    let copyChannelsInGroup: CopyChannelsInGroup
    let createSubscription: CreateSubscription
    let createSamples: CreateSamples
    let channelGetGroup: ChannelString
    let channelGetChannelName: ChannelString
    let channelGetUnitLabel: ChannelString
    let simpleGetIntegerValue: SimpleGetIntegerValue

    init?() {
        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY) else { return nil }
        guard
            let copyChannelsInGroup = Self.loadFunction(
                named: "IOReportCopyChannelsInGroup",
                from: handle,
                as: CopyChannelsInGroup.self
            ),
            let createSubscription = Self.loadFunction(
                named: "IOReportCreateSubscription",
                from: handle,
                as: CreateSubscription.self
            ),
            let createSamples = Self.loadFunction(
                named: "IOReportCreateSamples",
                from: handle,
                as: CreateSamples.self
            ),
            let channelGetGroup = Self.loadFunction(
                named: "IOReportChannelGetGroup",
                from: handle,
                as: ChannelString.self
            ),
            let channelGetChannelName = Self.loadFunction(
                named: "IOReportChannelGetChannelName",
                from: handle,
                as: ChannelString.self
            ),
            let channelGetUnitLabel = Self.loadFunction(
                named: "IOReportChannelGetUnitLabel",
                from: handle,
                as: ChannelString.self
            ),
            let simpleGetIntegerValue = Self.loadFunction(
                named: "IOReportSimpleGetIntegerValue",
                from: handle,
                as: SimpleGetIntegerValue.self
            )
        else {
            dlclose(handle)
            return nil
        }

        self.handle = handle
        self.copyChannelsInGroup = copyChannelsInGroup
        self.createSubscription = createSubscription
        self.createSamples = createSamples
        self.channelGetGroup = channelGetGroup
        self.channelGetChannelName = channelGetChannelName
        self.channelGetUnitLabel = channelGetUnitLabel
        self.simpleGetIntegerValue = simpleGetIntegerValue
    }

    deinit {
        dlclose(handle)
    }

    private static func loadFunction<T>(
        named name: String,
        from handle: UnsafeMutableRawPointer,
        as type: T.Type
    ) -> T? {
        guard let symbol = dlsym(handle, name) else {
            return nil
        }
        return unsafeBitCast(symbol, to: type)
    }
}
