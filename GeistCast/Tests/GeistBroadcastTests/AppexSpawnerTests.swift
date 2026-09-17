import Foundation
import Synchronization
import Testing
@testable import GeistBroadcast

struct AppexSpawnerTests {
    @Test
    func outOfOrderSuccessfulSpawnsRemainIndependentlyOwned() async throws {
        let boundary = GatedSpawnBoundary()
        let killer = ProcessKillRecorder()
        let sut = makeSUT(boundary: boundary, killer: killer)
        let firstSpawn = Task { try await spawn(sut) }
        await boundary.firstSpawnEntered.wait()

        let second = try await spawn(sut)
        boundary.releaseFirstSpawn()
        let first = try await firstSpawn.value
        await sut.terminate(first)
        await boundary.terminateFirstProcess()
        await sut.terminate(second)

        #expect(killer.processes == [first, second])
    }

    @Test
    func killStaleTerminatesEveryInstalledGenerationForBinary() async throws {
        let boundary = GatedSpawnBoundary()
        let killer = ProcessKillRecorder()
        let sut = makeSUT(boundary: boundary, killer: killer)
        let firstSpawn = Task { try await spawn(sut) }
        await boundary.firstSpawnEntered.wait()
        let second = try await spawn(sut)
        boundary.releaseFirstSpawn()
        let first = try await firstSpawn.value

        await sut.killStale(stagedBinary: GatedSpawnBoundary.binaryPath)
        await sut.terminate(first)
        await sut.terminate(second)

        #expect(Set(killer.processes) == Set([first, second]))
    }

    @Test
    func terminationBeforeSpawnReturnsDoesNotInstallFinishedProcess() async throws {
        let killer = ProcessKillRecorder()
        let sut = AppexSpawner(
            spawnOperation: { _, _, _, _, processTerminated in
                processTerminated()
                return AppexSpawner.SpawnResult(pid: 1, birthIdentity: nil)
            },
            processKiller: killer.record
        )

        let process = try await spawn(sut)
        await sut.terminate(process)

        #expect(killer.processes.isEmpty)
    }

    @Test
    func spawn_CallbackRetainedAfterInvocation_ReleasesArtifactOnce() async throws {
        let boundary = FakeSpawnBoundary()
        let tracker = ArtifactReleaseTracker()
        let sut = makeSUT(boundary: boundary)
        _ = try await spawn(sut, releaseTracker: tracker)

        boundary.terminate(call: 0)
        boundary.terminate(call: 0)

        #expect(tracker.releaseCount == 1)
        #expect(boundary.callbackCount == 1)
    }

    @Test
    func spawn_SpawnerReleasedBeforeCallback_KeepsArtifactUntilCallback() async throws {
        let boundary = FakeSpawnBoundary()
        let tracker = ArtifactReleaseTracker()
        var sut: AppexSpawner? = makeSUT(boundary: boundary)
        weak let releasedSUT = sut
        _ = try await spawn(try #require(sut), releaseTracker: tracker)

        sut = nil
        #expect(releasedSUT == nil)
        #expect(tracker.releaseCount == 0)
        boundary.terminate(call: 0)

        #expect(tracker.releaseCount == 1)
    }

    @Test
    func terminate_KillRequested_KeepsArtifactUntilCallback() async throws {
        let boundary = FakeSpawnBoundary()
        let tracker = ArtifactReleaseTracker()
        let killer = ProcessKillRecorder()
        let sut = makeSUT(boundary: boundary, killer: killer)
        let process = try await spawn(sut, releaseTracker: tracker)

        await sut.terminate(process)

        #expect(killer.processes == [process])
        #expect(tracker.releaseCount == 0)
        boundary.terminate(call: 0)
        #expect(tracker.releaseCount == 1)
    }

    @Test
    func killStale_KillRequested_KeepsArtifactUntilCallback() async throws {
        let boundary = FakeSpawnBoundary()
        let tracker = ArtifactReleaseTracker()
        let killer = ProcessKillRecorder()
        let sut = makeSUT(boundary: boundary, killer: killer)
        let process = try await spawn(sut, releaseTracker: tracker)

        await sut.killStale(stagedBinary: process.binaryPath)

        #expect(killer.processes == [process])
        #expect(tracker.releaseCount == 0)
        boundary.terminate(call: 0)
        #expect(tracker.releaseCount == 1)
    }

    @Test
    func spawn_DefiniteFailureWithRetainedCallback_ReleasesArtifact() async {
        let boundary = FakeSpawnBoundary(outcome: .failure)
        let tracker = ArtifactReleaseTracker()
        let sut = makeSUT(boundary: boundary)

        await #expect(throws: FakeSpawnBoundary.Failure.self) {
            try await spawn(sut, releaseTracker: tracker)
        }

        #expect(tracker.releaseCount == 1)
        boundary.terminate(call: 0)
        #expect(tracker.releaseCount == 1)
    }

