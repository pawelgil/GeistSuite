import Darwin
import Foundation
import Testing
@testable import GeistCamera

@Suite("Socket client delivery")
struct SocketClientDeliveryTests {
    @Test func SocketClient_MixedBacklog_PreservesReliableFramesAndLatestVideoInWireOrder() async throws {
        let server = try TestFeederServer.listen()
        let writer = GatedFrameWriter()
        let client = SocketClient(path: server.socketPath, frameWriter: writer)
        defer {
            writer.release()
            client.close()
            server.close()
        }
        try await client.connect(timeout: 2)
        await server.waitForConnection(timeout: 2)

        let blocker = FrameFixture(type: .hello, payload: Data([0xB0]))
        _ = client.send(blocker.outbound)
        let writerEntered = await writer.waitUntilEntered(timeout: .seconds(2))
        try #require(writerEntered, "socket writer did not reach the gate")

        let audio1 = audioFrame(marker: 1)
        let oldVideo0 = videoFrame(slot: 0, marker: 1)
        let latestVideo0 = videoFrame(slot: 0, marker: 2)
        let audio2 = audioFrame(marker: 2)
        let video1 = videoFrame(slot: 1, marker: 3)
        let audio3 = audioFrame(marker: 3)
        let barrier = FrameFixture(
            type: .metadataResults,
            payload: WireMetadataResults(slot: 0, objects: []).encoded()
        )
        let backlog = [oldVideo0, audio1, latestVideo0, audio2, video1, audio3, barrier]
        for frame in backlog {
            _ = client.send(frame.outbound)
        }

        writer.release()
        let received = await receiveThroughBarrier(server.inbound, barrier: barrier, timeout: .seconds(2))
        try #require(!writer.didExpire, "socket writer gate expired before explicit release")
        let messages = try #require(received, "socket writer did not drain through the barrier")
        let expected = [blocker, audio1, latestVideo0, audio2, video1, audio3, barrier]

        #expect(messages.map(\.observation) == expected.map(\.observation))
    }

    @Test func SocketClient_ReliableFrameExceedsCapacity_RejectsAndClosesWhileWriteIsActive() async throws {
        let server = try TestFeederServer.listen()
        let writer = GatedFrameWriter()
        let client = SocketClient(path: server.socketPath, frameWriter: writer)
        defer {
            writer.release()
            client.close()
            server.close()
        }
        try await client.connect(timeout: 2)
        await server.waitForConnection(timeout: 2)
        #expect(client.send(.reliable(type: .hello, payload: Data())) == .accepted)
        try #require(await writer.waitUntilEntered(timeout: .seconds(2)))

        let oversized = Data(count: OutboundFrameBuffer.defaultByteLimit)
        let rejection = client.send(.reliable(type: .metadataResults, payload: oversized))

        #expect(rejection == .rejected(.capacity))
        #expect(client.send(.reliable(type: .hello, payload: Data())) == .rejected(.unavailable))
        #expect(await server.waitForClientClose())
    }

    @Test func SocketClient_AggregateReliableBacklogExceedsCapacity_RejectsAndCloses() async throws {
        let server = try TestFeederServer.listen()
        let writer = GatedFrameWriter()
        let client = SocketClient(path: server.socketPath, frameWriter: writer)
        defer {
            writer.release()
            client.close()
            server.close()
        }
        try await client.connect(timeout: 2)
        await server.waitForConnection(timeout: 2)
        #expect(client.send(.reliable(type: .hello, payload: Data())) == .accepted)
        try #require(await writer.waitUntilEntered(timeout: .seconds(2)))
        let payload = Data(count: OutboundFrameBuffer.defaultByteLimit / 2)

        #expect(client.send(.audio(slot: 2, payload: payload)) == .accepted)
        let rejection = client.send(.reliable(type: .metadataResults, payload: payload))

        #expect(rejection == .rejected(.capacity))
        #expect(await server.waitForClientClose())
    }

