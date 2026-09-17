import CoreMedia
import CoreVideo
import Foundation
import Darwin
import Synchronization
import Testing
@testable import GeistBroadcast

@Suite(.serialized) struct GeistBroadcastSessionTests {

    @Test(arguments: [EAGAIN, EWOULDBLOCK])
    func acceptErrorAction_WhenListenerIsDrained_ReturnsDrained(error: Int32) {
        #expect(GeistBroadcastSession.acceptErrorAction(errno: error) == .drained)
    }

    @Test
    func acceptErrorAction_WhenReadIsInterrupted_ReturnsRetry() {
        #expect(GeistBroadcastSession.acceptErrorAction(errno: EINTR) == .retry)
    }

    @Test
    func acceptErrorAction_WhenSocketPermanentlyFails_ReturnsFail() {
        #expect(GeistBroadcastSession.acceptErrorAction(errno: EBADF) == .fail)
    }

    @Test
    func socketPath_differentSimulators_yieldDifferentPaths() {
        let sutA = createSUT(simulator: "S1", hostBundleID: "com.b")
        let sutB = createSUT(simulator: "S2", hostBundleID: "com.b")

        #expect(sutA.socketPath != sutB.socketPath)
    }

    @Test
    func socketPath_differentBundleIDs_yieldDifferentPaths() {
        let sutA = createSUT(simulator: "S", hostBundleID: "com.a")
        let sutB = createSUT(simulator: "S", hostBundleID: "com.b")

        #expect(sutA.socketPath != sutB.socketPath)
    }

    @Test
    func start_WhenFrameSocketPathIsTooLong_RollsBackControlListener() async {
        let capacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        let prefix = "/tmp/geistcast-"
        let suffix = "-b.sock"
        let simulator = String(repeating: "s", count: capacity - prefix.count - suffix.count - 1)
        let sut = createSUT(simulator: simulator, hostBundleID: "b")

        await #expect(throws: GeistBroadcastSession.SessionError.self) {
            try await sut.start()
        }

