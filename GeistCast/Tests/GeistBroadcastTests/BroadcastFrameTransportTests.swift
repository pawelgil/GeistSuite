import AVFoundation
import CoreVideo
import Darwin
import Foundation
@testable import GeistBroadcast
import Testing

struct BroadcastFrameTransportTests {
    @Test func `sink video queue full drops newest frame`() async throws {
        let sut = createSUT()
        defer { sut.stop() }
        let firstVideo = try makeVideo(fill: 17)
        let nextVideo = try makeVideo(fill: 51)
        sut.sink.sendVideo(firstVideo)
        try sut.sink.sendVideo(makeVideo(fill: 34))
        try sut.start(onFatalFailure: {})
        let client = try connect(to: sut.path)
        defer { close(client) }

        let frame = try await readFrame(from: client)
        sut.sink.sendVideo(nextVideo)
        let next = try await readFrame(from: client)

        expectVideo(frame, matching: firstVideo, fill: 17)
        expectVideo(next, matching: nextVideo, fill: 51)
    }

    @Test func `sink audio queue full preserves first sixteen frames`() async throws {
        let sut = createSUT()
        defer { sut.stop() }
        try enqueueAudio(0 ... 16, into: sut)
        try sut.start(onFatalFailure: {})
        let client = try connect(to: sut.path)
        defer { close(client) }

        let samples = try await readAudioSamples(count: 16, from: client)
        try sut.sink.sendMicAudio(makeAudio(sample: 99))
        let next = try await readAudioSamples(count: 1, from: client)

        #expect(samples == Array(0 ... 15))
        #expect(next == [99])
    }

    @Test func `connection replaced closes previous before delivering to replacement`() async throws {
        let sut = createSUT()
        defer { sut.stop() }
        try sut.start(onFatalFailure: {})
        let original = try connect(to: sut.path)
        defer { close(original) }
        try sut.sink.sendVideo(makeVideo(fill: 17))
        _ = try await readFrame(from: original)

        let replacement = try connect(to: sut.path)
        defer { close(replacement) }
        await #expect(throws: SocketReadError.closed) { try await readBytes(from: original, count: 1) }
        let video = try makeVideo(fill: 34)
        sut.sink.sendVideo(video)
        let frame = try await readFrame(from: replacement)

        expectVideo(frame, matching: video, fill: 34)
    }

    @Test func `connection replaced twice only latest receives frames`() async throws {
        let sut = createSUT()
        defer { sut.stop() }
        try sut.start(onFatalFailure: {})
        let original = try connect(to: sut.path)
        defer { close(original) }
        let intermediate = try connect(to: sut.path)
        defer { close(intermediate) }
        let latest = try connect(to: sut.path)
        defer { close(latest) }

        await #expect(throws: SocketReadError.closed) { try await readBytes(from: original, count: 1) }
        await #expect(throws: SocketReadError.closed) { try await readBytes(from: intermediate, count: 1) }
        let video = try makeVideo(fill: 51)
        sut.sink.sendVideo(video)
        let frame = try await readFrame(from: latest)

        expectVideo(frame, matching: video, fill: 51)
    }

    @Test func `stop connected client closes connection and unlinks path`() async throws {
        let sut = createSUT()
        defer { sut.stop() }
        try sut.start(onFatalFailure: {})
        let client = try connect(to: sut.path)
        defer { close(client) }
        try sut.sink.sendVideo(makeVideo(fill: 17))
        _ = try await readFrame(from: client)

        sut.stop()
        sut.stop()

        await #expect(throws: SocketReadError.closed) { try await readBytes(from: client, count: 1) }
        #expect(!FileManager.default.fileExists(atPath: sut.path))
        #expect(throws: BroadcastFrameTransport.Error.alreadyStarted) { try sut.start(onFatalFailure: {}) }
    }

    @Test func `stop blocked frame write unblocks without waiting for client read`() async throws {
        let sut = createSUT()
        defer { sut.stop() }
        try sut.start(onFatalFailure: {})
        let client = try connect(to: sut.path)
        defer { close(client) }
        try sut.sink.sendVideo(makeVideo(fill: 17, width: 2048, height: 2048))
        _ = try await readBytes(from: client, count: FrameHeader.byteCount)

        try await stopBeforeDeadline(sut)

        #expect(!FileManager.default.fileExists(atPath: sut.path))
    }

