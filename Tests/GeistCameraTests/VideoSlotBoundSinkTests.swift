import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import GeistCamera

@Suite("VideoSlotBoundSink")
struct VideoSlotBoundSinkTests {
    private static func makePixelBuffer(_ osType: OSType, w: Int = 16, h: Int = 16) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, w, h, osType, nil, &pb)
        return pb!
    }

    private static func makeSink(expected: PixelFormat, client: any FrameTransport) -> VideoSlotBoundSink {
        VideoSlotBoundSink(
            wireIndex: 0,
            declaredFormat: VideoSlotFormat(width: 16, height: 16, pixelFormat: expected, fps: 30),
            client: client,
            heartbeat: FrameHeartbeat()
        )
    }

    // Framed wire layout: length(4) + type(4) + WireVideoFrameHeader{ slot(4),
    // width(4), height(4), pixelFormat(4), ... } → pixelFormat at byte 20.
    private static func wirePixelFormat(_ frame: Data) -> OSType {
        frame.readLE(at: 20)
    }

    @Test func sendVideo_formatMatchesExpected_sendsFrame() {
        let spy = FrameTransportSpy()
        let sink = Self.makeSink(expected: .yuv420FullRange, client: spy)

        sink.sendVideo(Self.makePixelBuffer(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
                       pts: .zero, duration: .zero)

        #expect(spy.sentFrames.count == 1)
        #expect(Self.wirePixelFormat(spy.sentFrames[0]) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
    }

    @Test func sendVideo_appNegotiatedVideoRange_convertsAndSendsAsVideoRange() {
        let spy = FrameTransportSpy()
        let sink = Self.makeSink(expected: .yuv420FullRange, client: spy)
        sink.updateExpectedFormat(VideoSlotFormat(width: 16, height: 16,
                                                  pixelFormat: .yuv420VideoRange, fps: 30))

        // Producer still emits full range; without conversion the shim would
        // drop every frame as a mismatch (the HOST black-preview bug).
        sink.sendVideo(Self.makePixelBuffer(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
                       pts: .zero, duration: .zero)

        #expect(spy.sentFrames.count == 1)
        #expect(Self.wirePixelFormat(spy.sentFrames[0]) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    }

    @Test func sendVideo_incompatibleFormat_dropsFrame() {
        let spy = FrameTransportSpy()
        let sink = Self.makeSink(expected: .yuv420FullRange, client: spy)

        sink.sendVideo(Self.makePixelBuffer(kCVPixelFormatType_32BGRA),
                       pts: .zero, duration: .zero)

        #expect(spy.sentFrames.isEmpty)
    }
}

// MARK: - Test Doubles

private final class FrameTransportSpy: FrameTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [Data] = []

    var sentFrames: [Data] {
        lock.lock(); defer { lock.unlock() }
        return frames
    }

    func send(_ frame: Data) {
        lock.lock(); defer { lock.unlock() }
        frames.append(frame)
    }
}
