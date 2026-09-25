import CoreSimulatorPrivate
import Darwin
import Foundation
import GeistKit
import Synchronization

protocol AppexSpawning: Sendable {
    func spawn(stagedAppex: StagedAppex,
               simulatorUDID: String,
               simctlSetPath: String?,
               environment: [String: String]) async throws -> SpawnedAppex
    func killStale(stagedBinary: String) async
    func terminate(_ process: SpawnedAppex) async
}

struct SpawnedAppex: Hashable, Sendable {
    let binaryPath: String
    let generation: UUID
    let pid: pid_t
    let birthIdentity: ProcessBirthIdentity?
    let termination: ProcessTermination

    init(
        binaryPath: String,
        generation: UUID,
        pid: pid_t,
        birthIdentity: ProcessBirthIdentity? = nil,
        termination: ProcessTermination = ProcessTermination()
    ) {
        self.binaryPath = binaryPath
        self.generation = generation
        self.pid = pid
        self.birthIdentity = birthIdentity
        self.termination = termination
    }

    static func == (lhs: SpawnedAppex, rhs: SpawnedAppex) -> Bool {
        lhs.binaryPath == rhs.binaryPath && lhs.generation == rhs.generation && lhs.pid == rhs.pid
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(binaryPath)
        hasher.combine(generation)
        hasher.combine(pid)
    }
}

struct ProcessBirthIdentity: Hashable, Sendable {
    let seconds: UInt64
    let microseconds: UInt64
}

/// Spawns staged appex binaries on a booted simulator by calling
/// `SimDevice.spawnWithPath:options:terminationQueue:terminationHandler:pid:error:`
/// directly. Replaces the `xcrun simctl spawn …` + `pkill -9 -f …`
/// shellouts. Spawned process identities for a given staged binary are
/// tracked per-spawner instance so that `killStale` can deliver real
/// `kill(pid, SIGKILL)` calls instead of guessing by command-line match.
final class AppexSpawner: AppexSpawning, Sendable {

    struct SpawnResult: Sendable {
        let pid: pid_t
        let birthIdentity: ProcessBirthIdentity?
    }

    typealias ProcessKiller = @Sendable (SpawnedAppex) -> Void
    typealias SpawnOperation = @Sendable (
        _ stagedBinary: String,
        _ simulatorUDID: String,
        _ simctlSetPath: String?,
        _ environment: [String: String],
        _ processTerminated: @escaping @Sendable (Int32) -> Void
    ) async throws -> SpawnResult

    private struct TrackingState {
        private var processes: [String: [UUID: SpawnedAppex]] = [:]
        private var pendingInstall: Set<UUID> = []
        private var terminatedBeforeInstall: Set<UUID> = []

        mutating func beginInstall(generation: UUID) {
            pendingInstall.insert(generation)
        }

        mutating func failInstall(generation: UUID) {
            pendingInstall.remove(generation)
            terminatedBeforeInstall.remove(generation)
        }

        mutating func finishInstall(_ process: SpawnedAppex) {
            pendingInstall.remove(process.generation)
            guard terminatedBeforeInstall.remove(process.generation) == nil else { return }
            processes[process.binaryPath, default: [:]][process.generation] = process
        }

        mutating func removeAll(binaryPath: String) -> [SpawnedAppex] {
            guard let removed = processes.removeValue(forKey: binaryPath) else { return [] }
            return Array(removed.values)
        }

        mutating func remove(_ process: SpawnedAppex) -> Bool {
            guard processes[process.binaryPath]?[process.generation] == process else { return false }
            processes[process.binaryPath]?.removeValue(forKey: process.generation)
            removeEmptyBucket(binaryPath: process.binaryPath)
            return true
        }

        mutating func processTerminated(binaryPath: String, generation: UUID) {
            if processes[binaryPath]?.removeValue(forKey: generation) != nil {
                removeEmptyBucket(binaryPath: binaryPath)
            } else if pendingInstall.contains(generation) {
                terminatedBeforeInstall.insert(generation)
            }
        }

