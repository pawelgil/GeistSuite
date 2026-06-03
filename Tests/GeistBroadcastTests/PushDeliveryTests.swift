import AVFoundation
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import Synchronization
import Testing
@testable import GeistBroadcast

@Suite(.serialized) struct PushDeliveryTests {

    @Test
    func userPressedStart_withCustomVideoProducer_writesVideoFrameToFrameSocket() async throws {
        let buffer = try makeBGRAPixelBuffer(width: 4, height: 2, fill: 0x11)
        let producer = OneShotVideoFrameProducer(buffer: buffer)
        let extensionConnected = AsyncSignal()
        let delegate = SignalingDelegate(extensionConnected: extensionConnected)
        let sut = createSUT(
            videoCapture: .custom(producer),
            micAudio: .disabled,
            delegate: delegate
        )
        try await sut.start()
        let frameFD = try connectFrameClient(toSocketOf: sut)
        defer { close(frameFD) }
        let hostFD = try connectClient(toSocketOf: sut)
        defer { close(hostFD) }
        let extFD = try connectClient(toSocketOf: sut)
        defer { close(extFD) }

        try await driveUserPressedStart(
            sut: sut,
            hostFD: hostFD,
            extFD: extFD,
            extensionConnected: extensionConnected,
            micEnabled: false
        )

        let header = try await readFrameHeader(from: frameFD)
        let payload = try await readBytes(from: frameFD, count: Int(header.payloadSize))

        #expect(header.streamType == StreamType.video.rawValue)
        #expect(header.pixelFormatFourCC == FrameHeader.bgra32)
        #expect(header.width == 4)
        #expect(header.height == 2)
        #expect(payload.count == Int(header.bytesPerRowPlane0) * Int(header.height))

        await sut.stop()
    }

    @Test
    func userPressedStart_withCustomMicProducer_writesMicAudioFrameToFrameSocket() async throws {
        let buffer = makePCMBuffer(sampleRate: 44100, channels: 1, frameCount: 1024)
        let producer = OneShotMicAudioProducer(buffer: buffer)
        let extensionConnected = AsyncSignal()
        let delegate = SignalingDelegate(extensionConnected: extensionConnected)
        let sut = createSUT(
            videoCapture: .custom(SilentVideoProducer()),
            micAudio: .custom(producer),
            delegate: delegate
        )
        try await sut.start()
        let frameFD = try connectFrameClient(toSocketOf: sut)
        defer { close(frameFD) }
        let hostFD = try connectClient(toSocketOf: sut)
        defer { close(hostFD) }
        let extFD = try connectClient(toSocketOf: sut)
        defer { close(extFD) }

        try await driveUserPressedStart(
            sut: sut,
            hostFD: hostFD,
            extFD: extFD,
            extensionConnected: extensionConnected,
            micEnabled: true
        )

        let header = try await readFrameHeader(from: frameFD)
        _ = try await readBytes(from: frameFD, count: Int(header.payloadSize))

        #expect(header.streamType == StreamType.audioMic.rawValue)
        #expect(header.audioSampleRate == 44100)
        #expect(header.audioChannelCount == 1)
        #expect(header.audioSampleCount == 1024)

        await sut.stop()
    }

    @Test
    func userToggledMic_whileBroadcastingWithoutMic_attachesMicSourceAndDeliversFrame() async throws {
        let buffer = makePCMBuffer(sampleRate: 44100, channels: 1, frameCount: 1024)
        let producer = OneShotMicAudioProducer(buffer: buffer)
        let extensionConnected = AsyncSignal()
        let delegate = SignalingDelegate(extensionConnected: extensionConnected)
        let sut = createSUT(
            videoCapture: .custom(SilentVideoProducer()),
            micAudio: .custom(producer),
            delegate: delegate
        )
        try await sut.start()
        let frameFD = try connectFrameClient(toSocketOf: sut)
        defer { close(frameFD) }
        let hostFD = try connectClient(toSocketOf: sut)
        defer { close(hostFD) }
        let extFD = try connectClient(toSocketOf: sut)
        defer { close(extFD) }

        try await driveUserPressedStart(
            sut: sut,
            hostFD: hostFD,
            extFD: extFD,
            extensionConnected: extensionConnected,
            micEnabled: false
        )

        try sendMessage(.userToggledMic(enabled: true), to: hostFD)

        let header = try await readFrameHeader(from: frameFD)
        _ = try await readBytes(from: frameFD, count: Int(header.payloadSize))
        #expect(header.streamType == StreamType.audioMic.rawValue)

        await sut.stop()
    }

