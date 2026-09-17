import Foundation
import Testing
@testable import GeistCamera

@Suite("Outbound frame buffer")
struct OutboundFrameBufferTests {
    @Test func enqueueVideo_SameSlotPending_KeepsLatestAtCurrentPosition() {
        var buffer = OutboundFrameBuffer(byteLimit: 64)
        let oldVideo = video(slot: 0, marker: 1)
        let reliable = OutboundFrame.reliable(type: .hello, payload: Data())
        let latestVideo = video(slot: 0, marker: 2)

        #expect(buffer.enqueue(oldVideo) == .accepted)
        #expect(buffer.enqueue(reliable) == .accepted)
        #expect(buffer.enqueue(latestVideo) == .accepted)

        #expect(popEncoded(&buffer) == [reliable.encoded, latestVideo.encoded])
    }

    @Test func enqueueReliable_CapacityNeedsVideo_EvictsOldestVideoAndPreservesReliableFIFO() {
        var buffer = OutboundFrameBuffer(byteLimit: 40)
        let reliable1 = OutboundFrame.reliable(type: .hello, payload: Data(count: 12))
        let queuedVideo = video(slot: 0, marker: 1)
        let reliable2 = OutboundFrame.reliable(type: .metadataResults, payload: Data(count: 12))

        #expect(buffer.enqueue(reliable1) == .accepted)
        #expect(buffer.enqueue(queuedVideo) == .accepted)
        #expect(buffer.enqueue(reliable2) == .accepted)

        #expect(buffer.pendingBytes == 40)
        #expect(popEncoded(&buffer) == [reliable1.encoded, reliable2.encoded])
    }

    @Test func enqueueVideo_InsufficientCapacity_DropsWithoutExceedingLimit() {
        var buffer = OutboundFrameBuffer(byteLimit: 16)
        let reliable = OutboundFrame.reliable(type: .hello, payload: Data())

        #expect(buffer.enqueue(reliable) == .accepted)
        #expect(buffer.enqueue(video(slot: 0, marker: 1)) == .droppedVideo)

        #expect(buffer.pendingBytes == reliable.byteCount)
        #expect(popEncoded(&buffer) == [reliable.encoded])
    }

    @Test func enqueueReliable_IndividualFrameExceedsLimit_RejectsWithoutQueueing() {
        var buffer = OutboundFrameBuffer(byteLimit: 16)
        let oversized = OutboundFrame.reliable(type: .hello, payload: Data(count: 9))

        let admission = buffer.enqueue(oversized)

        #expect(admission == .rejected(.capacity))
        #expect(buffer.pendingBytes == 0)
        #expect(buffer.popFirst() == nil)
    }

    @Test func enqueueReliable_IndividualFrameEqualsLimit_AcceptsAtExactBound() {
        var buffer = OutboundFrameBuffer(byteLimit: 16)
        let exact = OutboundFrame.reliable(type: .hello, payload: Data(count: 8))

        let admission = buffer.enqueue(exact)

        #expect(admission == .accepted)
        #expect(buffer.pendingBytes == 16)
    }

    @Test func defaultByteLimit_IsFixedAt32MiB() {
        #expect(OutboundFrameBuffer.defaultByteLimit == 32 * 1024 * 1024)
    }

    @Test func popFirst_AfterPartialStorageConsumed_RefillDrainsNewFrames() {
        var buffer = OutboundFrameBuffer(byteLimit: 64)
        let first = OutboundFrame.reliable(type: .hello, payload: Data())
        let second = OutboundFrame.reliable(type: .metadataResults, payload: Data())
        #expect(buffer.enqueue(first) == .accepted)
        #expect(buffer.popFirst()?.encoded == first.encoded)

        #expect(buffer.enqueue(second) == .accepted)

        #expect(buffer.popFirst()?.encoded == second.encoded)
        #expect(buffer.popFirst() == nil)
        #expect(buffer.pendingBytes == 0)
    }

    private func popEncoded(_ buffer: inout OutboundFrameBuffer) -> [Data] {
        var frames: [Data] = []
        while let frame = buffer.popFirst() {
            frames.append(frame.encoded)
        }
        #expect(buffer.pendingBytes == 0)
        return frames
    }

    private func video(slot: UInt32, marker: UInt8) -> OutboundFrame {
        .video(slot: slot, payload: Data([marker, 0, 0, 0]))
    }
}