        private mutating func removeEmptyBucket(binaryPath: String) {
            if processes[binaryPath]?.isEmpty == true {
                processes.removeValue(forKey: binaryPath)
            }
        }
    }

    enum SpawnError: Error {
        case spawnFailed(reason: String)
    }

    private let tracking = Mutex(TrackingState())
    private let processKiller: ProcessKiller
    private let spawnOperation: SpawnOperation

    init(deviceResolver: SimDeviceResolver = SimDeviceResolver()) {
        processKiller = Self.kill
        spawnOperation = { stagedBinary, simulatorUDID, simctlSetPath, environment, processTerminated in
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
                terminationHandler: { status in processTerminated(status) } as @convention(block) (Int32) -> Void,
                pid: &pidValue,
                error: &spawnErr
            )
            guard ok else {
                let message = (spawnErr as? NSError)?.localizedDescription
                    ?? String(describing: spawnErr)
                throw SpawnError.spawnFailed(reason: message)
            }
            return SpawnResult(
                pid: pidValue,
                birthIdentity: Self.processBirthIdentity(pid: pidValue)
            )
        }
    }

    init(
        spawnOperation: @escaping SpawnOperation,
        processKiller: @escaping ProcessKiller
    ) {
        self.spawnOperation = spawnOperation
        self.processKiller = processKiller
    }

    func spawn(
        stagedAppex: StagedAppex,
        simulatorUDID: String,
        simctlSetPath: String?,
        environment: [String: String]
    ) async throws -> SpawnedAppex {
        let stagedBinary = stagedAppex.binaryPath
        await killStale(stagedBinary: stagedBinary)
        let generation = UUID()
        let termination = ProcessTermination()
        let lifetime = SpawnLifetime(stagedAppex: stagedAppex)
        tracking.withLock { $0.beginInstall(generation: generation) }
        let spawnResult: SpawnResult
        do {
            spawnResult = try await spawnOperation(
                stagedBinary,
                simulatorUDID,
                simctlSetPath,
                environment,
                { [weak self, lifetime] status in
                    termination.record(status)
                    lifetime.confirmTermination()
                    self?.processTerminated(
                        binaryPath: stagedBinary,
                        generation: generation
                    )
                }
            )
        } catch {
            tracking.withLock { $0.failInstall(generation: generation) }
            lifetime.confirmTermination()
            throw error
        }
        let process = SpawnedAppex(
            binaryPath: stagedBinary,
            generation: generation,
            pid: spawnResult.pid,
            birthIdentity: spawnResult.birthIdentity
            , termination: termination
        )
        tracking.withLock { $0.finishInstall(process) }
        return process
    }

    func killStale(stagedBinary: String) async {
        let processes = tracking.withLock { $0.removeAll(binaryPath: stagedBinary) }
        for process in processes { processKiller(process) }
    }

    func terminate(_ process: SpawnedAppex) async {
        let ownsProcess = tracking.withLock { $0.remove(process) }
        guard ownsProcess else { return }
        processKiller(process)
    }

    private static func kill(_ process: SpawnedAppex) {
        guard process.pid > 0,
              let expectedBirth = process.birthIdentity,
              Self.processBirthIdentity(pid: process.pid) == expectedBirth else { return }
        // SIGKILL: appex processes don't trap signals usefully.
        _ = Darwin.kill(process.pid, SIGKILL)
    }

    private static func processBirthIdentity(pid: pid_t) -> ProcessBirthIdentity? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size else {
            return nil
        }
        return ProcessBirthIdentity(
            seconds: UInt64(info.pbi_start_tvsec),
            microseconds: UInt64(info.pbi_start_tvusec)
        )
    }

    private func processTerminated(binaryPath: String, generation: UUID) {
        tracking.withLock {
            $0.processTerminated(binaryPath: binaryPath, generation: generation)
        }
    }
}
