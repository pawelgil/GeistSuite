import CoreMedia
import CoreVideo
import Foundation
import Darwin
import Synchronization
import Testing
@testable import GeistBroadcast

@Suite(.serialized) struct LifecycleTests {

    @Test(.timeLimit(.minutes(1)))
    func lifecycle_CancelAndRearm_PreservesDistinctOrderedAttempts() async throws {
        let first = PendingSpawn(processID: 101)
        let second = PendingSpawn(processID: 102)
        let sut = createSUT(spawner: FakeProcessSpawner(pending: [first, second]))
        let events = await sut.lifecycleEvents()
        let hostFD = try await startWithHost(sut)
        defer { close(hostFD) }
        try await startAttempt(over: hostFD, spawning: first)
        let initial = await sut.snapshot()

        try await cancelAndRearm(over: hostFD, spawning: second)
        let replacement = await sut.snapshot()
        await sut.stopBroadcast()
        first.release.fire()
        second.release.fire()
        _ = try await first.process.termination.wait()
        _ = try await second.process.termination.wait()
        await sut.stop()

        let ends = try await collectedEnds(events)
        #expect(initial.attemptID != replacement.attemptID)
        #expect(replacement.attemptSequence == initial.attemptSequence + 1)
        #expect(ends.map(\.attemptID) == [initial.attemptID, replacement.attemptID])
        #expect(ends.map(\.sequence) == [initial.attemptSequence, replacement.attemptSequence])
        #expect(ends.map(\.reason) == [.cancelled, .stopped])
    }

