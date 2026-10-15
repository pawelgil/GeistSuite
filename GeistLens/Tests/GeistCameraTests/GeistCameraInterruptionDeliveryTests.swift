import Foundation
import GeistCameraShimCore
import Synchronization
import Testing

struct GeistCameraInterruptionDeliveryTests {
    @Test func delivery_PendingTransitions_PrecedeSourceReactivation() async {
        let sut = createSUT()
        let events = Mutex<[String]>([])
        sut.enqueue(afterDraining: { events.withLock { $0.append("drained") } }) {
            events.withLock { $0.append("began") }
        }
        sut.enqueue(afterDraining: {}) { events.withLock { $0.append("ended") } }

        await withCheckedContinuation { continuation in
            sut.afterPendingTransitions {
                events.withLock { $0.append("reactivated") }
                continuation.resume()
            }
        }

        #expect(events.withLock { $0 } == ["drained", "began", "ended", "reactivated"])
    }

    @Test func delivery_BlockedDrain_HoldsNotificationsAndReactivation() async {
        let sut = createSUT()
        let drain = DispatchSemaphore(value: 0)
        let events = Mutex<[String]>([])
        await withCheckedContinuation { continuation in
            sut.enqueue(afterDraining: {
                continuation.resume()
                drain.wait()
            }) { events.withLock { $0.append("began") } }
        }
        sut.enqueue(afterDraining: {}) { events.withLock { $0.append("ended") } }
        #expect(events.withLock { $0.isEmpty })

        await withCheckedContinuation { continuation in
            sut.afterPendingTransitions {
                events.withLock { $0.append("reactivated") }
                continuation.resume()
            }
            drain.signal()
        }

        #expect(events.withLock { $0 } == ["began", "ended", "reactivated"])
    }

    @Test func delivery_NoTransition_StillReactivatesSource() async {
        let sut = createSUT()

        let delivered = await withCheckedContinuation { continuation in
            sut.afterPendingTransitions { continuation.resume(returning: true) }
        }

        #expect(delivered)
    }

    @Test func waitUntilDelivered_PendingDelivery_CompletesBeforeReturning() async {
        let sut = createSUT()
        let events = Mutex<[String]>([])
        sut.enqueue(afterDraining: { events.withLock { $0.append("drained") } }) {
            events.withLock { $0.append("delivered") }
        }

        await withCheckedContinuation { continuation in
            DispatchQueue(label: "test.camera.control").async {
                sut.waitUntilDelivered()
                events.withLock { $0.append("returned") }
                continuation.resume()
            }
        }

        #expect(events.withLock { $0 } == ["drained", "delivered", "returned"])
    }

    private func createSUT() -> GeistCameraInterruptionDelivery {
        GeistCameraInterruptionDelivery(deliveryQueue: DispatchQueue(label: "test.camera.interruptions"))
    }
}
