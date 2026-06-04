import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import GeistCamera

@Suite("DetectionRouter")
struct DetectionRouterTests {
    private static func makePixelBuffer() -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 16, 16,
                            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                            nil, &pb)
        return pb!
    }

    @Test func sendVideo_alwaysForwardsToDownstream() {
        let downstreamSpy = DownstreamVideoSinkSpy()
        let detectorSpy = HostDetectingSpy()
        let registry = DemandRegistry()
        let router = DetectionRouter(slot: 0, downstream: downstreamSpy,
                                      demand: registry, detector: detectorSpy)

        router.sendVideo(Self.makePixelBuffer(), pts: .zero, duration: .zero)

        #expect(downstreamSpy.receivedCallCount == 1)
    }

    @Test func sendVideo_demandEmpty_doesNotCallDetector() {
        let downstreamSpy = DownstreamVideoSinkSpy()
        let detectorSpy = HostDetectingSpy()
        let registry = DemandRegistry()
        let router = DetectionRouter(slot: 0, downstream: downstreamSpy,
                                      demand: registry, detector: detectorSpy)

        router.sendVideo(Self.makePixelBuffer(), pts: .zero, duration: .zero)

        #expect(detectorSpy.receivedCallCount == 0)
    }

    @Test func sendVideo_demandWantsQR_callsDetectorWithSameDemand() {
        let downstreamSpy = DownstreamVideoSinkSpy()
        let detectorSpy = HostDetectingSpy()
        let registry = DemandRegistry()
        registry.update(slot: 0, demand: SlotDemand(wantsQR: true, wantsFace: false))
        let router = DetectionRouter(slot: 0, downstream: downstreamSpy,
                                      demand: registry, detector: detectorSpy)

        router.sendVideo(Self.makePixelBuffer(), pts: .zero, duration: .zero)

        #expect(detectorSpy.receivedCallCount == 1)
        #expect(detectorSpy.lastDemand?.wantsQR == true)
        #expect(detectorSpy.lastDemand?.wantsFace == false)
    }

    @Test func sendVideo_demandForDifferentSlot_doesNotCallDetector() {
        let downstreamSpy = DownstreamVideoSinkSpy()
        let detectorSpy = HostDetectingSpy()
        let registry = DemandRegistry()
        registry.update(slot: 1, demand: SlotDemand(wantsQR: true, wantsFace: false))
        let router = DetectionRouter(slot: 0, downstream: downstreamSpy,
                                      demand: registry, detector: detectorSpy)

        router.sendVideo(Self.makePixelBuffer(), pts: .zero, duration: .zero)

        #expect(detectorSpy.receivedCallCount == 0)
    }

    @Test func sendVideo_calledMultipleTimes_forwardsEachToDownstream() {
        let downstreamSpy = DownstreamVideoSinkSpy()
        let detectorSpy = HostDetectingSpy()
        let registry = DemandRegistry()
        let router = DetectionRouter(slot: 0, downstream: downstreamSpy,
                                      demand: registry, detector: detectorSpy)

        router.sendVideo(Self.makePixelBuffer(), pts: .zero, duration: .zero)
        router.sendVideo(Self.makePixelBuffer(), pts: .zero, duration: .zero)
        router.sendVideo(Self.makePixelBuffer(), pts: .zero, duration: .zero)

        #expect(downstreamSpy.receivedCallCount == 3)
    }
}

// MARK: - Test Doubles

private final class DownstreamVideoSinkSpy: VideoFrameSink, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var receivedCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    func sendVideo(_ pixelBuffer: CVPixelBuffer, pts: CMTime, duration: CMTime) {
        lock.lock(); defer { lock.unlock() }
        count += 1
    }
}

private final class HostDetectingSpy: HostDetecting, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var lastSlotValue: UInt32?
    private var lastDemandValue: SlotDemand?

    var receivedCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    var lastSlot: UInt32? {
        lock.lock(); defer { lock.unlock() }
        return lastSlotValue
    }

    var lastDemand: SlotDemand? {
        lock.lock(); defer { lock.unlock() }
        return lastDemandValue
    }

    func process(slot: UInt32, pixelBuffer: CVPixelBuffer, demand: SlotDemand) {
        lock.lock(); defer { lock.unlock() }
        count += 1
        lastSlotValue = slot
        lastDemandValue = demand
    }
}