    @Test func `start bind fails can retry after directory created`() async throws {
        let directory = "/tmp/gc-frame-\(UUID().uuidString)"
        let sut = BroadcastFrameTransport(path: "\(directory)/frames.sock")
        defer {
            sut.stop()
            try? FileManager.default.removeItem(atPath: directory)
        }
        #expect(throws: UnixSocketListener.Error.bind(errno: ENOENT)) { try sut.start(onFatalFailure: {}) }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)

        try sut.start(onFatalFailure: {})
        let client = try connect(to: sut.path)
        defer { close(client) }
        let video = try makeVideo(fill: 17)
        sut.sink.sendVideo(video)
        let frame = try await readFrame(from: client)

        expectVideo(frame, matching: video, fill: 17)
    }

    @Test(arguments: 0 ..< 20)
    func `deinit connected client closes connection without retained worker`(repetition _: Int) async throws {
        var sut: BroadcastFrameTransport? = createSUT()
        let path = try #require(sut?.path)
        try sut?.start(onFatalFailure: {})
        let client = try connect(to: path)
        defer { close(client) }
        try sut?.sink.sendVideo(makeVideo(fill: 17))
        _ = try await readFrame(from: client)

        sut = nil

        await #expect(throws: SocketReadError.closed) { try await readBytes(from: client, count: 1) }
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    private func createSUT() -> BroadcastFrameTransport {
        BroadcastFrameTransport(path: "/tmp/gc-frame-\(UUID().uuidString).sock")
    }

    private func connect(to path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketReadError.errno(errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                strlcpy($0, path, capacity)
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let error = errno
            close(fd)
            throw SocketReadError.errno(error)
        }
        return fd
    }

    private func readFrame(from fd: Int32) async throws -> (header: FrameHeader, payload: Data) {
        let bytes = try await readBytes(from: fd, count: FrameHeader.byteCount)
        let header = try #require(FrameHeader.decoded(from: bytes))
        let payload = try await readBytes(from: fd, count: Int(header.payloadSize))
        return (header, payload)
    }

    private func expectVideo(
        _ frame: (header: FrameHeader, payload: Data), matching video: CVPixelBuffer, fill: UInt8,
    ) {
        let bytesPerRow = CVPixelBufferGetBytesPerRow(video)
        let height = CVPixelBufferGetHeight(video)
        let expectedPayload = Data(repeating: fill, count: bytesPerRow * height)
        let expectedHeader = FrameHeader.video(
            pixelFormatFourCC: CVPixelBufferGetPixelFormatType(video),
            width: UInt32(CVPixelBufferGetWidth(video)), height: UInt32(height),
            bytesPerRowPlane0: UInt32(bytesPerRow), bytesPerRowPlane1: 0,
            payloadSize: UInt32(expectedPayload.count),
        )

        #expect(frame.header == expectedHeader)
        #expect(frame.payload == expectedPayload)
    }

    private func makeVideo(fill: UInt8, width: Int = 4, height: Int = 2) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                         [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        try #require(status == kCVReturnSuccess)
        let result = try #require(buffer)
        CVPixelBufferLockBaseAddress(result, [])
        defer { CVPixelBufferUnlockBaseAddress(result, []) }
        let base = try #require(CVPixelBufferGetBaseAddress(result))
        memset(base, Int32(fill), CVPixelBufferGetBytesPerRow(result) * height)
        return result
    }

    private func makeAudio(sample: Int16) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000,
                                                channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        buffer.frameLength = 1
        let channels = try #require(buffer.int16ChannelData)
        channels[0][0] = sample
        return buffer
    }

    private func enqueueAudio(_ samples: ClosedRange<Int16>, into sut: BroadcastFrameTransport) throws {
        for sample in samples {
            try sut.sink.sendMicAudio(makeAudio(sample: sample))
        }
    }

    private func readAudioSamples(count: Int, from fd: Int32) async throws -> [Int16] {
        var samples: [Int16] = []
        for _ in 0 ..< count {
            let frame = try await readFrame(from: fd)
            try #require(frame.header.streamType == StreamType.audioMic.rawValue)
            try #require(frame.payload.count == MemoryLayout<Int16>.size)
            samples.append(frame.payload.withUnsafeBytes { $0.loadUnaligned(as: Int16.self) })
        }
        return samples
    }

    private func stopBeforeDeadline(_ sut: BroadcastFrameTransport) async throws {
        let completion = AsyncStream<Void>.makeStream()
        DispatchQueue.global().async {
            sut.stop()
            completion.continuation.yield(())
            completion.continuation.finish()
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            defer { group.cancelAll() }
            group.addTask {
                var iterator = completion.stream.makeAsyncIterator()
                _ = await iterator.next()
                try Task.checkCancellation()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw SocketReadError.timeout
            }
            _ = try await group.next()
        }
    }
}
