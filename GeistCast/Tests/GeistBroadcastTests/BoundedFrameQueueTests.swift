import Testing
import Synchronization
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

    @Test
    func enqueue_weightExactlyFillsCapacity_acceptsThenDropsNewest() {
        let sut = BoundedFrameQueue<Int>(maximumWeight: 5, maximumCount: 10)

        #expect(sut.enqueueOrDropNewest(1, weight: 2) == .accepted)
        #expect(sut.enqueueOrDropNewest(2, weight: 3) == .accepted)
        #expect(sut.enqueueOrDropNewest(3, weight: 1) == .dropped)
        #expect(sut.dequeue(timeoutSeconds: 0) == .received(1))
        #expect(sut.dequeue(timeoutSeconds: 0) == .received(2))
    }

    @Test
    func dequeue_weightedItem_refundsItsWeight() {
        let sut = BoundedFrameQueue<Int>(maximumWeight: 3, maximumCount: 3)
        #expect(sut.enqueueOrDropNewest(1, weight: 3) == .accepted)
        #expect(sut.dequeue(timeoutSeconds: 0) == .received(1))

        let outcome = sut.enqueueOrDropNewest(2, weight: 3)

        #expect(outcome == .accepted)
    }

    @Test
    func enqueue_countLimitReached_dropsDespiteRemainingWeight() {
        let sut = BoundedFrameQueue<Int>(maximumWeight: 10, maximumCount: 2)

        #expect(sut.enqueueOrDropNewest(1, weight: 1) == .accepted)
        #expect(sut.enqueueOrDropNewest(2, weight: 1) == .accepted)
        #expect(sut.enqueueOrDropNewest(3, weight: 1) == .dropped)
    }

    @Test
    func enqueue_intMaxWeight_dropsWithoutOverflowingCapacityMath() {
        let sut = BoundedFrameQueue<Int>(maximumWeight: 10, maximumCount: 10)
        #expect(sut.enqueueOrDropNewest(1, weight: 1) == .accepted)

        let outcome = sut.enqueueOrDropNewest(2, weight: .max)

        #expect(outcome == .dropped)
        #expect(sut.dequeue(timeoutSeconds: 0) == .received(1))
    }

    @Test
    func close_weightedItems_clearsAndRejectsFurtherEnqueues() {
        let sut = BoundedFrameQueue<Int>(maximumWeight: 10, maximumCount: 10)
        #expect(sut.enqueueOrDropNewest(1, weight: 6) == .accepted)

        sut.close()

        #expect(sut.dequeue(timeoutSeconds: 0) == .closed)
        #expect(sut.enqueueOrDropNewest(2, weight: 6) == .closed)
    }

    @Test
    func enqueue_countMode_preservesConfiguredCapacity() {
        let sut = BoundedFrameQueue<Int>(capacity: 2)

        #expect(sut.enqueueOrDropNewest(1) == .accepted)
        #expect(sut.enqueueOrDropNewest(2) == .accepted)
        #expect(sut.enqueueOrDropNewest(3) == .dropped)
    }

    @Test
    func concurrentWeightedEnqueues_acceptedItemsDrainExactlyOnceAndRefundWeight() async {
        let maximumWeight = 300
        let sut = BoundedFrameQueue<Int>(maximumWeight: maximumWeight, maximumCount: 200)
        let accepted = Mutex([(item: Int, weight: Int)]())

        await withTaskGroup(of: Void.self) { group in
            for item in 1 ... 200 {
                group.addTask {
                    let weight = item % 7 + 1
                    if sut.enqueueOrDropNewest(item, weight: weight) == .accepted {
                        accepted.withLock { $0.append((item, weight)) }
                    }
                }
            }
        }

        let acceptedItems = accepted.withLock { $0 }
        #expect(acceptedItems.reduce(0) { $0 + $1.weight } <= maximumWeight)

        var drained: [Int] = []
        while case .received(let item) = sut.dequeue(timeoutSeconds: 0) {
            drained.append(item)
        }
        #expect(drained.count == acceptedItems.count)
        #expect(Set(drained) == Set(acceptedItems.map(\.item)))
        #expect(Set(drained).count == drained.count)
        #expect(sut.enqueueOrDropNewest(201, weight: maximumWeight) == .accepted)
    }
}