        #expect(!FileManager.default.fileExists(atPath: sut.socketPath))
        await sut.stop()
    }

    @Test
    func start_WhenFrameSocketPathIsOccupied_RollsBackOnlyControlListener() async throws {
        let simulator = "SIM-\(UUID().uuidString.prefix(8))"
        let hostBundleID = "com.test.host"
        let framePath = "/tmp/geistcast-frames-\(simulator)-\(hostBundleID).sock"
        try FileManager.default.createDirectory(atPath: framePath, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: framePath) }
        let sut = createSUT(simulator: simulator, hostBundleID: hostBundleID)

        await #expect(throws: GeistBroadcastSession.SessionError.self) {
            try await sut.start()
        }

        #expect(!FileManager.default.fileExists(atPath: sut.socketPath))
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: framePath, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        await sut.stop()
    }

    @Test
    func broadcastStartedLine_fromExtension_firesStartedDelegateAndActivatesBroadcast() async throws {
        let broadcast = makeBroadcast()
        let spy = SpyDelegate()
        let sut = createSUT(delegate: spy)
        try await sut.start()

        try await write(wireLine(type: "started"), toSocketOf: sut)
        await spy.broadcastStarted.wait()

        #expect(spy.starts == [broadcast])
        #expect(await sut.activeBroadcasts == [broadcast])

        await sut.stop()
    }

    @Test
    func broadcastEndedLine_fromExtension_firesEndedDelegateAndRemovesBroadcast() async throws {
        let broadcast = makeBroadcast()
        let spy = SpyDelegate()
        let sut = createSUT(delegate: spy)
        try await sut.start()
        try await write(wireLine(type: "started"), toSocketOf: sut)
        await spy.broadcastStarted.wait()

        try await write(wireLine(type: "ended"), toSocketOf: sut)
        await spy.broadcastEnded.wait()

        #expect(spy.ends == [broadcast])
        #expect(await sut.activeBroadcasts.isEmpty)

        await sut.stop()
    }

    @Test
    func helloHost_whenNoActiveBroadcast_repliesStateRecordingFalse() async throws {
        let sut = createSUT()
        try await sut.start()
        let fd = try connectClient(toSocketOf: sut)
        defer { close(fd) }

        try sendMessage(.helloHost, to: fd)
        let reply = try await readWireMessage(from: fd)

        if case .state(let recording, let broadcast, let micEnabled, _, _) = reply {
            #expect(recording == false)
            #expect(broadcast == nil)
            #expect(micEnabled == false)
        } else {
            Issue.record("expected state reply, got \(reply)")
        }

        await sut.stop()
    }

    @Test
    func stop_AfterClientHandshake_ClosesPeerSocket() async throws {
        let sut = createSUT()
        try await sut.start()
        let fd = try connectClient(toSocketOf: sut)
        defer { close(fd) }
        try sendMessage(.helloHost, to: fd)
        _ = try await readWireMessage(from: fd)

        await sut.stop()

        #expect(await readByteCount(from: fd) == 0)
    }

    @Test
    func userPressedStart_afterHelloHostHandshake_invokesStagerWithExtensionAppexPath() async throws {
        let stager = FakeStager()
        let spawner = SpySpawner()
        let extContext = ExtensionContext(
            bundleID: "com.ext", appexPath: "/path/to/Ext.appex"
        )
        let sut = createSUT(
            extension: extContext, stager: stager, spawner: spawner
        )
        try await sut.start()
        let fd = try connectClient(toSocketOf: sut)
        defer { close(fd) }

        try sendMessage(.helloHost, to: fd)
        _ = try await readWireMessage(from: fd)
        try sendMessage(.userPressedStart(micEnabled: false), to: fd)
        await stager.firstCall.wait()

        #expect(stager.appexPaths == ["/path/to/Ext.appex"])

        await sut.stop()
    }

    @Test
    func userPressedStart_afterStagerSucceeds_invokesSpawner() async throws {
        let stager = FakeStager()
        let spawner = SpySpawner()
        let sut = createSUT(stager: stager, spawner: spawner)
        try await sut.start()
        let fd = try connectClient(toSocketOf: sut)
        defer { close(fd) }

        try sendMessage(.helloHost, to: fd)
        _ = try await readWireMessage(from: fd)
        try sendMessage(.userPressedStart(micEnabled: false), to: fd)
        await spawner.firstCall.wait()

        #expect(spawner.calls.count == 1)

        await sut.stop()
    }

    @Test
    func userPressedStart_whenExtensionShimDylibMissing_delegateReceivesBroadcastFailedToStart() async throws {
        let delegate = SpyDelegate()
        let sut = createSUT(
            delegate: delegate,
            extensionShimDylibPath: "/tmp/this-path-does-not-exist-\(UUID().uuidString).dylib"
        )
        try await sut.start()
        let fd = try connectClient(toSocketOf: sut)
        defer { close(fd) }

        try sendMessage(.helloHost, to: fd)
        _ = try await readWireMessage(from: fd)
        try sendMessage(.userPressedStart(micEnabled: false), to: fd)
        await delegate.broadcastFailedToStart.wait()

        #expect(delegate.failures.count == 1)
        #expect(delegate.starts.isEmpty)

        await sut.stop()
    }

    @Test
    func userPressedStart_whenSpawnerThrows_delegateReceivesBroadcastFailedToStart() async throws {
        let delegate = SpyDelegate()
        let sut = createSUT(delegate: delegate, spawner: StubFailingSpawner())
        try await sut.start()
        let fd = try connectClient(toSocketOf: sut)
        defer { close(fd) }

        try sendMessage(.helloHost, to: fd)
        _ = try await readWireMessage(from: fd)
        try sendMessage(.userPressedStart(micEnabled: false), to: fd)
        await delegate.broadcastFailedToStart.wait()

        #expect(delegate.failures.count == 1)
        #expect(delegate.starts.isEmpty)

        await sut.stop()
    }

    @Test
    func userPressedStop_whileSpawnerStillBlocked_forwardsFinishToExtension() async throws {
        let spawner = GatedSpawner()
        let delegate = SpyDelegate()
        let sut = createSUT(delegate: delegate, spawner: spawner)
        try await sut.start()

        let hostFD = try connectClient(toSocketOf: sut)
        defer { close(hostFD) }
        try sendMessage(.helloHost, to: hostFD)
        _ = try await readWireMessage(from: hostFD)

        let extFD = try connectClient(toSocketOf: sut)
        defer { close(extFD) }
        try sendMessage(.helloExtension(extensionBundleID: "com.test.host.cast"), to: extFD)
        await delegate.extensionConnected.wait()

        try sendMessage(.userPressedStart(micEnabled: false), to: hostFD)
        await spawner.spawnEntered.wait()
        // Extension was connected before start was pressed, so a `begin` is
        // sent immediately on userPressedStart; skip it to reach `finish`.
        let begin = try await readWireMessage(from: extFD)
        if case .begin = begin {} else { Issue.record("expected begin, got \(begin)") }
        try sendMessage(.userPressedStop, to: hostFD)

        let message = try await readWireMessage(from: extFD)
        #expect(message == .finish)

        spawner.release()
        await sut.stop()
    }

    @Test
    func userCancelledStart_afterPressedStart_closesExtensionFDAndClearsPendingBroadcast() async throws {
        let delegate = SpyDelegate()
        let sut = createSUT(delegate: delegate)
        try await sut.start()
        let hostFD = try connectClient(toSocketOf: sut)
        defer { close(hostFD) }
        let extFD = try connectClient(toSocketOf: sut)
        defer { close(extFD) }

        try sendMessage(.userPressedStart(micEnabled: false), to: hostFD)
        try sendMessage(.helloExtension(extensionBundleID: "com.test.host.cast"), to: extFD)
        await delegate.extensionConnected.wait()
        let begin = try await readWireMessage(from: extFD)
        if case .begin = begin {} else { Issue.record("expected begin, got \(begin)") }

        try sendMessage(.userCancelledStart, to: hostFD)

        var buf = [UInt8](repeating: 0, count: 16)
        let n = buf.withUnsafeMutableBufferPointer { read(extFD, $0.baseAddress, $0.count) }
        #expect(n == 0)

        await sut.stop()
    }

    @Test
    func userPressedStart_afterCancel_armsFreshBroadcastAndSpawnsAgain() async throws {
        let releaseTracker = SessionArtifactReleaseTracker()
        let stager = FakeStager(releaseTracker: releaseTracker)
        let spawner = SpySpawner()
        let sut = createSUT(stager: stager, spawner: spawner)
        try await sut.start()
        let hostFD = try connectClient(toSocketOf: sut)
        defer { close(hostFD) }

        try sendMessage(.userPressedStart(micEnabled: false), to: hostFD)
        await spawner.firstCall.wait()
        try sendMessage(.userCancelledStart, to: hostFD)
        try sendMessage(.userPressedStart(micEnabled: false), to: hostFD)

        await spawner.callCountReached(2)
        #expect(spawner.calls.count == 2)
        #expect(stager.appexPaths.count == 1)
        #expect(releaseTracker.releaseCount == 0)

        await sut.stop()
        #expect(await waitUntil { releaseTracker.releaseCount == 1 })
    }

    @Test
    func userPressedStart_afterCancel_WhenStaleLaunchFails_PreservesFreshBroadcast() async throws {
        let delegate = SpyDelegate()
        let spawner = CancelRearmSpawner()
        let sut = createSUT(delegate: delegate, spawner: spawner)
        try await sut.start()
        let hostFD = try connectClient(toSocketOf: sut)
        defer { close(hostFD) }

        try sendMessage(.userPressedStart(micEnabled: false), to: hostFD)
        await spawner.firstSpawnEntered.wait()
        try sendMessage(.userCancelledStart, to: hostFD)
        try sendMessage(.userPressedStart(micEnabled: false), to: hostFD)
        await spawner.secondSpawnReturned.wait()

        spawner.failFirstSpawn()
        await spawner.staleErrorReleased.wait()

        #expect(delegate.failures.isEmpty)
        #expect(await sut.hasInFlightBroadcast)
        await sut.stop()
    }

    @Test
    func extensionDisconnect_WhenNewSpawnReturnsWhileOldConnectionRemains_TerminatesOnlyOldProcess() async throws {
        let delegate = SpyDelegate()
        let spawner = GatedTerminationSpawner()
        let sut = createSUT(delegate: delegate, spawner: spawner)
        try await sut.start()
        let hostFD = try connectClient(toSocketOf: sut)
        defer { close(hostFD) }
        try sendMessage(.userPressedStart(micEnabled: false), to: hostFD)
        #expect(await waitUntil { spawner.liveProcesses.count == 1 })

        let disconnectedFD = try connectClient(toSocketOf: sut)
        try sendMessage(.helloExtension(extensionBundleID: "com.test.host.cast"), to: disconnectedFD)
        #expect(await waitUntil { delegate.extensionConnectionCount == 1 })
        try sendMessage(.broadcastStarted(makeBroadcast()), to: disconnectedFD)
        await delegate.broadcastStarted.wait()

        try sendMessage(.userPressedStart(micEnabled: false), to: hostFD)
        #expect(await waitUntil { spawner.liveProcesses.count == 2 })
        let freshProcess = spawner.liveProcesses.last
        close(disconnectedFD)
        await spawner.terminateEntered.wait()

        spawner.releaseTermination()
        await spawner.terminateFinished.wait()

        #expect(spawner.liveProcesses.count == 1)
        #expect(spawner.liveProcesses.first == freshProcess)
        await sut.stop()
    }

    @Test
    func extensionDisconnect_WhenHelloArrivesBeforeSpawnReturns_TerminatesReturnedProcess() async throws {
        let delegate = SpyDelegate()
        let spawner = DelayedReturnSpawner()
        let sut = createSUT(delegate: delegate, spawner: spawner)
        try await sut.start()
        let hostFD = try connectClient(toSocketOf: sut)
        defer { close(hostFD) }
        try sendMessage(.userPressedStart(micEnabled: false), to: hostFD)
        await spawner.spawnEntered.wait()

        let extensionFD = try connectClient(toSocketOf: sut)
        try sendMessage(.helloExtension(extensionBundleID: "com.test.host.cast"), to: extensionFD)
        #expect(await waitUntil { delegate.extensionConnectionCount == 1 })
        close(extensionFD)
        spawner.releaseSpawn()
        await spawner.terminateCalled.wait()

        #expect(spawner.terminatedProcess == spawner.process)
        await sut.stop()
    }

    @Test
    func stop_AfterControlConnectionAndSessionRelease_CompletesConnectionCleanup() async throws {
        var sut: GeistBroadcastSession? = createSUT()
        weak let releasedSession = sut
        try await sut?.start()
        guard let socketPath = sut?.socketPath else { return }
        let fd = try connectClient(toSocketPath: socketPath)
        defer { close(fd) }
        try sendMessage(.helloHost, to: fd)

        await sut?.stop()
        sut = nil

        #expect(await waitUntil { releasedSession == nil })
    }

    @Test
    func stop_WhileStagingIsBlocked_DoesNotSpawnAfterStagingReturns() async throws {
        let delegate = SpyDelegate()
        let releaseTracker = SessionArtifactReleaseTracker()
        let stager = GatedStager(releaseTracker: releaseTracker)
        let spawner = SpySpawner()
        let sut = createSUT(delegate: delegate, stager: stager, spawner: spawner)
        await stager.firstStageEntered.wait()
        try await sut.start()
        let hostFD = try connectClient(toSocketOf: sut)
        defer { close(hostFD) }
        let extensionFD = try connectClient(toSocketOf: sut)
        defer { close(extensionFD) }
        try sendMessage(.helloExtension(extensionBundleID: "com.test.host.cast"), to: extensionFD)
        await delegate.extensionConnected.wait()
        try sendMessage(.userPressedStart(micEnabled: false), to: hostFD)
        _ = try await readWireMessage(from: extensionFD)

        await sut.stop()
        stager.release()
        await stager.stageReturned.wait()

        #expect(await waitUntil { releaseTracker.releaseCount == 1 })
        #expect(spawner.calls.isEmpty)
    }

    @Test
    func refresh_WhilePriorStagingIsBlocked_ReleasesPriorArtifactAfterReturn() async throws {
        let sourcePath = try makeSourceAppex()
        defer { removeSourceAppex(atPath: sourcePath) }
        let releaseTracker = SessionArtifactReleaseTracker()
        let stager = GatedStager(releaseTracker: releaseTracker)
        let sut = createSUT(
            extension: ExtensionContext(bundleID: "com.test.host.cast", appexPath: sourcePath),
            stager: stager
        )
        await stager.firstStageEntered.wait()
        try Data("changed".utf8).write(to: executableURL(for: sourcePath))

        await sut.refreshStagedAppexIfNeeded()
        await stager.secondStageEntered.wait()
        stager.release()

        #expect(await waitUntil { releaseTracker.releaseCount == 1 })
        await sut.stop()
        #expect(await waitUntil { releaseTracker.releaseCount == 2 })
    }

    @Test
    func refresh_AfterSessionStopped_DoesNotAcquireNewArtifact() async throws {
        let sourcePath = try makeSourceAppex()
        defer { removeSourceAppex(atPath: sourcePath) }
        let stager = FakeStager()
        let sut = createSUT(
            extension: ExtensionContext(bundleID: "com.test.host.cast", appexPath: sourcePath),
            stager: stager
        )
        await stager.firstCall.wait()
        await sut.stop()
        try Data("changed".utf8).write(to: executableURL(for: sourcePath))

        await sut.refreshStagedAppexIfNeeded()
        await Task.yield()

        #expect(stager.appexPaths == [sourcePath])
    }

    @Test
    func stopBroadcast_withNothingInFlight_isNoOp() async throws {
        let sut = createSUT()
        try await sut.start()

        await sut.stopBroadcast()

        #expect(await sut.activeBroadcasts.isEmpty)
        #expect(await sut.hasInFlightBroadcast == false)

        await sut.stop()
    }

    @Test
    func stopBroadcast_whileExtensionConnectedAndArmed_clearsPendingAndNotifiesHost() async throws {
        let delegate = SpyDelegate()
        let sut = createSUT(delegate: delegate)
        try await sut.start()
        let hostFD = try connectClient(toSocketOf: sut)
        defer { close(hostFD) }
        try sendMessage(.helloHost, to: hostFD)
        _ = try await readWireMessage(from: hostFD)

        let extFD = try connectClient(toSocketOf: sut)
        defer { close(extFD) }
        try sendMessage(.helloExtension(extensionBundleID: "com.test.host.cast"), to: extFD)
        await delegate.extensionConnected.wait()
        try sendMessage(.userPressedStart(micEnabled: false), to: hostFD)
        let begin = try await readWireMessage(from: extFD)
        if case .begin = begin {} else { Issue.record("expected begin, got \(begin)") }

        await sut.stopBroadcast()

        let finish = try await readWireMessage(from: extFD)
        #expect(finish == .finish)
        let ended = try await readWireMessage(from: hostFD)
        if case .broadcastEnded = ended {} else { Issue.record("expected broadcastEnded on host fd, got \(ended)") }
        #expect(await sut.hasInFlightBroadcast == false)

        await sut.stop()
    }

    private func createSUT(
        simulator: String = "SIM-\(UUID().uuidString.prefix(8))",
        hostBundleID: String = "com.test.host",
        extension extensionContext: ExtensionContext = ExtensionContext(
            bundleID: "com.test.host.cast",
            appexPath: "/tmp/fake.appex"
        ),
        delegate: SpyDelegate? = nil,
        stager: any AppexStaging = FakeStager(),
        spawner: any AppexSpawning = SpySpawner(),
        extensionShimDylibPath: String? = nil
    ) -> GeistBroadcastSession {
        GeistBroadcastSession(
            simulatorUDID: simulator,
            hostBundleID: hostBundleID,
            extensionContext: extensionContext,
            simctlSetPath: nil,
            videoCapture: .custom(SilentVideoProducer()),
            micAudio: .disabled,
            delegate: delegate,
            stager: stager,
            spawner: spawner,
            appShimDylibPath: nil,
            extensionShimDylibPath: extensionShimDylibPath
        )
    }

    private func makeBroadcast(
        simulatorUDID: String = "SIM",
        hostAppBundleID: String = "com.test.host",
        extensionBundleID: String = "com.test.host.cast",
        startedAt: Date = ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")!
    ) -> Broadcast {
        Broadcast(
            simulatorUDID: simulatorUDID,
            hostAppBundleID: hostAppBundleID,
            extensionBundleID: extensionBundleID,
            startedAt: startedAt
        )
    }

    private func makeSourceAppex() throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "GeistBroadcastSessionTests-\(UUID().uuidString).appex")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        try Data("initial".utf8).write(to: executableURL(for: path.path))
        return path.path
    }

    private func executableURL(for appexPath: String) -> URL {
        let executableName = URL(fileURLWithPath: appexPath)
            .deletingPathExtension()
            .lastPathComponent
        return URL(fileURLWithPath: appexPath).appending(path: executableName)
    }

    private func removeSourceAppex(atPath path: String) {
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            Issue.record("failed to remove test source appex \(path): \(error)")
        }
    }

    private func wireLine(type: String) -> Data {
        let body = """
        {"type":"\(type)","simulatorUDID":"SIM","hostAppBundleID":"com.test.host","extensionBundleID":"com.test.host.cast","startedAt":"2026-01-01T00:00:00Z"}\n
        """
        return Data(body.utf8)
    }

    private func connectClient(toSocketOf session: GeistBroadcastSession) throws -> Int32 {
        try connectClient(toSocketPath: session.socketPath)
    }

    private func connectClient(toSocketPath path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TestError.socket }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
        _ = path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
                tuplePtr.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { dst in
                    strlcpy(dst, src, pathCapacity)
                }
            }
        }
        let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 { return fd }
        let err = errno
        close(fd)
        throw TestError.connect(errno: err)
    }

    private func write(_ line: Data, toSocketOf session: GeistBroadcastSession) async throws {
        let fd = try connectClient(toSocketOf: session)
        defer { close(fd) }
        try sendBytes(Array(line), to: fd)
    }

    private func sendMessage(_ message: WireMessage, to fd: Int32) throws {
        let bytes = Array(WireEncoder().encode(message))
        try sendBytes(bytes, to: fd)
    }

    private func readByteCount(from fd: Int32) async -> Int {
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(
            fd,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
        return await withCheckedContinuation { continuation in
            DispatchQueue(label: "com.geist.broadcast-tests.socket-read").async {
                var byte: UInt8 = 0
                continuation.resume(returning: Darwin.read(fd, &byte, 1))
            }
        }
    }

    private func sendBytes(_ bytes: [UInt8], to fd: Int32) throws {
        var written = 0
        while written < bytes.count {
            let n = bytes.withUnsafeBytes { ptr in
                Darwin.write(fd, ptr.baseAddress!.advanced(by: written), bytes.count - written)
            }
            guard n > 0 else { throw TestError.write }
            written += n
        }
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    private enum TestError: Error {
        case socket
        case connect(errno: Int32)
        case write
    }
}

private final class SpyDelegate: GeistBroadcastSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _starts: [Broadcast] = []
    private var _ends: [Broadcast] = []
    private var _failures: [Broadcast] = []
    private var _extensionConnectionCount = 0
    let broadcastStarted = AsyncSignal()
    let broadcastEnded = AsyncSignal()
    let broadcastFailedToStart = AsyncSignal()
    let extensionConnected = AsyncSignal()

    var starts: [Broadcast] { lock.withLock { _starts } }
    var ends: [Broadcast] { lock.withLock { _ends } }
    var failures: [Broadcast] { lock.withLock { _failures } }
    var extensionConnectionCount: Int { lock.withLock { _extensionConnectionCount } }

    func session(_: GeistBroadcastSession, broadcastStarted: Broadcast) {
        lock.withLock { _starts.append(broadcastStarted) }
        self.broadcastStarted.fire()
    }

    func session(_: GeistBroadcastSession, broadcastEnded: Broadcast) {
        lock.withLock { _ends.append(broadcastEnded) }
        self.broadcastEnded.fire()
    }

    func session(_: GeistBroadcastSession, extensionConnectedFor _: String) {
        lock.withLock { _extensionConnectionCount += 1 }
        extensionConnected.fire()
    }

    func session(_: GeistBroadcastSession,
                 broadcastFailedToStart broadcast: Broadcast,
                 error: Error) {
        lock.withLock { _failures.append(broadcast) }
        self.broadcastFailedToStart.fire()
    }
}

