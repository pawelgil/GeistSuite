import Testing
@testable import GeistBroadcast

@Suite("BoundedFrameQueue") struct BoundedFrameQueueTests {

    @Test
    func enqueue_underCapacity_returnsAccepted() {
        let sut = BoundedFrameQueue<Int>(capacity: 2)

        let outcome = sut.enqueueOrDropNewest(1)

        #expect(outcome == .accepted)
    }

    @Test
    func enqueue_atCapacity_returnsDropped() {
        let sut = BoundedFrameQueue<Int>(capacity: 1)
        _ = sut.enqueueOrDropNewest(1)

        let outcome = sut.enqueueOrDropNewest(2)

        #expect(outcome == .dropped)
    }

    @Test
    func enqueue_droppedItem_doesNotReplaceQueuedItem() {
        let sut = BoundedFrameQueue<Int>(capacity: 1)
        _ = sut.enqueueOrDropNewest(1)
        _ = sut.enqueueOrDropNewest(2)

        let dequeued = sut.dequeue(timeoutSeconds: 0)

        #expect(dequeued == .received(1))
    }

    @Test
    func dequeue_empty_returnsEmptyOnTimeout() {
        let sut = BoundedFrameQueue<Int>(capacity: 2)

        let outcome = sut.dequeue(timeoutSeconds: 0.05)

        #expect(outcome == .empty)
    }

    @Test
    func dequeue_afterClose_returnsClosed() {
        let sut = BoundedFrameQueue<Int>(capacity: 2)
        sut.close()

        let outcome = sut.dequeue(timeoutSeconds: 0)

        #expect(outcome == .closed)
    }

    @Test
    func dequeue_multipleEnqueued_returnsItemsInFIFOOrder() {
        let sut = BoundedFrameQueue<Int>(capacity: 4)
        _ = sut.enqueueOrDropNewest(10)
        _ = sut.enqueueOrDropNewest(20)
        _ = sut.enqueueOrDropNewest(30)

        #expect(sut.dequeue(timeoutSeconds: 0) == .received(10))
        #expect(sut.dequeue(timeoutSeconds: 0) == .received(20))
        #expect(sut.dequeue(timeoutSeconds: 0) == .received(30))
    }

    @Test
    func enqueue_afterClose_returnsClosed() {
        let sut = BoundedFrameQueue<Int>(capacity: 2)
        sut.close()

        let outcome = sut.enqueueOrDropNewest(1)

        #expect(outcome == .closed)
    }

    @Test
    func close_whileDequeueWaiting_releasesWithClosed() async {
        let sut = BoundedFrameQueue<Int>(capacity: 1)

        async let dequeued = Task.detached {
            sut.dequeue(timeoutSeconds: 10)
        }.value
        async let closed: Void = Task.detached { sut.close() }.value

        _ = await closed
        let outcome = await dequeued

        #expect(outcome == .closed)
    }
}