    @Test
    func spawn_CallbackBeforeReturn_ReleasesArtifactOnce() async throws {
        let boundary = FakeSpawnBoundary(outcome: .callbackBeforeReturn)
        let tracker = ArtifactReleaseTracker()
        let sut = makeSUT(boundary: boundary)

        _ = try await spawn(sut, releaseTracker: tracker)

        #expect(tracker.releaseCount == 1)
    }

    @Test
    func spawn_TwoGenerations_ReleaseOnlyAfterEachCallback() async throws {
        let boundary = FakeSpawnBoundary()
        let tracker = ArtifactReleaseTracker()
        let sut = makeSUT(boundary: boundary)
        _ = try await spawn(sut, releaseTracker: tracker)
        _ = try await spawn(sut, releaseTracker: tracker)

        #expect(tracker.releaseCount == 0)
        boundary.terminate(call: 0)
        #expect(tracker.releaseCount == 1)
        boundary.terminate(call: 1)
        #expect(tracker.releaseCount == 2)
    }

    @Test
    func spawn_TwoGenerationsSharingArtifact_ReleaseAfterLastCallback() async throws {
        let boundary = FakeSpawnBoundary()
        let tracker = ArtifactReleaseTracker()
        let sut = makeSUT(boundary: boundary)
        var stagedAppex: StagedAppex? = StagedAppex(
            binaryPath: FakeSpawnBoundary.binaryPath,
            rootOwner: ArtifactOwner(releaseTracker: tracker)
        )
        _ = try await spawn(sut, stagedAppex: try #require(stagedAppex))
        _ = try await spawn(sut, stagedAppex: try #require(stagedAppex))
        stagedAppex = nil

        boundary.terminate(call: 0)
        #expect(tracker.releaseCount == 0)
        boundary.terminate(call: 1)
        #expect(tracker.releaseCount == 1)
    }

    private func makeSUT(
        boundary: GatedSpawnBoundary,
        killer: ProcessKillRecorder
    ) -> AppexSpawner {
        AppexSpawner(
            spawnOperation: { path, _, _, _, processTerminated in
                await boundary.spawn(path: path, processTerminated: processTerminated)
            },
            processKiller: killer.record
        )
    }

    private func makeSUT(
        boundary: FakeSpawnBoundary,
        killer: ProcessKillRecorder = ProcessKillRecorder()
    ) -> AppexSpawner {
        AppexSpawner(
            spawnOperation: boundary.spawn,
            processKiller: killer.record
        )
    }

    private func spawn(_ sut: AppexSpawner) async throws -> SpawnedAppex {
        try await sut.spawn(
            stagedAppex: StagedAppex(
                binaryPath: GatedSpawnBoundary.binaryPath,
                rootOwner: StubStagedArtifactOwner()
            ),
            simulatorUDID: UUID().uuidString,
            simctlSetPath: nil,
            environment: [:]
        )
    }

    private func spawn(
        _ sut: AppexSpawner,
        releaseTracker: ArtifactReleaseTracker
    ) async throws -> SpawnedAppex {
        try await sut.spawn(
            stagedAppex: StagedAppex(
                binaryPath: FakeSpawnBoundary.binaryPath,
                rootOwner: ArtifactOwner(releaseTracker: releaseTracker)
            ),
            simulatorUDID: UUID().uuidString,
            simctlSetPath: nil,
            environment: [:]
        )
    }

    private func spawn(
        _ sut: AppexSpawner,
        stagedAppex: StagedAppex
    ) async throws -> SpawnedAppex {
        try await sut.spawn(
            stagedAppex: stagedAppex,
            simulatorUDID: UUID().uuidString,
            simctlSetPath: nil,
            environment: [:]
        )
    }
}

private final class ArtifactOwner: Sendable {
    private let releaseTracker: ArtifactReleaseTracker

    init(releaseTracker: ArtifactReleaseTracker) {
        self.releaseTracker = releaseTracker
    }

    deinit {
        releaseTracker.recordRelease()
    }
}

private final class ArtifactReleaseTracker: Sendable {
    private let count = Mutex(0)

    var releaseCount: Int { count.withLock { $0 } }

    func recordRelease() {
        count.withLock { $0 += 1 }
    }
}

private final class FakeSpawnBoundary: Sendable {
    enum Failure: Error {
        case spawn
    }

    enum Outcome: Sendable {
        case callbackBeforeReturn
        case failure
        case success
    }

    private struct State {
        var callbacks: [@Sendable () -> Void] = []
    }

    static let binaryPath = "/private/tmp/Test.appex/Binary"

    private let outcome: Outcome
    private let state = Mutex(State())

    init(outcome: Outcome = .success) {
        self.outcome = outcome
    }

    var callbackCount: Int { state.withLock { $0.callbacks.count } }

    func spawn(
        stagedBinary _: String,
        simulatorUDID _: String,
        simctlSetPath _: String?,
        environment _: [String: String],
        processTerminated: @escaping @Sendable () -> Void
    ) async throws -> AppexSpawner.SpawnResult {
        let call = state.withLock { state -> Int in
            state.callbacks.append(processTerminated)
            return state.callbacks.count
        }
        switch outcome {
        case .callbackBeforeReturn:
            processTerminated()
        case .failure:
            throw Failure.spawn
        case .success:
            break
        }
        return AppexSpawner.SpawnResult(
            pid: pid_t(call),
            birthIdentity: ProcessBirthIdentity(seconds: UInt64(call), microseconds: 0)
        )
    }

    func terminate(call: Int) {
        let callback = state.withLock { $0.callbacks[call] }
        callback()
    }
}

private final class StubStagedArtifactOwner: Sendable {}

private final class ProcessKillRecorder: Sendable {
    private let storage = Mutex<[SpawnedAppex]>([])

    var processes: [SpawnedAppex] {
        storage.withLock { $0 }
    }

    func record(_ process: SpawnedAppex) {
        storage.withLock { $0.append(process) }
    }
}

private actor GatedSpawnBoundary {
    static let binaryPath = "/tmp/Test.appex/Binary"

    private let firstSpawnGate = AsyncSignal()
    private var processTerminations: [@Sendable () -> Void] = []
    private var spawnCount = 0
    let firstSpawnEntered = AsyncSignal()

    nonisolated func releaseFirstSpawn() {
        firstSpawnGate.fire()
    }

    func spawn(
        path _: String,
        processTerminated: @escaping @Sendable () -> Void
    ) async -> AppexSpawner.SpawnResult {
        spawnCount += 1
        let call = spawnCount
        processTerminations.append(processTerminated)
        if call == 1 {
            firstSpawnEntered.fire()
            await firstSpawnGate.wait()
        }
        return AppexSpawner.SpawnResult(
            pid: pid_t(call),
            birthIdentity: ProcessBirthIdentity(seconds: UInt64(call), microseconds: 0)
        )
    }

    func terminateFirstProcess() {
        processTerminations.first?()
    }
}