private final class GatedTerminationSpawner: AppexSpawning {
    private struct State {
        var liveProcesses: [SpawnedAppex] = []
    }

    private let gate = AsyncSignal()
    private let state = Mutex(State())
    let terminateEntered = AsyncSignal()
    let terminateFinished = AsyncSignal()

    var liveProcesses: [SpawnedAppex] { state.withLock { $0.liveProcesses } }

    func releaseTermination() { gate.fire() }

    func spawn(
        stagedAppex: StagedAppex,
        simulatorUDID: String,
        simctlSetPath: String?,
        environment: [String: String]
    ) async throws -> SpawnedAppex {
        state.withLock { state in
            let process = SpawnedAppex(
                binaryPath: stagedAppex.binaryPath,
                generation: UUID(),
                pid: getpid()
            )
            state.liveProcesses.append(process)
            return process
        }
    }

    func killStale(stagedBinary: String) async {}

    func terminate(_ process: SpawnedAppex) async {
        terminateEntered.fire()
        await gate.wait()
        state.withLock { $0.liveProcesses.removeAll { $0 == process } }
        terminateFinished.fire()
    }
}

private final class DelayedReturnSpawner: AppexSpawning {
    private let gate = AsyncSignal()
    private let terminated = Mutex<SpawnedAppex?>(nil)
    let process = SpawnedAppex(binaryPath: "/tmp/fake.appex/staged/Binary", generation: UUID(), pid: getpid())
    let spawnEntered = AsyncSignal()
    let terminateCalled = AsyncSignal()

