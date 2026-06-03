import CoreMedia
import CoreVideo
import Foundation
import Darwin
import Synchronization
import Testing
@testable import GeistBroadcast

@Suite(.serialized) struct GeistBroadcastSessionTests {

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

        if case .state(let recording, let broadcast, let micEnabled, _) = reply {
            #expect(recording == false)
            #expect(broadcast == nil)
            #expect(micEnabled == false)
        } else {
            Issue.record("expected state reply, got \(reply)")
        }

        await sut.stop()
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
        let spawner = SpySpawner()
        let sut = createSUT(spawner: spawner)
        try await sut.start()
        let hostFD = try connectClient(toSocketOf: sut)
        defer { close(hostFD) }

        try sendMessage(.userPressedStart(micEnabled: false), to: hostFD)
        await spawner.firstCall.wait()
        try sendMessage(.userCancelledStart, to: hostFD)
        try sendMessage(.userPressedStart(micEnabled: false), to: hostFD)

        await spawner.callCountReached(2)
        #expect(spawner.calls.count == 2)

        await sut.stop()
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

    private func wireLine(type: String) -> Data {
        let body = """
        {"type":"\(type)","simulatorUDID":"SIM","hostAppBundleID":"com.test.host","extensionBundleID":"com.test.host.cast","startedAt":"2026-01-01T00:00:00Z"}\n
        """
        return Data(body.utf8)
    }

    private func connectClient(toSocketOf session: GeistBroadcastSession) throws -> Int32 {
        let path = session.socketPath
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
    let broadcastStarted = AsyncSignal()
    let broadcastEnded = AsyncSignal()
    let broadcastFailedToStart = AsyncSignal()
    let extensionConnected = AsyncSignal()

    var starts: [Broadcast] { lock.withLock { _starts } }
    var ends: [Broadcast] { lock.withLock { _ends } }
    var failures: [Broadcast] { lock.withLock { _failures } }

    func session(_: GeistBroadcastSession, broadcastStarted: Broadcast) {
        lock.withLock { _starts.append(broadcastStarted) }
        self.broadcastStarted.fire()
    }

    func session(_: GeistBroadcastSession, broadcastEnded: Broadcast) {
        lock.withLock { _ends.append(broadcastEnded) }
        self.broadcastEnded.fire()
    }

    func session(_: GeistBroadcastSession, extensionConnectedFor _: String) {
        extensionConnected.fire()
    }

    func session(_: GeistBroadcastSession,
                 broadcastFailedToStart broadcast: Broadcast,
                 error: Error) {
        lock.withLock { _failures.append(broadcast) }
        self.broadcastFailedToStart.fire()
    }
}

private struct StubError: Error, Equatable {}

private final class StubFailingSpawner: AppexSpawning {
    func spawn(stagedBinary: String,
               simulatorUDID: String,
               simctlSetPath: String?,
               environment: [String: String]) async throws {
        throw StubError()
    }
    func killStale(stagedBinary: String) async {}
}

private final class GatedSpawner: AppexSpawning {
    private let gate = AsyncSignal()
    let spawnEntered = AsyncSignal()

    func release() { gate.fire() }

    func spawn(stagedBinary: String,
               simulatorUDID: String,
               simctlSetPath: String?,
               environment: [String: String]) async throws {
        spawnEntered.fire()
        await gate.wait()
    }
    func killStale(stagedBinary: String) async {}
}

private final class FakeStager: AppexStaging {
    private let paths = Mutex<[String]>([])
    let firstCall = AsyncSignal()

    var appexPaths: [String] { paths.withLock { $0 } }

    func stage(appexAt sourcePath: String) async throws -> StagedAppex {
        let isFirst = paths.withLock { current -> Bool in
            current.append(sourcePath)
            return current.count == 1
        }
        if isFirst { firstCall.fire() }
        return StagedAppex(binaryPath: "\(sourcePath)/staged/Binary")
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

    func spawn(stagedBinary: String,
               simulatorUDID: String,
               simctlSetPath: String?,
               environment: [String: String]) async throws {
        let (isFirst, count) = invocations.withLock { current -> (Bool, Int) in
            current.append((stagedBinary, simulatorUDID, simctlSetPath, environment))
            return (current.count == 1, current.count)
        }
        if isFirst { firstCall.fire() }
        let signal = perCall.withLock { signals -> AsyncSignal in
            while signals.count < count { signals.append(AsyncSignal()) }
            return signals[count - 1]
        }
        signal.fire()
    }
    func killStale(stagedBinary: String) async {}
}

private final class SilentVideoProducer: VideoFrameProducer {
    func start(producing handler: @escaping @Sendable (CVPixelBuffer, CMTime) -> Void) throws {}
    func stop() {}
}

