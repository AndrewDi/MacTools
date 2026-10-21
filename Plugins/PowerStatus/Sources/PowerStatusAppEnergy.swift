import AppKit
import Darwin
import Foundation

/// One application's measured energy draw over the last sampling window.
struct PowerStatusAppEnergy: Identifiable, Equatable {
    /// Bundle identifier of the owning application; stable across samples.
    let id: String
    let name: String
    let icon: NSImage?
    let watts: Double
}

/// Pure conversion and ranking helpers, kept separate from the sampling code so
/// the energy math can be verified without touching live processes.
enum PowerStatusAppEnergyMath {
    /// Below this many watts the reading is sampling noise rather than a
    /// meaningful share of the system draw.
    static let minimumReportedWatts = 0.02

    /// Converts cumulative per-process energy counters into watts.
    ///
    /// The kernel counters are monotonic for a process lifetime, so a value
    /// that went backwards means the PID was reused and there is no valid
    /// delta. A process missing from `previous` has not been measured yet.
    static func watts(
        previous: [Int32: UInt64],
        current: [Int32: UInt64],
        elapsed: TimeInterval
    ) -> [Int32: Double] {
        guard elapsed > 0 else { return [:] }
        var result: [Int32: Double] = [:]
        for (pid, energy) in current {
            guard let before = previous[pid], energy >= before else { continue }
            let joules = Double(energy - before) / 1_000_000_000.0
            result[pid] = joules / elapsed
        }
        return result
    }

    /// Keeps the heaviest applications, dropping readings too small to matter.
    static func ranked(
        _ apps: [PowerStatusAppEnergy],
        limit: Int = 5,
        minimumWatts: Double = minimumReportedWatts
    ) -> [PowerStatusAppEnergy] {
        Array(
            apps
                .filter { $0.watts >= minimumWatts }
                .sorted { lhs, rhs in
                    if lhs.watts == rhs.watts { return lhs.name < rhs.name }
                    return lhs.watts > rhs.watts
                }
                .prefix(max(0, limit))
        )
    }
}

/// Measures per-application energy use from the kernel's per-process energy
/// counters, which are the same source Activity Monitor's energy figures are
/// derived from. Main-actor isolated because it reads `NSRunningApplication`
/// names and icons.
@MainActor
final class PowerStatusAppEnergyMonitor {
    private struct Baseline {
        let timestamp: Date
        let energyByPID: [Int32: UInt64]
    }

    /// ~2 samples of smoothing at the panel's 2 s cadence: enough to steady the
    /// list without lagging behind an app that starts or stops working.
    private static let smoothingAlpha = 0.35

    /// A longer gap (sleep, panel closed, stalled timer) makes the delta an
    /// average over an unknown window, so it starts a fresh baseline instead.
    private static let maximumSampleInterval: TimeInterval = 30

    private var baseline: Baseline?
    private var smoothedWatts: [String: Double] = [:]

    /// Drops the previous counters so the next sample starts a fresh window.
    func reset() {
        baseline = nil
        smoothedWatts.removeAll()
    }

    /// Samples cumulative energy and returns the five heaviest applications
    /// since the previous call. The first call only records a baseline.
    func sample(now: Date = Date()) -> [PowerStatusAppEnergy] {
        let energies = Self.readCumulativeEnergy()
        defer { baseline = Baseline(timestamp: now, energyByPID: energies) }

        guard let baseline else { return [] }
        let elapsed = now.timeIntervalSince(baseline.timestamp)
        guard elapsed > 0.2, elapsed <= Self.maximumSampleInterval else {
            smoothedWatts.removeAll()
            return []
        }

        let wattsByPID = PowerStatusAppEnergyMath.watts(
            previous: baseline.energyByPID,
            current: energies,
            elapsed: elapsed
        )
        guard !wattsByPID.isEmpty else { return [] }

        var appsByPID: [Int32: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications {
            let pid = app.processIdentifier
            if pid > 0 {
                appsByPID[pid] = app
            }
        }
        guard !appsByPID.isEmpty else { return [] }

        // Attribute helpers and child processes to the app that owns them, so
        // a browser's renderer and GPU helpers count toward the browser.
        var wattsByApp: [String: Double] = [:]
        var appByID: [String: NSRunningApplication] = [:]
        for (pid, watts) in wattsByPID {
            guard let owner = Self.owningApp(for: pid, appsByPID: appsByPID),
                  let id = owner.bundleIdentifier,
                  !id.isEmpty else { continue }
            wattsByApp[id, default: 0] += watts
            appByID[id] = owner
        }
        guard !wattsByApp.isEmpty else { return [] }

        var smoothed: [String: Double] = [:]
        for (id, watts) in wattsByApp {
            let previous = smoothedWatts[id] ?? watts
            smoothed[id] = previous + Self.smoothingAlpha * (watts - previous)
        }
        smoothedWatts = smoothed

        let readings: [PowerStatusAppEnergy] = smoothed.map { element in
            let (id, watts) = element
            let app = appByID[id]
            return PowerStatusAppEnergy(
                id: id,
                name: app?.localizedName ?? app?.bundleIdentifier ?? id,
                icon: app?.icon,
                watts: watts
            )
        }
        return PowerStatusAppEnergyMath.ranked(readings)
    }

    // MARK: - Process inspection

    /// Attributes a process to the highest app ancestor with a regular
    /// activation policy, falling back to the closest app ancestor. Walking to
    /// the top keeps nested helpers with the app the user launched.
    private static func owningApp(
        for pid: Int32,
        appsByPID: [Int32: NSRunningApplication]
    ) -> NSRunningApplication? {
        var current = pid
        var visited = Set<Int32>()
        var closestApp: NSRunningApplication?
        var regularApp: NSRunningApplication?

        // Bounded so a malformed parent chain cannot spin forever.
        for _ in 0..<12 {
            guard current > 0, visited.insert(current).inserted else { break }
            if let app = appsByPID[current] {
                if closestApp == nil { closestApp = app }
                if app.activationPolicy == .regular { regularApp = app }
            }
            guard let parent = parentPID(of: current) else { break }
            current = parent
        }
        return regularApp ?? closestApp
    }

    private static func parentPID(of pid: Int32) -> Int32? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard result == size else { return nil }
        return Int32(bitPattern: info.pbi_ppid)
    }

    /// Reads the lifetime energy counter (nanojoules) for every process this
    /// user can inspect. Processes owned by other users fail and are skipped.
    private static func readCumulativeEnergy() -> [Int32: UInt64] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [:] }

        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let bytes = Int32(pids.count * MemoryLayout<Int32>.size)
        let filled = proc_listallpids(&pids, bytes)
        guard filled > 0 else { return [:] }

        var result: [Int32: UInt64] = [:]
        result.reserveCapacity(Int(filled))
        for index in 0..<Int(filled) {
            let pid = pids[index]
            guard pid > 0 else { continue }

            var info = rusage_info_v6()
            let status = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                    proc_pid_rusage(pid, RUSAGE_INFO_V6, rebound)
                }
            }
            guard status == 0 else { continue }
            result[pid] = info.ri_energy_nj
        }
        return result
    }
}