    var terminatedProcess: SpawnedAppex? { terminated.withLock { $0 } }

    func releaseSpawn() { gate.fire() }

    func spawn(
        stagedAppex: StagedAppex,
        simulatorUDID: String,
        simctlSetPath: String?,
        environment: [String: String]
    ) async throws -> SpawnedAppex {
        spawnEntered.fire()
        await gate.wait()
        return process
    }

    func killStale(stagedBinary: String) async {}

    func terminate(_ process: SpawnedAppex) async {
        terminated.withLock { $0 = process }
        terminateCalled.fire()
    }
}

private final class CancelRearmSpawner: AppexSpawning {
    private let firstSpawnGate = AsyncSignal()
    private let spawnCount = Mutex(0)
    let firstSpawnEntered = AsyncSignal()
    let secondSpawnReturned = AsyncSignal()
    let staleErrorReleased = AsyncSignal()

    func failFirstSpawn() { firstSpawnGate.fire() }

    func spawn(
        stagedAppex: StagedAppex,
        simulatorUDID: String,
        simctlSetPath: String?,
        environment: [String: String]
    ) async throws -> SpawnedAppex {
        let call = spawnCount.withLock { count -> Int in
            count += 1
            return count
        }
        if call == 1 {
            firstSpawnEntered.fire()
            await firstSpawnGate.wait()
            throw ObservedLaunchError(onRelease: staleErrorReleased)
        }
        secondSpawnReturned.fire()
        return SpawnedAppex(binaryPath: stagedAppex.binaryPath, generation: UUID(), pid: 2)
    }