    @Test(.timeLimit(.minutes(1)))
    func lifecycle_LaunchFailsBeforePID_EmitsOneIdentifiedFailure() async throws {
        let spawner = GatedFailingSpawner()
        let sut = createSUT(spawner: spawner)
        let events = await sut.lifecycleEvents()
        let hostFD = try await startWithHost(sut)
        defer { close(hostFD) }
        try sendMessage(.userPressedStart(micEnabled: false), to: hostFD)
        await spawner.entered.wait()
        let initial = await sut.snapshot()

        spawner.release.fire()
        var iterator = events.makeAsyncIterator()
        let end = try requireEnded(await iterator.next())
        await sut.stop()

        #expect(end.attemptID == initial.attemptID)
        #expect(end.sequence == initial.attemptSequence)
        #expect(end.processID == nil)
        #expect(end.reason == .failed(ExtensionTerminationError(
            domain: spawner.error.domain, code: spawner.error.code,
            message: spawner.error.localizedDescription
        )))
        #expect(await iterator.next() == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func lifecycle_StaleSpawnReturns_PreservesNewAttemptAndProcess() async throws {
        let first = PendingSpawn(processID: 101)
        let second = PendingSpawn(processID: 102)
        let spawner = FakeProcessSpawner(pending: [first, second])
        let sut = createSUT(spawner: spawner)
        let events = await sut.lifecycleEvents()
        let hostFD = try await startWithHost(sut)
        defer { close(hostFD) }
        try await startAttempt(over: hostFD, spawning: first)
        try await cancelAndRearm(over: hostFD, spawning: second)
        second.release.fire()
        var iterator = events.makeAsyncIterator()
        let cancelled = try requireEnded(await iterator.next())
        let replacement = try requireProcessStarted(await iterator.next())

        first.release.fire()
        _ = try await first.process.termination.wait()
        let current = await sut.snapshot()
        let end = try #require(await sut.stopBroadcast())
        await sut.stop()

        #expect(current.attemptID == replacement.attemptID)
        #expect(current.attemptSequence == replacement.sequence)
        #expect(cancelled.reason == .cancelled)
        #expect(cancelled.attemptID != replacement.attemptID)
        #expect(replacement.sequence == cancelled.sequence + 1)
        #expect(current.processID == second.process.pid)
        #expect(replacement.processID == second.process.pid)
        #expect(await spawner.liveProcesses == [second.process])
        #expect(end.attemptID == replacement.attemptID)
        let finalEnd = try requireEnded(await iterator.next())
        #expect(finalEnd.attemptID == replacement.attemptID)
        #expect(finalEnd.reason == .stopped)
        #expect(await iterator.next() == nil)
    }

    @Test func lifecycle_MultipleSubscribers_ReceiveSameAttempt() async throws {
        let spy = SpyDelegate()
        let sut = createSUT(delegate: spy)
        let first = await sut.lifecycleEvents()
        let second = await sut.lifecycleEvents()
        try await sut.start()
        let fd = try await joinAsExtensionAndStartBroadcast(sut, delegate: spy)
        defer { close(fd) }

        let end = try #require(await sut.stopBroadcast())
        await sut.stop()

        #expect(await endedAttempts(first) == [end.attemptID])
        #expect(await endedAttempts(second) == [end.attemptID])
    }

    @Test func lifecycle_DisconnectBeforeSpawnCompletes_RetainsReceipt() async throws {
        let spy = SpyDelegate()
        let termination = ProcessTermination()
        let spawner = GatedSpawner(processID: getpid(), termination: termination)
        let sut = createSUT(delegate: spy, spawner: spawner)
        let events = await sut.lifecycleEvents()
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
        let end = try #require(await firstEnd(events))
        let receipt = try #require(end.termination)
        termination.record(23)
        spawner.release()

        #expect(end.reason == .disconnected)
        #expect(end.processID == getpid())
        #expect(try await receipt.wait() == 23)
        await sut.stop()
    }

    @Test func lifecycle_StoppedBroadcast_EmitsOneIdentifiedEnd() async throws {
        let spy = SpyDelegate()
        let sut = createSUT(delegate: spy)
        let events = await sut.lifecycleEvents()
        try await sut.start()
        let fd = try await joinAsExtensionAndStartBroadcast(sut, delegate: spy)
        defer { close(fd) }
        let snapshot = await sut.snapshot()

        await sut.stopBroadcast()
        await sut.stopBroadcast()
        await sut.stop()

        var ends: [BroadcastEnd] = []
        for await event in events {
            if case let .ended(end) = event { ends.append(end) }
        }
        #expect(ends.count == 1)
        let end = try #require(ends.first)
        #expect(end.attemptID == snapshot.attemptID)
        #expect(end.processID == snapshot.processID)
        #expect(end.reason == .stopped)
    }

    @Test func snapshot_RecordingBroadcast_ReturnsCoherentState() async throws {
        let spy = SpyDelegate()
        let sut = createSUT(delegate: spy)
        try await sut.start()
        let fd = try await joinAsExtensionAndStartBroadcast(sut, delegate: spy)
        defer { close(fd) }

        let snapshot = await sut.snapshot()

        #expect(snapshot.lifecycle == .recording)
        #expect(snapshot.attemptID != nil)
        #expect(snapshot.processID != nil)
        #expect(snapshot.micDelivery == .normal)
        await sut.stop()
    }

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

        async let pause: Void = sut.pause()
        let message = try await readWireMessage(from: extFD)
        let requestID = try #require(pauseRequestID(message))
        try sendMessage(.controlAck(requestID: requestID), to: extFD)
        try await pause

        await sut.stop()
    }

    @Test
    func pauseThenResume_whileBroadcastActive_writesPauseThenResumeToExtensionSocket() async throws {
        let spy = SpyDelegate()
        let sut = createSUT(delegate: spy)
        try await sut.start()
        let extFD = try await joinAsExtensionAndStartBroadcast(sut, delegate: spy)
        defer { close(extFD) }

        async let pause: Void = sut.pause()
        let first = try await readWireMessage(from: extFD)
        let pauseID = try #require(pauseRequestID(first))
        try sendMessage(.controlAck(requestID: pauseID), to: extFD)
        try await pause

        async let resume: Void = sut.resume()
        let second = try await readWireMessage(from: extFD)
        let resumeID = try #require(resumeRequestID(second))
        try sendMessage(.controlAck(requestID: resumeID), to: extFD)
        try await resume

        await sut.stop()
    }

    @Test
    func resume_whenBroadcastActiveButNotPaused_throwsNotPaused() async throws {
        let spy = SpyDelegate()
        let sut = createSUT(delegate: spy)
        try await sut.start()
        let extFD = try await joinAsExtensionAndStartBroadcast(sut, delegate: spy)
        defer { close(extFD) }

        await #expect(throws: GeistBroadcastSession.SessionError.notPaused) {
            try await sut.resume()
        }

        await sut.stop()
    }

    @Test
    func pause_calledTwiceWhileActive_throwsAlreadyPaused() async throws {
        let spy = SpyDelegate()
        let sut = createSUT(delegate: spy)
        try await sut.start()
        let extFD = try await joinAsExtensionAndStartBroadcast(sut, delegate: spy)
        defer { close(extFD) }

        async let pause: Void = sut.pause()
        let first = try await readWireMessage(from: extFD)
        let requestID = try #require(pauseRequestID(first))
        try sendMessage(.controlAck(requestID: requestID), to: extFD)
        try await pause
        await #expect(throws: GeistBroadcastSession.SessionError.alreadyPaused) {
            try await sut.pause()
        }

        await sut.stop()
    }

    @Test
    func extensionTerminated_whileBroadcastActive_firesTerminatedDelegateWithError() async throws {
        let spy = SpyDelegate()
        let sut = createSUT(delegate: spy)
        try await sut.start()
        try await sut.setMicDelivery(.withheld)
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
        #expect(await sut.lastBroadcastEndedNormally == false)
        #expect(await sut.micDeliveryMode == .normal)

        await sut.stop()
    }

    @Test
    func broadcastEndedEnvelope_marksBroadcastAsNormallyEnded() async throws {
        let spy = SpyDelegate()
        let sut = createSUT(delegate: spy)
        try await sut.start()
        try await sut.setMicDelivery(.withheld)
        let extFD = try await joinAsExtensionAndStartBroadcast(sut, delegate: spy)
        defer { close(extFD) }

        let broadcast = try #require(spy.starts.first)
        try sendMessage(.broadcastEnded(broadcast), to: extFD)
        await spy.broadcastEndedSignal.wait()

        #expect(await sut.lastBroadcastEndedNormally == true)
        #expect(await sut.micDeliveryMode == .normal)
        #expect(await sut.snapshot().lifecycle == .idle)
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
        try await sut.setMicDelivery(.withheld)
        let extFD = try await joinAsExtensionAndStartBroadcast(sut, delegate: spy)

        close(extFD)
        await spy.broadcastEndedSignal.wait()

        #expect(spy.ends.count == 1)
        #expect(spy.terminations.isEmpty)
        #expect(await sut.activeBroadcasts.isEmpty)
        #expect(await sut.lastBroadcastEndedNormally == false)
        #expect(await sut.micDeliveryMode == .normal)

        await sut.stop()
    }

    @Test
    func extensionFDClosed_beforeBroadcastStarted_firesFailedToStartWithExtensionDiedBeforeStart() async throws {
        let spy = SpyDelegate()
        let spawner = GatedSpawner()
        let sut = createSUT(delegate: spy, spawner: spawner)
        try await sut.start()
        try await sut.setMicDelivery(.withheld)

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
        #expect(await sut.micDeliveryMode == .normal)

        spawner.release()
        await sut.stop()
    }

    @Test
    func extensionProcessID_usesConnectedExtensionPeerBeforeSpawnCompletes() async throws {
        let spy = SpyDelegate()
        let sut = createSUT(delegate: spy)
        try await sut.start()

        let extFD = try connectClient(toSocketOf: sut)
        defer { close(extFD) }
        try sendMessage(.helloExtension(extensionBundleID: "com.test.host.cast"), to: extFD)
        await spy.extensionConnected.wait()

        #expect(await sut.extensionProcessID == getpid())

        await sut.stop()
    }

    @Test
    func extensionTerminated_beforeBroadcastStarted_firesFailedToStartDelegate() async throws {
        let spy = SpyDelegate()
        let spawner = GatedSpawner()
        let sut = createSUT(delegate: spy, spawner: spawner)
        try await sut.start()
        try await sut.setMicDelivery(.withheld)

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
        #expect(await sut.micDeliveryMode == .normal)

        spawner.release()
        await sut.stop()
    }

    private func startWithHost(_ sut: GeistBroadcastSession) async throws -> Int32 {
        try await sut.start()
        let fd = try connectClient(toSocketOf: sut)
        try sendMessage(.helloHost, to: fd)
        _ = try await readWireMessage(from: fd)
        return fd
    }

    private func startAttempt(over hostFD: Int32, spawning pending: PendingSpawn) async throws {
        try sendMessage(.userPressedStart(micEnabled: false), to: hostFD)
        await pending.entered.wait()
    }

    private func cancelAndRearm(over hostFD: Int32, spawning pending: PendingSpawn) async throws {
        try sendMessage(.userCancelledStart, to: hostFD)
        try await startAttempt(over: hostFD, spawning: pending)
    }

    private func requireEnded(_ event: BroadcastLifecycleEvent?) throws -> BroadcastEnd {
        let event = try #require(event)
        guard case let .ended(end) = event else {
            throw TestError.unexpectedEvent(expected: "ended")
        }
        return end
    }

    private func requireProcessStarted(
        _ event: BroadcastLifecycleEvent?
    ) throws -> (attemptID: UUID, processID: Int32, sequence: UInt64) {
        let event = try #require(event)
        guard case let .processStarted(attemptID, processID, sequence) = event else {
            throw TestError.unexpectedEvent(expected: "processStarted")
        }
        return (attemptID, processID, sequence)
    }

    private func collectedEnds(_ events: AsyncStream<BroadcastLifecycleEvent>) async throws -> [BroadcastEnd] {
        var result: [BroadcastEnd] = []
        for await event in events {
            result.append(try requireEnded(event))
        }
        return result
    }

    private func endedAttempts(_ events: AsyncStream<BroadcastLifecycleEvent>) async -> [UUID] {
        var result: [UUID] = []
        for await event in events {
            if case let .ended(end) = event { result.append(end.attemptID) }
        }
        return result
    }

    private func firstEnd(_ events: AsyncStream<BroadcastLifecycleEvent>) async -> BroadcastEnd? {
        for await event in events {
            if case let .ended(end) = event { return end }
        }
        return nil
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

    private func pauseRequestID(_ message: WireMessage) -> String? {
        guard case let .pause(requestID) = message else { return nil }
        return requestID
    }

    private func resumeRequestID(_ message: WireMessage) -> String? {
        guard case let .resume(requestID) = message else { return nil }
        return requestID
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
        case unexpectedEvent(expected: String)
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
    private var _starts: [Broadcast] = []
    let extensionConnected = AsyncSignal()
    let broadcastStartedSignal = AsyncSignal()
    let broadcastEndedSignal = AsyncSignal()
    let terminatedSignal = AsyncSignal()
    let failedToStartSignal = AsyncSignal()

    var terminations: [TerminationCapture] { lock.withLock { _terminations } }
    var failures: [FailureCapture] { lock.withLock { _failures } }
    var ends: [Broadcast] { lock.withLock { _ends } }
    var starts: [Broadcast] { lock.withLock { _starts } }

    func session(_: GeistBroadcastSession, extensionConnectedFor _: String) {
        extensionConnected.fire()
    }

    func session(_: GeistBroadcastSession, broadcastStarted broadcast: Broadcast) {
        lock.withLock { _starts.append(broadcast) }
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
        StagedAppex(
            binaryPath: "\(sourcePath)/staged/Binary",
            rootOwner: StubStagedArtifactOwner()
        )
    }
}

private final class StubSpawner: AppexSpawning {
    func spawn(stagedAppex: StagedAppex,
               simulatorUDID: String,
               simctlSetPath: String?,
               environment: [String: String]) async throws -> SpawnedAppex {
        SpawnedAppex(binaryPath: stagedAppex.binaryPath, generation: UUID(), pid: 1)
    }
    func killStale(stagedBinary: String) async {}
    func terminate(_ process: SpawnedAppex) async {}
}

private final class GatedSpawner: AppexSpawning {
    private let gate = AsyncSignal()
    let spawnEntered = AsyncSignal()
    private let processID: pid_t
    private let termination: ProcessTermination

    init(processID: pid_t = 1, termination: ProcessTermination = ProcessTermination()) {
        self.processID = processID
        self.termination = termination
    }

    func release() { gate.fire() }

    func spawn(stagedAppex: StagedAppex,
               simulatorUDID: String,
               simctlSetPath: String?,
               environment: [String: String]) async throws -> SpawnedAppex {
        spawnEntered.fire()
        await gate.wait()
        return SpawnedAppex(binaryPath: stagedAppex.binaryPath, generation: UUID(), pid: processID, termination: termination)
    }
    func killStale(stagedBinary: String) async {}
    func terminate(_ process: SpawnedAppex) async {}
}

private final class StubStagedArtifactOwner: Sendable {}

private final class PendingSpawn: Sendable {
    let entered = AsyncSignal()
    let release = AsyncSignal()
    let process: SpawnedAppex

    init(processID: Int32) {
        process = SpawnedAppex(binaryPath: "/tmp/fake.appex/staged/Binary", generation: UUID(), pid: processID)
    }
}

private actor FakeProcessSpawner: AppexSpawning {
    private var pending: [PendingSpawn]
    private(set) var liveProcesses: [SpawnedAppex] = []

    init(pending: [PendingSpawn]) {
        self.pending = pending
    }

    func spawn(stagedAppex: StagedAppex, simulatorUDID: String,
               simctlSetPath: String?, environment: [String: String]) async throws -> SpawnedAppex {
        let next = pending.removeFirst()
        next.entered.fire()
        await next.release.wait()
        liveProcesses.append(next.process)
        return next.process
    }

    func killStale(stagedBinary: String) async {}

    func terminate(_ process: SpawnedAppex) async {
        liveProcesses.removeAll { $0 == process }
        process.termination.record(0)
    }
}

private final class GatedFailingSpawner: AppexSpawning {
    let entered = AsyncSignal()
    let release = AsyncSignal()
    let error = NSError(domain: "LaunchFailure", code: 7)

    func spawn(stagedAppex: StagedAppex, simulatorUDID: String,
               simctlSetPath: String?, environment: [String: String]) async throws -> SpawnedAppex {
        entered.fire()
        await release.wait()
        throw error
    }

    func killStale(stagedBinary: String) async {}
    func terminate(_ process: SpawnedAppex) async {}
}

private final class SilentVideoProducer: VideoFrameProducer {
    func start(producing handler: @escaping @Sendable (CVPixelBuffer, CMTime) -> Void) throws {}
    func stop() {}
}