    @Test func SocketClient_VideoFrameExceedsCapacity_DropsVideoAndKeepsConnectionUsable() async throws {
        let server = try TestFeederServer.listen()
        let client = SocketClient(path: server.socketPath)
        defer {
            client.close()
            server.close()
        }
        try await client.connect(timeout: 2)
        await server.waitForConnection(timeout: 2)
        let oversized = Data(count: OutboundFrameBuffer.defaultByteLimit)

        let admission = client.send(.video(slot: 0, payload: oversized))
        let barrier = WireMetadataResults(slot: 0, objects: []).encoded()
        #expect(client.send(.reliable(type: .metadataResults, payload: barrier)) == .accepted)

        #expect(admission == .droppedVideo)
        #expect(await server.firstInbound(matching: .metadataResults, timeout: 2) != nil)
    }

    @Test func SocketClient_WriteFailsAfterAdmission_ClosesAndRejectsLaterFrames() async throws {
        let server = try TestFeederServer.listen()
        let writer = FrameWriterFailureStub()
        let client = SocketClient(path: server.socketPath, frameWriter: writer)
        defer {
            client.close()
            server.close()
        }
        try await client.connect(timeout: 2)
        await server.waitForConnection(timeout: 2)

        let admission = client.send(.reliable(type: .hello, payload: Data()))

        #expect(admission == .accepted)
        #expect(await server.waitForClientClose())
        #expect(client.send(.reliable(type: .hello, payload: Data())) == .rejected(.unavailable))
    }

    @Test func SocketClient_CloseWhileWriteBlocked_RejectsLaterFramesWithoutAffectingAnotherClient() async throws {
        let server1 = try TestFeederServer.listen()
        let server2 = try TestFeederServer.listen()
        let writer = GatedFrameWriter()
        let client1 = SocketClient(path: server1.socketPath, frameWriter: writer)
        let client2 = SocketClient(path: server2.socketPath)
        defer {
            writer.release()
            client1.close()
            client2.close()
            server1.close()
            server2.close()
        }
        try await client1.connect(timeout: 2)
        try await client2.connect(timeout: 2)
        #expect(client1.send(.reliable(type: .hello, payload: Data())) == .accepted)
        try #require(await writer.waitUntilEntered(timeout: .seconds(2)))

        client1.close()
        let client1Admission = client1.send(.reliable(type: .hello, payload: Data()))
        let barrier = WireMetadataResults(slot: 0, objects: []).encoded()
        let client2Admission = client2.send(.reliable(type: .metadataResults, payload: barrier))

        #expect(client1Admission == .rejected(.unavailable))
        #expect(client2Admission == .accepted)
        #expect(await server1.waitForClientClose())
        #expect(await server2.firstInbound(matching: .metadataResults, timeout: 2) != nil)
    }

    @Test func SocketClient_DrainEmptiesAndRefills_DeliversEveryBarrier() async throws {
        let server = try TestFeederServer.listen()
        let client = SocketClient(path: server.socketPath)
        defer {
            client.close()
            server.close()
        }
        try await client.connect(timeout: 2)

        for marker in 0 ..< UInt32(20) {
            let barrier = FrameFixture(
                type: .metadataResults,
                payload: WireMetadataResults(slot: marker, objects: []).encoded()
            )
            #expect(client.send(barrier.outbound) == .accepted)
            let received = await receiveThroughBarrier(server.inbound, barrier: barrier, timeout: .seconds(2))
            try #require(received != nil)
        }
    }

    @Test func SocketClient_DeallocatedWhileWriteBlocked_ReleasesClientBeforeGate() async throws {
        let server = try TestFeederServer.listen()
        let writer = GatedFrameWriter()
        defer {
            writer.release()
            server.close()
        }
        weak var releasedClient: SocketClient?

        do {
            let client = SocketClient(path: server.socketPath, frameWriter: writer)
            try await client.connect(timeout: 2)
            #expect(client.send(.reliable(type: .hello, payload: Data())) == .accepted)
            try #require(await writer.waitUntilEntered(timeout: .seconds(2)))
            releasedClient = client
        }

        #expect(releasedClient == nil)
        #expect(await server.waitForClientClose())
    }

    private func audioFrame(marker: Int64) -> FrameFixture {
        let header = WireAudioFrameHeader(
            slot: 2,
            sampleCount: 1,
            sampleRate: 48_000,
            channels: 1,
            format: 0x6C70_636D,
            bitsPerChannel: 32,
            ptsNs: marker,
            bytesLen: 4
        )
        var payload = header.encoded()
        payload.appendLE(Float(marker).bitPattern)
        return FrameFixture(type: .audioFrame, payload: payload)
    }