    func killStale(stagedBinary: String) async {}
    func terminate(_ process: SpawnedAppex) async {}
}

private final class ObservedLaunchError: Error, @unchecked Sendable {
    private let onRelease: AsyncSignal

    init(onRelease: AsyncSignal) {
        self.onRelease = onRelease
    }

    deinit {
        onRelease.fire()
    }
}

private struct StubError: Error, Equatable {}

private final class StubFailingSpawner: AppexSpawning {
    func spawn(stagedAppex: StagedAppex,
               simulatorUDID: String,
               simctlSetPath: String?,
               environment: [String: String]) async throws -> SpawnedAppex {
        throw StubError()
    }
    func killStale(stagedBinary: String) async {}
    func terminate(_ process: SpawnedAppex) async {}
}

private final class GatedSpawner: AppexSpawning {
    private let gate = AsyncSignal()
    let spawnEntered = AsyncSignal()

    func release() { gate.fire() }

    func spawn(stagedAppex: StagedAppex,
               simulatorUDID: String,
               simctlSetPath: String?,
               environment: [String: String]) async throws -> SpawnedAppex {
        spawnEntered.fire()
        await gate.wait()
        return SpawnedAppex(binaryPath: stagedAppex.binaryPath, generation: UUID(), pid: 1)
    }
    func killStale(stagedBinary: String) async {}
    func terminate(_ process: SpawnedAppex) async {}
}

