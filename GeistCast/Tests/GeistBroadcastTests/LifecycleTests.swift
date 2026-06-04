import CoreMedia
import CoreVideo
import Foundation
import Darwin
import Synchronization
import Testing
@testable import GeistBroadcast

@Suite(.serialized) struct LifecycleTests {

    @Test
    func pause_whenNoActiveBroadcast_throwsNotBroadcasting() async throws {
        let sut = createSUT()
        try await sut.start()

        await #expect(throws: GeistBroadcastSession.SessionError.notBroadcasting) {
            try await sut.pause()
        }

        await sut.stop()
    }

    @Test
    func resume_whenNoActiveBroadcast_throwsNotBroadcasting() async throws {
        let sut = createSUT()
        try await sut.start()

        await #expect(throws: GeistBroadcastSession.SessionError.notBroadcasting) {
            try await sut.resume()
        }

        await sut.stop()
    }

    @Test
    func pause_whileBroadcastActive_writesPauseToExtensionSocket() async throws {
        let spy = SpyDelegate()
        let sut = createSUT(delegate: spy)
        try await sut.start()
        let extFD = try await joinAsExtensionAndStartBroadcast(sut, delegate: spy)
        defer { close(extFD) }

        try await sut.pause()

        let message = try await readWireMessage(from: extFD)
        #expect(message == .pause)

        await sut.stop()
    }

    @Test
    func pauseThenResume_whileBroadcastActive_writesPauseThenResumeToExtensionSocket() async throws {
        let spy = SpyDelegate()
        let sut = createSUT(delegate: spy)
        try await sut.start()
        let extFD = try await joinAsExtensionAndStartBroadcast(sut, delegate: spy)
        defer { close(extFD) }

        try await sut.pause()
        try await sut.resume()

        let first = try await readWireMessage(from: extFD)
        let second = try await readWireMessage(from: extFD)
        #expect(first == .pause)
        #expect(second == .resume)

        await sut.stop()
    }

    @Test
    func resume_whenBroadcastActiveButNotPaused_isNoOpWritingNothing() async throws {
        let spy = SpyDelegate()
        let sut = createSUT(delegate: spy)
        try await sut.start()
        let extFD = try await joinAsExtensionAndStartBroadcast(sut, delegate: spy)
        defer { close(extFD) }

        try await sut.resume()

        await #expect(throws: SocketReadError.timeout) {
            _ = try await readWireMessage(from: extFD, timeoutSeconds: 0.3)
        }

        await sut.stop()
    }

    @Test
    func pause_calledTwiceWhileActive_writesPauseOnlyOnce() async throws {
        let spy = SpyDelegate()
        let sut = createSUT(delegate: spy)
        try await sut.start()
        let extFD = try await joinAsExtensionAndStartBroadcast(sut, delegate: spy)
        defer { close(extFD) }

        try await sut.pause()
        try await sut.pause()

        let first = try await readWireMessage(from: extFD)
        #expect(first == .pause)
        await #expect(throws: SocketReadError.timeout) {
            _ = try await readWireMessage(from: extFD, timeoutSeconds: 0.3)
        }

        await sut.stop()
    }

    @Test
    func extensionTerminated_whileBroadcastActive_firesTerminatedDelegateWithError() async throws {
        let spy = SpyDelegate()
        let sut = createSUT(delegate: spy)
        try await sut.start()
        let extFD = try await joinAsExtensionAndStartBroadcast(sut, delegate: spy)
        defer { close(extFD) }

        let envelope: [String: Any] = [
            "type": "extension_terminated",
            "errorDomain": "TestDomain",
            "errorCode": 42,
            "errorMessage": "boom",
        ]
        try sendJSONLine(envelope, to: extFD)
        await spy.terminatedSignal.wait()

        let termination = try #require(spy.terminations.first)
        #expect(termination.error.domain == "TestDomain")
        #expect(termination.error.code == 42)
        #expect(termination.error.message == "boom")
        #expect(await sut.activeBroadcasts.isEmpty)

        await sut.stop()
    }

    @Test
    func broadcastEndedEnvelope_afterStopBroadcast_doesNotRefireDelegateOrResendToHost() async throws {
        let spy = SpyDelegate()
        let sut = createSUT(delegate: spy)
        try await sut.start()

        let hostFD = try connectClient(toSocketOf: sut)
        defer { close(hostFD) }
        try sendMessage(.helloHost, to: hostFD)
        _ = try await readWireMessage(from: hostFD)

        let extFD = try await joinAsExtensionAndStartBroadcast(sut, delegate: spy)
        defer { close(extFD) }
        // joinAsExtensionAndStartBroadcast triggers a forwarded .broadcastStarted
        // to the host; drain it before exercising the stop path.
        _ = try await readWireMessage(from: hostFD)

        await sut.stopBroadcast()
        await spy.broadcastEndedSignal.wait()
        let firstEnded = try await readWireMessage(from: hostFD)
        if case .broadcastEnded = firstEnded {} else {
            Issue.record("expected broadcastEnded, got \(firstEnded)")
        }
        #expect(spy.ends.count == 1)

        let broadcast = Broadcast(
            simulatorUDID: sut.simulator,
            hostAppBundleID: sut.hostBundleID,
            extensionBundleID: "com.test.host.cast",
            startedAt: ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")!
        )
        try sendMessage(.broadcastEnded(broadcast), to: extFD)

        await #expect(throws: SocketReadError.timeout) {
            _ = try await readWireMessage(from: hostFD, timeoutSeconds: 0.3)
        }
        #expect(spy.ends.count == 1)

        await sut.stop()
    }

    @Test
    func extensionFDClosed_whileBroadcastActive_firesBroadcastEndedAndClearsActiveBroadcasts() async throws {
        let spy = SpyDelegate()
        let sut = createSUT(delegate: spy)
        try await sut.start()
        let extFD = try await joinAsExtensionAndStartBroadcast(sut, delegate: spy)

        close(extFD)
        await spy.broadcastEndedSignal.wait()

        #expect(spy.ends.count == 1)
        #expect(spy.terminations.isEmpty)
        #expect(await sut.activeBroadcasts.isEmpty)

        await sut.stop()
    }

    @Test
    func extensionFDClosed_beforeBroadcastStarted_firesFailedToStartWithExtensionDiedBeforeStart() async throws {
        let spy = SpyDelegate()
        let spawner = GatedSpawner()
        let sut = createSUT(delegate: spy, spawner: spawner)
        try await sut.start()

        let hostFD = try connectClient(toSocketOf: sut)
        defer { close(hostFD) }
        try sendMessage(.helloHost, to: hostFD)
        _ = try await readWireMessage(from: hostFD)

        let extFD = try connectClient(toSocketOf: sut)
        try sendMessage(.helloExtension(extensionBundleID: "com.test.host.cast"), to: extFD)
        await spy.extensionConnected.wait()
        try sendMessage(.userPressedStart(micEnabled: false), to: hostFD)
        await spawner.spawnEntered.wait()

        close(extFD)
        await spy.failedToStartSignal.wait()

        let failure = try #require(spy.failures.first)
        #expect(failure.error as? GeistBroadcastSession.SessionError
                == .extensionDiedBeforeStart)

        spawner.release()
        await sut.stop()
    }

    @Test
    func extensionTerminated_beforeBroadcastStarted_firesFailedToStartDelegate() async throws {
        let spy = SpyDelegate()
        let spawner = GatedSpawner()
        let sut = createSUT(delegate: spy, spawner: spawner)
        try await sut.start()

        let hostFD = try connectClient(toSocketOf: sut)
        defer { close(hostFD) }
        try sendMessage(.helloHost, to: hostFD)
        _ = try await readWireMessage(from: hostFD)

        let extFD = try connectClient(toSocketOf: sut)
        defer { close(extFD) }
        try sendMessage(.helloExtension(extensionBundleID: "com.test.host.cast"), to: extFD)
        await spy.extensionConnected.wait()
        try sendMessage(.userPressedStart(micEnabled: false), to: hostFD)
        await spawner.spawnEntered.wait()

        let envelope: [String: Any] = [
            "type": "extension_terminated",
            "errorDomain": "Pre",
            "errorCode": 7,
            "errorMessage": "before start",
        ]
        try sendJSONLine(envelope, to: extFD)
        await spy.failedToStartSignal.wait()

        let failure = try #require(spy.failures.first)
        let asTermination = try #require(failure.error as? ExtensionTerminationError)
        #expect(asTermination.domain == "Pre")
        #expect(asTermination.code == 7)

        spawner.release()
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
        stager: any AppexStaging = StubStager(),
        spawner: any AppexSpawning = StubSpawner()
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
            spawner: spawner
        )
    }

    private func joinAsExtensionAndStartBroadcast(
        _ sut: GeistBroadcastSession,
        delegate: SpyDelegate,
        extensionBundleID: String = "com.test.host.cast"
    ) async throws -> Int32 {
        let fd = try connectClient(toSocketOf: sut)
        try sendMessage(.helloExtension(extensionBundleID: extensionBundleID), to: fd)
        await delegate.extensionConnected.wait()

        let broadcast = Broadcast(
            simulatorUDID: sut.simulator,
            hostAppBundleID: sut.hostBundleID,
            extensionBundleID: extensionBundleID,
            startedAt: ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")!
        )
        try sendMessage(.broadcastStarted(broadcast), to: fd)
        await delegate.broadcastStartedSignal.wait()
        return fd
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

    private func sendMessage(_ message: WireMessage, to fd: Int32) throws {
        let bytes = Array(WireEncoder().encode(message))
        try sendBytes(bytes, to: fd)
    }

    private func sendJSONLine(_ json: [String: Any], to fd: Int32) throws {
        var data = try JSONSerialization.data(withJSONObject: json, options: [])
        data.append(0x0A)
        try sendBytes(Array(data), to: fd)
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

private struct TerminationCapture: Sendable {
    let broadcast: Broadcast
    let error: ExtensionTerminationError
}

private struct FailureCapture: @unchecked Sendable {
    let broadcast: Broadcast
    let error: Error
}

private final class SpyDelegate: GeistBroadcastSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _terminations: [TerminationCapture] = []
    private var _failures: [FailureCapture] = []
    private var _ends: [Broadcast] = []
    let extensionConnected = AsyncSignal()
    let broadcastStartedSignal = AsyncSignal()
    let broadcastEndedSignal = AsyncSignal()
    let terminatedSignal = AsyncSignal()
    let failedToStartSignal = AsyncSignal()

    var terminations: [TerminationCapture] { lock.withLock { _terminations } }
    var failures: [FailureCapture] { lock.withLock { _failures } }
    var ends: [Broadcast] { lock.withLock { _ends } }

    func session(_: GeistBroadcastSession, extensionConnectedFor _: String) {
        extensionConnected.fire()
    }

    func session(_: GeistBroadcastSession, broadcastStarted _: Broadcast) {
        broadcastStartedSignal.fire()
    }

    func session(_: GeistBroadcastSession, broadcastEnded broadcast: Broadcast) {
        lock.withLock { _ends.append(broadcast) }
        broadcastEndedSignal.fire()
    }

    func session(_: GeistBroadcastSession,
                 broadcast: Broadcast,
                 terminatedWithError error: Error) {
        guard let typed = error as? ExtensionTerminationError else { return }
        lock.withLock {
            _terminations.append(TerminationCapture(broadcast: broadcast, error: typed))
        }
        terminatedSignal.fire()
    }

    func session(_: GeistBroadcastSession,
                 broadcastFailedToStart broadcast: Broadcast,
                 error: Error) {
        lock.withLock {
            _failures.append(FailureCapture(broadcast: broadcast, error: error))
        }
        failedToStartSignal.fire()
    }
}

private final class StubStager: AppexStaging {
    func stage(appexAt sourcePath: String) async throws -> StagedAppex {
        StagedAppex(binaryPath: "\(sourcePath)/staged/Binary")
    }
}

private final class StubSpawner: AppexSpawning {
    func spawn(stagedBinary: String,
               simulatorUDID: String,
               simctlSetPath: String?,
               environment: [String: String]) async throws {}
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

private final class SilentVideoProducer: VideoFrameProducer {
    func start(producing handler: @escaping @Sendable (CVPixelBuffer, CMTime) -> Void) throws {}
    func stop() {}
}

