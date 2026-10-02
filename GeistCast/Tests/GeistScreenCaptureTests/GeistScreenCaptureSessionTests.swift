import AVFoundation
import CoreVideo
import Darwin
import Foundation
@testable import GeistScreenCapture
import GeistScreenCaptureShimCore
import Synchronization
import Testing

struct GeistScreenCaptureSessionTests {
    @Test
    func connection_ScreenRequested_ReturnsSuccessAndStreamsFrame() async throws {
        let screen = ControllableScreenCapture()
        let socketPath = "/tmp/geistsck-test-\(UUID().uuidString).sock"
        let sut = makeSUT(screen: screen, socketPath: socketPath)
        try await sut.start()
        defer { Task { await sut.stop() } }
        let client = try connect(to: socketPath)
        defer { close(client) }

        try writeRequest(outputs: GEIST_SCK_OUTPUT_SCREEN, to: client)

        #expect(try readResponse(from: client) == GEIST_SCK_STATUS_OK)
        let pixelBuffer = try makePixelBuffer()
        screen.emit(pixelBuffer)
        let headerData = try readExactly(FrameHeader.byteCount, from: client)
        let header = try #require(FrameHeader.decode(headerData))
        _ = try readExactly(Int(header.payloadSize), from: client)
        #expect(header.streamType == GEIST_SCK_STREAM_SCREEN)
        #expect(header.width == 2)
        #expect(header.height == 2)
    }

    @Test
    func connection_AppAudioRequested_ReturnsNotSupported() async throws {
        let socketPath = "/tmp/geistsck-test-\(UUID().uuidString).sock"
        let sut = makeSUT(socketPath: socketPath)
        try await sut.start()
        defer { Task { await sut.stop() } }
        let client = try connect(to: socketPath)
        defer { close(client) }

        try writeRequest(outputs: GEIST_SCK_OUTPUT_AUDIO, to: client)

        #expect(try readResponse(from: client) == GEIST_SCK_STATUS_NOT_SUPPORTED)
    }

    @Test
    func connection_AnotherStreamActive_ReturnsBusy() async throws {
        let socketPath = "/tmp/geistsck-test-\(UUID().uuidString).sock"
        let sut = makeSUT(socketPath: socketPath)
        try await sut.start()
        defer { Task { await sut.stop() } }
        let first = try connect(to: socketPath)
        defer { close(first) }
        try writeRequest(outputs: GEIST_SCK_OUTPUT_SCREEN, to: first)
        #expect(try readResponse(from: first) == GEIST_SCK_STATUS_OK)
        let second = try connect(to: socketPath)
        defer { close(second) }

        try writeRequest(outputs: GEIST_SCK_OUTPUT_SCREEN, to: second)

        #expect(try readResponse(from: second) == GEIST_SCK_STATUS_BUSY)
    }

    @Test
    func connection_InvalidMagic_ReturnsInvalidRequest() async throws {
        let socketPath = "/tmp/geistsck-test-\(UUID().uuidString).sock"
        let sut = makeSUT(socketPath: socketPath)
        try await sut.start()
        defer { Task { await sut.stop() } }
        let client = try connect(to: socketPath)
        defer { close(client) }

        try writeRequest(outputs: GEIST_SCK_OUTPUT_SCREEN, magic: 0, to: client)

        #expect(try readResponse(from: client) == GEIST_SCK_STATUS_INVALID_REQUEST)
    }

    @Test
    func connection_MicrophoneRequested_ReturnsSuccessAndStreamsSamples() async throws {
        let microphone = ControllableMicrophoneCapture()
        let socketPath = "/tmp/geistsck-test-\(UUID().uuidString).sock"
        let sut = makeSUT(microphone: microphone, socketPath: socketPath)
        try await sut.start()
        defer { Task { await sut.stop() } }
        let client = try connect(to: socketPath)
        defer { close(client) }

        try writeRequest(outputs: GEIST_SCK_OUTPUT_MICROPHONE, to: client)

        #expect(try readResponse(from: client) == GEIST_SCK_STATUS_OK)
        try microphone.emit(makeAudioBuffer())
        let headerData = try readExactly(FrameHeader.byteCount, from: client)
        let header = try #require(FrameHeader.decode(headerData))
        _ = try readExactly(Int(header.payloadSize), from: client)
        #expect(header.streamType == GEIST_SCK_STREAM_MICROPHONE)
        #expect(header.audioSampleRate == 48000)
        #expect(header.audioSampleCount == 16)
    }

    @Test
    func connection_ClientDisconnects_NextClientCanStartImmediately() async throws {
        let socketPath = "/tmp/geistsck-test-\(UUID().uuidString).sock"
        let sut = makeSUT(socketPath: socketPath)
        try await sut.start()
        defer { Task { await sut.stop() } }
        let first = try connect(to: socketPath)
        try writeRequest(outputs: GEIST_SCK_OUTPUT_SCREEN, to: first)
        #expect(try readResponse(from: first) == GEIST_SCK_STATUS_OK)
        close(first)
        let second = try connect(to: socketPath)
        defer { close(second) }

        try writeRequest(outputs: GEIST_SCK_OUTPUT_SCREEN, to: second)

        #expect(try readResponse(from: second) == GEIST_SCK_STATUS_OK)
    }