private final class FakeStager: AppexStaging {
    private let paths = Mutex<[String]>([])
    private let releaseTracker: SessionArtifactReleaseTracker
    let firstCall = AsyncSignal()

    init(releaseTracker: SessionArtifactReleaseTracker = SessionArtifactReleaseTracker()) {
        self.releaseTracker = releaseTracker
    }

    var appexPaths: [String] { paths.withLock { $0 } }

    func stage(appexAt sourcePath: String) async throws -> StagedAppex {
        let isFirst = paths.withLock { current -> Bool in
            current.append(sourcePath)
            return current.count == 1
        }
        if isFirst { firstCall.fire() }
        return StagedAppex(
            binaryPath: "\(sourcePath)/staged/Binary",
            rootOwner: SessionArtifactOwner(releaseTracker: releaseTracker)
        )
    }
}

private final class GatedStager: AppexStaging {
    private let gate = AsyncSignal()
    private let releaseTracker: SessionArtifactReleaseTracker
    private let stageCount = Mutex(0)
    let firstStageEntered = AsyncSignal()
    let secondStageEntered = AsyncSignal()
    let stageReturned = AsyncSignal()

    init(releaseTracker: SessionArtifactReleaseTracker = SessionArtifactReleaseTracker()) {
        self.releaseTracker = releaseTracker
    }