    @Test
    func helloHost_whileBroadcastActiveWithMicAttached_repliesStateWithMicEnabledTrue() async throws {
        let extensionConnected = AsyncSignal()
        let broadcastStarted = AsyncSignal()
        let delegate = SignalingDelegate(
            extensionConnected: extensionConnected,
            broadcastStarted: broadcastStarted
        )
        let sut = createSUT(
            videoCapture: .custom(SilentVideoProducer()),
            micAudio: .custom(OneShotMicAudioProducer(
                buffer: makePCMBuffer(sampleRate: 44100, channels: 1, frameCount: 1024)
            )),
            delegate: delegate
        )
        try await sut.start()
        let hostFD = try connectClient(toSocketOf: sut)
        defer { close(hostFD) }
        let extFD = try connectClient(toSocketOf: sut)
        defer { close(extFD) }

        try await driveUserPressedStart(
            sut: sut,
            hostFD: hostFD,
            extFD: extFD,
            extensionConnected: extensionConnected,
            micEnabled: true
        )
        let broadcast = Broadcast(
            simulatorUDID: sut.simulator,
            hostAppBundleID: sut.hostBundleID,
            extensionBundleID: "com.test.host.cast",
            startedAt: ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")!
        )
        try sendMessage(.broadcastStarted(broadcast), to: extFD)
        await broadcastStarted.wait()

        let freshHostFD = try connectClient(toSocketOf: sut)
        defer { close(freshHostFD) }
        try sendMessage(.helloHost, to: freshHostFD)
        let reply = try await readWireMessage(from: freshHostFD)

        if case .state(let recording, let replyBroadcast, let micEnabled, _) = reply {
            #expect(recording == true)
            #expect(replyBroadcast == broadcast)
            #expect(micEnabled == true)
        } else {
            Issue.record("expected state reply, got \(reply)")
        }

        await sut.stop()
    }

    @Test
    func helloHost_whileBroadcastActiveWithoutMic_repliesStateWithMicEnabledFalse() async throws {
        let extensionConnected = AsyncSignal()
        let broadcastStarted = AsyncSignal()
        let delegate = SignalingDelegate(
            extensionConnected: extensionConnected,
            broadcastStarted: broadcastStarted
        )
        let sut = createSUT(
            videoCapture: .custom(SilentVideoProducer()),
            micAudio: .disabled,
            delegate: delegate
        )
        try await sut.start()
        let hostFD = try connectClient(toSocketOf: sut)
        defer { close(hostFD) }
        let extFD = try connectClient(toSocketOf: sut)
        defer { close(extFD) }

        try await driveUserPressedStart(
            sut: sut,
            hostFD: hostFD,
            extFD: extFD,
            extensionConnected: extensionConnected,
            micEnabled: false
        )
        let broadcast = Broadcast(
            simulatorUDID: sut.simulator,
            hostAppBundleID: sut.hostBundleID,
            extensionBundleID: "com.test.host.cast",
            startedAt: ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")!
        )
        try sendMessage(.broadcastStarted(broadcast), to: extFD)
        await broadcastStarted.wait()

        let freshHostFD = try connectClient(toSocketOf: sut)
        defer { close(freshHostFD) }
        try sendMessage(.helloHost, to: freshHostFD)
        let reply = try await readWireMessage(from: freshHostFD)

        if case .state(let recording, let replyBroadcast, let micEnabled, _) = reply {
            #expect(recording == true)
            #expect(replyBroadcast == broadcast)
            #expect(micEnabled == false)
        } else {
            Issue.record("expected state reply, got \(reply)")
        }

        await sut.stop()
    }

    @Test
    func simulateMicAudioInterruption_withConnectedExtension_writesMessageToControlSocket() async throws {
        let extensionConnected = AsyncSignal()
        let delegate = SignalingDelegate(extensionConnected: extensionConnected)
        let sut = createSUT(delegate: delegate)
        try await sut.start()
        let extFD = try connectClient(toSocketOf: sut)
        defer { close(extFD) }
        try sendMessage(.helloExtension(extensionBundleID: "com.test.host.cast"), to: extFD)
        await extensionConnected.wait()

        try await sut.simulateMicAudioInterruption(true)

        let message = try await readWireMessage(from: extFD)
        #expect(message == .setMicAudioReadiness(ready: false))

        await sut.stop()
    }

    @Test
    func simulateMicAudioInterruption_whenExtensionNotConnected_throwsNotConnected() async throws {
        let sut = createSUT()
        try await sut.start()

        await #expect(throws: GeistBroadcastSession.SessionError.notConnected) {
            try await sut.simulateMicAudioInterruption(true)
        }