    @Test
    func start_RegularFileAtSocketPath_DoesNotDeleteIt() async throws {
        let socketPath = "/tmp/geistsck-test-\(UUID().uuidString).sock"
        let contents = Data("owned".utf8)
        try contents.write(to: URL(fileURLWithPath: socketPath))
        defer { unlink(socketPath) }
        let sut = makeSUT(socketPath: socketPath)

        await #expect(throws: GeistScreenCaptureSession.Error.self) {
            try await sut.start()
        }

        #expect(try Data(contentsOf: URL(fileURLWithPath: socketPath)) == contents)
    }

    @Test
    func start_SocketCreated_RestrictsAccessToCurrentUser() async throws {
        let socketPath = "/tmp/geistsck-test-\(UUID().uuidString).sock"
        let sut = makeSUT(socketPath: socketPath)
        try await sut.start()
        defer { Task { await sut.stop() } }
        var metadata = stat()

        #expect(lstat(socketPath, &metadata) == 0)
        #expect(metadata.st_mode & 0o777 == 0o600)
    }

    private func makeSUT(
        screen: any ScreenFrameCapturing = DummySessionScreenCapture(),
        microphone: any MicrophoneCapturing = DummySessionMicrophoneCapture(),
        socketPath: String
    ) -> GeistScreenCaptureSession {
        let writer = SocketFrameWriter()
        return GeistScreenCaptureSession(
            simulator: UUID(),
            socketPath: socketPath,
            coordinator: CaptureCoordinator(
                screen: screen,
                microphone: microphone,
                writer: writer
            ),
            writer: writer
        )
    }

    private func connect(to path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketTestError.failed }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
            path.utf8CString.withUnsafeBytes { bytes.copyBytes(from: $0) }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            throw SocketTestError.failed
        }
        return fd
    }

    private func writeRequest(
        outputs: UInt32,
        magic: UInt32 = GEIST_SCK_WIRE_MAGIC,
        to fd: Int32
    ) throws {
        var request = geist_sck_start_request_t(
            magic: magic,
            version: GEIST_SCK_WIRE_VERSION,
            outputs: outputs
        )
        let written = withUnsafeBytes(of: &request) { write(fd, $0.baseAddress, $0.count) }
        guard written == MemoryLayout<geist_sck_start_request_t>.size else {
            throw SocketTestError.failed
        }
    }

    private func readResponse(from fd: Int32) throws -> Int32 {
        let data = try readExactly(
            MemoryLayout<geist_sck_start_response_t>.size,
            from: fd
        )
        let response = data.withUnsafeBytes {
            $0.loadUnaligned(as: geist_sck_start_response_t.self)
        }
        guard response.magic == GEIST_SCK_WIRE_MAGIC else { throw SocketTestError.failed }
        return response.status
    }

    private func readExactly(_ count: Int, from fd: Int32) throws -> Data {
        var data = Data(count: count)
        let result = data.withUnsafeMutableBytes { bytes -> Int in
            guard let base = bytes.baseAddress else { return 0 }
            var offset = 0
            while offset < count {
                let readCount = read(fd, base.advanced(by: offset), count - offset)
                guard readCount > 0 else { return -1 }
                offset += readCount
            }
            return offset
        }
        guard result == count else { throw SocketTestError.failed }
        return data
    }

    private func makePixelBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(
            nil,
            2,
            2,
            kCVPixelFormatType_32BGRA,
            nil,
            &buffer
        )
        guard result == kCVReturnSuccess, let buffer else { throw SocketTestError.failed }
        return buffer
    }

    private func makeAudioBuffer() throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16)
        else { throw SocketTestError.failed }
        buffer.frameLength = 16
        return buffer
    }
}

private enum SocketTestError: Swift.Error {
    case failed
}

private final class ControllableScreenCapture: ScreenFrameCapturing {
    // MARK: Properties

    private let handler = Mutex<(@Sendable (CVPixelBuffer) -> Void)?>(nil)

    // MARK: Functions

    func start(delivering handler: @escaping @Sendable (CVPixelBuffer) -> Void) throws {
        self.handler.withLock { $0 = handler }
    }

    func stop() {
        handler.withLock { $0 = nil }
    }

    func emit(_ frame: CVPixelBuffer) {
        handler.withLock { $0 }?(frame)
    }
}

private final class ControllableMicrophoneCapture: MicrophoneCapturing {
    // MARK: Properties

    private let handler = Mutex<(@Sendable (AVAudioPCMBuffer) -> Void)?>(nil)

    // MARK: Functions

    func start(delivering handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        self.handler.withLock { $0 = handler }
    }

    func stop() {
        handler.withLock { $0 = nil }
    }

    func emit(_ buffer: AVAudioPCMBuffer) {
        handler.withLock { $0 }?(buffer)
    }
}

private struct DummySessionScreenCapture: ScreenFrameCapturing {
    func start(delivering _: @escaping @Sendable (CVPixelBuffer) -> Void) throws {}
    func stop() {}
}

private struct DummySessionMicrophoneCapture: MicrophoneCapturing {
    func start(delivering _: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {}
    func stop() {}
}