    func release() { gate.fire() }

    func stage(appexAt sourcePath: String) async throws -> StagedAppex {
        let call = stageCount.withLock { count -> Int in
            count += 1
            return count
        }
        if call == 1 {
            firstStageEntered.fire()
        } else if call == 2 {
            secondStageEntered.fire()
        }
        await gate.wait()
        stageReturned.fire()
        return StagedAppex(
            binaryPath: "\(sourcePath)/staged/Binary",
            rootOwner: SessionArtifactOwner(releaseTracker: releaseTracker)
        )
    }
}

private final class SessionArtifactOwner: Sendable {
    private let releaseTracker: SessionArtifactReleaseTracker

    init(releaseTracker: SessionArtifactReleaseTracker) {
        self.releaseTracker = releaseTracker
    }

    deinit {
        releaseTracker.recordRelease()
    }
}

private final class SessionArtifactReleaseTracker: Sendable {
    private let count = Mutex(0)

    var releaseCount: Int { count.withLock { $0 } }

    func recordRelease() {
        count.withLock { $0 += 1 }
    }
}

private final class SpySpawner: AppexSpawning {
    private let invocations = Mutex<[(String, String, String?, [String: String])]>([])
    private let perCall = Mutex<[AsyncSignal]>([])
    let firstCall = AsyncSignal()

