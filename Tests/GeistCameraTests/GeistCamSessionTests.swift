import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import GeistCamera

@Suite("GeistCamSession")
struct GeistCamSessionTests {
    @Test func start_afterAttachingMediaSource_sendsHelloToServer() async throws {
        let server = try TestFeederServer.listen()
        defer { server.close() }
        let session = GeistCamSession(socketPath: server.socketPath)
        let source = MediaSourceSpy()
        try await session.attachMediaSource(source, video: .backCamera, audio: nil)

        try await session.start(connectTimeout: 2)

        let hello = await server.firstInbound(matching: .hello, timeout: 2)
        await session.stop()
        #expect(hello != nil)
    }

    @Test func helloAckActivatesSlot_startsMediaSource() async throws {
        let server = try TestFeederServer.listen()
        defer { server.close() }
        let session = GeistCamSession(socketPath: server.socketPath)
        let source = MediaSourceSpy()
        try await session.attachMediaSource(source, video: .backCamera, audio: nil)
        try await session.start(connectTimeout: 2)
        _ = await server.firstInbound(matching: .hello, timeout: 2)

        server.send(.helloAck, payload: makeHelloAckPayload(version: 1, initial: [1, 0, 0]))

        let started = await pollUntil({ source.startCallCount > 0 }, timeout: 2)
        await session.stop()
        #expect(started)
        #expect(source.startCallCount == 1)
    }

    @Test func activeFormat_invokesReformatOnMediaSource() async throws {
        let server = try TestFeederServer.listen()
        defer { server.close() }
        let session = GeistCamSession(socketPath: server.socketPath)
        let source = MediaSourceSpy()
        try await session.attachMediaSource(source, video: .backCamera, audio: nil)
        try await session.start(connectTimeout: 2)
        _ = await server.firstInbound(matching: .hello, timeout: 2)
        server.send(.helloAck, payload: makeHelloAckPayload(version: 1, initial: [1, 0, 0]))
        _ = await pollUntil({ source.startCallCount > 0 }, timeout: 2)

        server.send(.activeFormat, payload: makeActiveFormatPayload(slot: 0, width: 1920, height: 1080,
                                                                     pixelFormat: 0x34323066))

        let reformatted = await pollUntil({ source.reformatCallCount > 0 }, timeout: 2)
        await session.stop()
        #expect(reformatted)
        #expect(source.lastReformatTarget?.width == 1920)
        #expect(source.lastReformatTarget?.height == 1080)
    }

    @Test func recordingStateActive_makesAttachThrowRecordingInProgress() async throws {
        let server = try TestFeederServer.listen()
        defer { server.close() }
        let session = GeistCamSession(socketPath: server.socketPath)
        let firstSource = MediaSourceSpy()
        try await session.attachMediaSource(firstSource, video: .backCamera, audio: nil)
        try await session.start(connectTimeout: 2)
        _ = await server.firstInbound(matching: .hello, timeout: 2)
        server.send(.helloAck, payload: makeHelloAckPayload(version: 1, initial: [0, 0, 0]))

        server.send(.recordingState, payload: makeRecordingStatePayload(active: 1))
        try? await Task.sleep(for: .milliseconds(150))

        let replacement = MediaSourceSpy()
        await #expect(throws: SourceSwitchError.recordingInProgress) {
            try await session.attachMediaSource(replacement, video: .backCamera, audio: nil)
        }
        await session.stop()
    }

    @Test func slotActiveOff_afterRunning_stopsMediaSource() async throws {
        let server = try TestFeederServer.listen()
        defer { server.close() }
        let session = GeistCamSession(socketPath: server.socketPath)
        let source = MediaSourceSpy()
        try await session.attachMediaSource(source, video: .backCamera, audio: nil)
        try await session.start(connectTimeout: 2)
        _ = await server.firstInbound(matching: .hello, timeout: 2)
        server.send(.helloAck, payload: makeHelloAckPayload(version: 1, initial: [1, 0, 0]))
        _ = await pollUntil({ source.startCallCount > 0 }, timeout: 2)

        server.send(.slotActive, payload: makeSlotActivePayload(slot: 0, active: 0))

        let stopped = await pollUntil({ source.stopCallCount > 0 }, timeout: 2)
        await session.stop()
        #expect(stopped)
    }
}

// MARK: - Helpers

private func pollUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

private func makeHelloAckPayload(version: UInt32, initial: [UInt32]) -> Data {
    var d = Data()
    d.appendLE(version)
    for v in initial { d.appendLE(v) }
    return d
}

private func makeSlotActivePayload(slot: UInt32, active: UInt32) -> Data {
    var d = Data()
    d.appendLE(slot)
    d.appendLE(active)
    return d
}

private func makeRecordingStatePayload(active: UInt32) -> Data {
    var d = Data()
    d.appendLE(active)
    return d
}

private func makeActiveFormatPayload(slot: UInt32, width: UInt32, height: UInt32, pixelFormat: UInt32) -> Data {
    var d = Data()
    d.appendLE(slot)
    d.appendLE(width)
    d.appendLE(height)
    d.appendLE(pixelFormat)
    return d
}

// MARK: - Test Doubles

private final class MediaSourceSpy: MediaSource, @unchecked Sendable {
    let hasVideo = true
    let hasAudio = false
    let declaredVideoFormat: VideoSlotFormat? = VideoSlotFormat(
        width: 320, height: 240, pixelFormat: .yuv420FullRange, fps: 30
    )
    let declaredAudioFormat: AudioSlotFormat? = nil

    private let lock = NSLock()
    private var _startCount = 0
    private var _stopCount = 0
    private var _reformatCount = 0
    private var _lastReformat: VideoSlotFormat?

    var startCallCount: Int { lock.lock(); defer { lock.unlock() }; return _startCount }
    var stopCallCount: Int { lock.lock(); defer { lock.unlock() }; return _stopCount }
    var reformatCallCount: Int { lock.lock(); defer { lock.unlock() }; return _reformatCount }
    var lastReformatTarget: VideoSlotFormat? { lock.lock(); defer { lock.unlock() }; return _lastReformat }

    func start(into sink: any MediaSink) throws {
        lock.lock(); defer { lock.unlock() }
        _startCount += 1
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        _stopCount += 1
    }

    func reformat(to target: VideoSlotFormat) {
        lock.lock(); defer { lock.unlock() }
        _reformatCount += 1
        _lastReformat = target
    }
}