    private func videoFrame(slot: UInt32, marker: Int64) -> FrameFixture {
        let header = WireVideoFrameHeader(
            slot: slot,
            width: 1,
            height: 1,
            pixelFormat: 0x4247_5241,
            ptsNs: marker,
            durationNs: 1,
            bytesLen: 4
        )
        var payload = header.encoded()
        payload.appendLE(UInt32(truncatingIfNeeded: marker))
        return FrameFixture(type: .videoFrame, payload: payload)
    }

    private func receiveThroughBarrier(
        _ stream: AsyncStream<TestFeederServer.InboundMessage>,
        barrier: FrameFixture,
        timeout: Duration
    ) async -> [TestFeederServer.InboundMessage]? {
        await withTaskGroup(of: [TestFeederServer.InboundMessage]?.self) { group in
            group.addTask {
                var messages: [TestFeederServer.InboundMessage] = []
                for await message in stream {
                    messages.append(message)
                    if message.observation == barrier.observation {
                        return messages
                    }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let messages = await group.next() ?? nil
            group.cancelAll()
            return messages
        }
    }
}

private struct FrameFixture: Sendable {
    let type: WireMessageType
    let payload: Data

    var outbound: OutboundFrame {
        switch type {
        case .audioFrame:
            .audio(slot: payload.readLE(at: 0), payload: payload)
        case .videoFrame:
            .video(slot: payload.readLE(at: 0), payload: payload)
        default:
            .reliable(type: type, payload: payload)
        }
    }

    var observation: FrameObservation {
        FrameObservation(type: type.rawValue, payload: payload)
    }
}

private struct FrameObservation: Equatable, Sendable {
    let type: UInt32
    let payload: Data
}

private extension TestFeederServer.InboundMessage {
    var observation: FrameObservation {
        FrameObservation(type: type.rawValue, payload: payload)
    }
}

// NSCondition guards every mutable field accessed across the writer and test tasks.
private final class GatedFrameWriter: SocketClient.FrameWriting, @unchecked Sendable {
    private let condition = NSCondition()
    private let entered: AsyncStream<Void>
    private let enteredContinuation: AsyncStream<Void>.Continuation
    private var expired = false
    private var gatesNextWrite = true
    private var isReleased = false

    var didExpire: Bool {
        condition.lock()
        defer { condition.unlock() }
        return expired
    }

    init() {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        self.entered = stream
        self.enteredContinuation = continuation
    }

    func writeFrame(fd: Int32, frame: Data) -> Bool {
        condition.lock()
        let shouldGate = gatesNextWrite
        gatesNextWrite = false
        condition.unlock()

        if shouldGate {
            enteredContinuation.yield()
            enteredContinuation.finish()
            guard waitForRelease() else { return false }
        }
        return writeAll(fd: fd, frame: frame)
    }

    func waitUntilEntered(timeout: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { [entered] in
                for await _ in entered {
                    return true
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let didEnter = await group.next() ?? false
            group.cancelAll()
            return didEnter
        }
    }

    func release() {
        condition.lock()
        isReleased = true
        condition.broadcast()
        condition.unlock()
    }

    private func waitForRelease() -> Bool {
        let deadline = Date().addingTimeInterval(5)
        condition.lock()
        defer { condition.unlock() }
        while !isReleased {
            guard condition.wait(until: deadline) else {
                expired = true
                return false
            }
        }
        return true
    }

    private func writeAll(fd: Int32, frame: Data) -> Bool {
        frame.withUnsafeBytes { rawPointer -> Bool in
            guard let baseAddress = rawPointer.baseAddress else { return true }
            var sent = 0
            while sent < frame.count {
                let written = Darwin.send(fd, baseAddress.advanced(by: sent), frame.count - sent, 0)
                if written <= 0 {
                    if written < 0, errno == EINTR { continue }
                    return false
                }
                sent += written
            }
            return true
        }
    }
}

private struct FrameWriterFailureStub: SocketClient.FrameWriting {
    func writeFrame(fd _: Int32, frame _: Data) -> Bool {
        return false
    }
}