    var calls: [(stagedBinary: String, simulator: String, setPath: String?, env: [String: String])] {
        invocations.withLock { $0 }
    }

    func callCountReached(_ n: Int) async {
        let signal = perCall.withLock { signals -> AsyncSignal in
            while signals.count < n { signals.append(AsyncSignal()) }
            return signals[n - 1]
        }
        await signal.wait()
    }

    func spawn(stagedAppex: StagedAppex,
               simulatorUDID: String,
               simctlSetPath: String?,
               environment: [String: String]) async throws -> SpawnedAppex {
        let (isFirst, count) = invocations.withLock { current -> (Bool, Int) in
            current.append((stagedAppex.binaryPath, simulatorUDID, simctlSetPath, environment))
            return (current.count == 1, current.count)
        }
        if isFirst { firstCall.fire() }
        let signal = perCall.withLock { signals -> AsyncSignal in
            while signals.count < count { signals.append(AsyncSignal()) }
            return signals[count - 1]
        }
        signal.fire()
        return SpawnedAppex(
            binaryPath: stagedAppex.binaryPath,
            generation: UUID(),
            pid: pid_t(count)
        )
    }
    func killStale(stagedBinary: String) async {}
    func terminate(_ process: SpawnedAppex) async {}
}

private final class SilentVideoProducer: VideoFrameProducer {
    func start(producing handler: @escaping @Sendable (CVPixelBuffer, CMTime) -> Void) throws {}
    func stop() {}
}
