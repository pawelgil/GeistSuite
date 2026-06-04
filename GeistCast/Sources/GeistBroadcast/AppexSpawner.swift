import CoreSimulatorPrivate
import Darwin
import Foundation
import GeistKit
import Synchronization

protocol AppexSpawning: Sendable {
    func spawn(stagedBinary: String,
               simulatorUDID: String,
               simctlSetPath: String?,
               environment: [String: String]) async throws
    func killStale(stagedBinary: String) async
}

/// Spawns staged appex binaries on a booted simulator by calling
/// `SimDevice.spawnWithPath:options:terminationQueue:terminationHandler:pid:error:`
/// directly. Replaces the `xcrun simctl spawn …` + `pkill -9 -f …`
/// shellouts. The previously-spawned pid for a given staged binary is
/// tracked per-spawner instance so that `killStale` can deliver a real
/// `kill(pid, SIGKILL)` instead of guessing by command-line match.
final class AppexSpawner: AppexSpawning, Sendable {

    enum SpawnError: Error {
        case spawnFailed(reason: String)
    }

    private let trackedPIDs = Mutex<[String: pid_t]>([:])
    private let deviceResolver: SimDeviceResolver

    init(deviceResolver: SimDeviceResolver = SimDeviceResolver()) {
        self.deviceResolver = deviceResolver
    }

    func spawn(
        stagedBinary: String,
        simulatorUDID: String,
        simctlSetPath: String?,
        environment: [String: String]
    ) async throws {
        await killStale(stagedBinary: stagedBinary)
        guard let udid = UUID(uuidString: simulatorUDID) else {
            throw SpawnError.spawnFailed(reason: "invalid UDID '\(simulatorUDID)'")
        }
        let device = try deviceResolver.resolve(udid: udid, simctlSetPath: simctlSetPath)
        let options: [String: Any] = [
            "arguments": [stagedBinary],
            "environment": environment,
            "stdin": 0,
            "stdout": 1,
            "stderr": 2,
            "standalone": kCFBooleanFalse as Any,
        ]
        var pidValue: Int32 = 0
        var spawnErr: AnyObject?
        let ok = device.spawn(
            withPath: stagedBinary,
            options: options,
            terminationQueue: DispatchQueue.global(qos: .utility),
            terminationHandler: { _ in } as @convention(block) (Int32) -> Void,
            pid: &pidValue,
            error: &spawnErr
        )
        guard ok else {
            let msg = (spawnErr as? NSError)?.localizedDescription
                ?? String(describing: spawnErr)
            throw SpawnError.spawnFailed(reason: msg)
        }
        trackedPIDs.withLock { $0[stagedBinary] = pidValue }
    }

    func killStale(stagedBinary: String) async {
        let pid = trackedPIDs.withLock { dict -> pid_t? in
            let value = dict.removeValue(forKey: stagedBinary)
            return value
        }
        guard let pid, pid > 0 else { return }
        // SIGKILL: appex processes don't trap signals usefully.
        _ = kill(pid, SIGKILL)
    }
}