        await sut.stop()
    }

    // MARK: helpers

    private func createSUT(
        simulator: String = "SIM-\(UUID().uuidString.prefix(8))",
        hostBundleID: String = "com.test.host",
        extension extensionContext: ExtensionContext = ExtensionContext(
            bundleID: "com.test.host.cast",
            appexPath: "/tmp/fake.appex"
        ),
        videoCapture: VideoCaptureConfig = .custom(SilentVideoProducer()),
        micAudio: MicAudioConfig = .disabled,
        delegate: (any GeistBroadcastSessionDelegate)? = nil
    ) -> GeistBroadcastSession {
        GeistBroadcastSession(
            simulatorUDID: simulator,
            hostBundleID: hostBundleID,
            extensionContext: extensionContext,
            simctlSetPath: nil,
            videoCapture: videoCapture,
            micAudio: micAudio,
            delegate: delegate,
            stager: StubStager(),
            spawner: StubSpawner()
        )
    }

    private func driveUserPressedStart(
        sut: GeistBroadcastSession,
        hostFD: Int32,
        extFD: Int32,
        extensionConnected: AsyncSignal,
        micEnabled: Bool
    ) async throws {
        try sendMessage(.helloHost, to: hostFD)
        _ = try await readWireMessage(from: hostFD)
        try sendMessage(.helloExtension(extensionBundleID: "com.test.host.cast"), to: extFD)
        await extensionConnected.wait()
        try sendMessage(.userPressedStart(micEnabled: micEnabled), to: hostFD)
        _ = try await readWireMessage(from: extFD)
    }

    private func connectClient(toSocketOf session: GeistBroadcastSession) throws -> Int32 {
        let path = session.socketPath
        return try connect(unixPath: path)
    }

    private func connectFrameClient(toSocketOf session: GeistBroadcastSession) throws -> Int32 {
        let path = "/tmp/geistcast-frames-\(session.simulator)-\(session.hostBundleID).sock"
        return try connect(unixPath: path)
    }

    private func connect(unixPath: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TestError.socket }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        _ = unixPath.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
                tuplePtr.withMemoryRebound(to: CChar.self, capacity: cap) { dst in
                    strlcpy(dst, src, cap)
                }
            }
        }
        let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 { return fd }
        let err = errno
        close(fd)
        throw TestError.connect(errno: err)
    }

    private func readFrameHeader(from fd: Int32) async throws -> FrameHeader {
        let bytes = try await readBytes(from: fd, count: FrameHeader.byteCount)
        guard let header = FrameHeader.decoded(from: bytes) else {
            throw TestError.invalidHeader
        }
        return header
    }

    private func sendMessage(_ message: WireMessage, to fd: Int32) throws {
        let bytes = Array(WireEncoder().encode(message))
        var off = 0
        while off < bytes.count {
            let n = bytes.withUnsafeBytes { ptr in
                Darwin.write(fd, ptr.baseAddress!.advanced(by: off), bytes.count - off)
            }
            guard n > 0 else { throw TestError.write }
            off += n
        }
    }

    private enum TestError: Error {
        case socket
        case connect(errno: Int32)
        case write
        case invalidHeader
    }
}

private func makeBGRAPixelBuffer(width: Int, height: Int, fill: UInt8) throws -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb
    )
    guard status == kCVReturnSuccess, let buf = pb else {
        throw PushDeliveryTestError.pixelBufferCreateFailed
    }
    CVPixelBufferLockBaseAddress(buf, [])
    defer { CVPixelBufferUnlockBaseAddress(buf, []) }
    if let base = CVPixelBufferGetBaseAddress(buf) {
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        memset(base, Int32(fill), bpr * height)
    }
    return buf
}

private func makePCMBuffer(sampleRate: Double, channels: AVAudioChannelCount, frameCount: AVAudioFrameCount) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                sampleRate: sampleRate,
                                channels: channels,
                                interleaved: false)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
    buffer.frameLength = frameCount
    return buffer
}

private enum PushDeliveryTestError: Error {
    case pixelBufferCreateFailed
}

private final class OneShotVideoFrameProducer: VideoFrameProducer, @unchecked Sendable {
    private let buffer: CVPixelBuffer

    init(buffer: CVPixelBuffer) { self.buffer = buffer }

    func start(producing handler: @escaping @Sendable (CVPixelBuffer, CMTime) -> Void) throws {
        handler(buffer, .zero)
    }
    func stop() {}
}

private final class OneShotMicAudioProducer: MicAudioProducer, @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer

    init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    func start(producing handler: @escaping @Sendable (AVAudioPCMBuffer, CMTime) -> Void) throws {
        handler(buffer, .zero)
    }
    func stop() {}
}

private final class StubStager: AppexStaging {
    func stage(appexAt sourcePath: String) async throws -> StagedAppex {
        StagedAppex(binaryPath: "\(sourcePath)/staged/Binary")
    }
}

private final class StubSpawner: AppexSpawning {
    func spawn(stagedBinary: String, simulatorUDID: String,
               simctlSetPath: String?, environment: [String: String]) async throws {}
    func killStale(stagedBinary: String) async {}
}

private final class SignalingDelegate: GeistBroadcastSessionDelegate {
    private let extensionConnected: AsyncSignal
    private let broadcastStarted: AsyncSignal?
    init(extensionConnected: AsyncSignal, broadcastStarted: AsyncSignal? = nil) {
        self.extensionConnected = extensionConnected
        self.broadcastStarted = broadcastStarted
    }
    func session(_: GeistBroadcastSession, extensionConnectedFor _: String) {
        extensionConnected.fire()
    }
    func session(_: GeistBroadcastSession, broadcastStarted _: Broadcast) {
        broadcastStarted?.fire()
    }
}

private final class SilentVideoProducer: VideoFrameProducer {
    func start(producing handler: @escaping @Sendable (CVPixelBuffer, CMTime) -> Void) throws {}
    func stop() {}
}

