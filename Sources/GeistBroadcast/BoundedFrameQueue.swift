import Foundation

final class BoundedFrameQueue<Element: Sendable>: @unchecked Sendable {

    enum EnqueueOutcome: Sendable, Equatable {
        case accepted
        case dropped
        case closed
    }

    enum DequeueOutcome: Sendable {
        case received(Element)
        case empty
        case closed
    }

    private let condition = NSCondition()
    private var items: [Element] = []
    private let capacity: Int
    private var isClosed = false

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    // Drop-newest matches how the system delivers to broadcast extensions:
    // the producer never waits.
    func enqueueOrDropNewest(_ item: Element) -> EnqueueOutcome {
        condition.lock(); defer { condition.unlock() }
        if isClosed { return .closed }
        if items.count >= capacity { return .dropped }
        items.append(item)
        condition.broadcast()
        return .accepted
    }

    func dequeue(timeoutSeconds: TimeInterval) -> DequeueOutcome {
        let deadline = Date(timeIntervalSinceNow: timeoutSeconds)
        condition.lock(); defer { condition.unlock() }
        while items.isEmpty {
            if isClosed { return .closed }
            if !condition.wait(until: deadline) { return .empty }
        }
        let item = items.removeFirst()
        condition.broadcast()
        return .received(item)
    }

    func close() {
        condition.lock(); defer { condition.unlock() }
        isClosed = true
        items.removeAll()
        condition.broadcast()
    }
}

extension BoundedFrameQueue.DequeueOutcome: Equatable where Element: Equatable {}
