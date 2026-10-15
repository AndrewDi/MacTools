import AppKit
import Darwin
import Foundation

@MainActor
protocol TrackpadSensorLeaseManaging: AnyObject {
    var shouldRetryAfterFailedAcquisition: Bool { get }
    func acquire() -> Bool
    func release()
}

struct TrackpadSensorProcessPolicy {
    static func allowsAcquisition(
        isDisabledByEnvironment: Bool,
        bundleIdentifier: String,
        currentBundleURL: URL,
        productName: String,
        homeDirectory: URL,
        fileExists: (String) -> Bool
    ) -> Bool {
        guard !isDisabledByEnvironment else { return false }

        let isDevelopmentApp = bundleIdentifier.hasSuffix(".dev")
            || productName.hasSuffix(" Dev")
        guard isDevelopmentApp else { return true }

        let installedBundleURL = homeDirectory
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("\(productName).app", isDirectory: true)
        guard fileExists(installedBundleURL.path) else {
            // Keep direct Xcode runs usable before the developer has installed a stable Debug app.
            return true
        }

        return installedBundleURL.resolvingSymlinksInPath().standardizedFileURL
            == currentBundleURL.resolvingSymlinksInPath().standardizedFileURL
    }
}

@MainActor
final class TrackpadSensorProcessLease: TrackpadSensorLeaseManaging {
    static let disabledEnvironmentKey = "MACTOOLS_DISABLE_TRACKPAD_LISTENER"

    private let lockPath: String
    private let isAcquisitionAllowed: Bool
    private var fileDescriptor: Int32 = -1
    var shouldRetryAfterFailedAcquisition: Bool { isAcquisitionAllowed }

    init(
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        isAcquisitionAllowed: Bool? = nil
    ) {
        lockPath = temporaryDirectory
            .appendingPathComponent("mactools.trackpad-gestures.listener.lock")
            .path
        self.isAcquisitionAllowed = isAcquisitionAllowed ?? Self.defaultAcquisitionPolicy(
            bundleIdentifier: bundleIdentifier
        )
    }

    deinit {
        if fileDescriptor >= 0 {
            _ = flock(fileDescriptor, LOCK_UN)
            Darwin.close(fileDescriptor)
        }
    }

    func acquire() -> Bool {
        guard isAcquisitionAllowed else { return false }
        guard fileDescriptor < 0 else { return true }
        let descriptor = Darwin.open(
            lockPath,
            O_CREAT | O_RDWR | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { return false }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            return false
        }
        fileDescriptor = descriptor
        return true
    }

    func release() {
        guard fileDescriptor >= 0 else { return }
        _ = flock(fileDescriptor, LOCK_UN)
        Darwin.close(fileDescriptor)
        fileDescriptor = -1
    }

    private static func defaultAcquisitionPolicy(bundleIdentifier: String) -> Bool {
        let productName = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? Bundle.main.bundleURL.deletingPathExtension().lastPathComponent
        return TrackpadSensorProcessPolicy.allowsAcquisition(
            isDisabledByEnvironment: ProcessInfo.processInfo.environment[
                disabledEnvironmentKey
            ] == "1",
            bundleIdentifier: bundleIdentifier,
            currentBundleURL: Bundle.main.bundleURL,
            productName: productName,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            fileExists: FileManager.default.fileExists(atPath:)
        )
    }
}
