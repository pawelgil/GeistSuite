import Foundation

// The condition lock protects entries, occupied weight, and closed state together.
final class BoundedFrameQueue<Element: Sendable>: @unchecked Sendable {

    private struct Entry {
        let element: Element
        let weight: Int
    }

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
    private var items: [Entry] = []
    private let maximumWeight: Int
    private let maximumCount: Int
    private var occupiedWeight = 0
    private var isClosed = false

    convenience init(capacity: Int) {
        self.init(maximumWeight: capacity, maximumCount: capacity)
    }

    init(maximumWeight: Int, maximumCount: Int) {
        precondition(maximumWeight > 0)
        precondition(maximumCount > 0)
        self.maximumWeight = maximumWeight
        self.maximumCount = maximumCount
    }

    // Drop-newest matches how the system delivers to broadcast extensions:
    // the producer never waits.
    func enqueueOrDropNewest(_ item: Element, weight: Int = 1) -> EnqueueOutcome {
        precondition(weight > 0)
        condition.lock(); defer { condition.unlock() }
        if isClosed { return .closed }
        if items.count >= maximumCount || weight > maximumWeight - occupiedWeight {
            return .dropped
        }
        items.append(Entry(element: item, weight: weight))
        occupiedWeight += weight
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
        let entry = items.removeFirst()
        occupiedWeight -= entry.weight
        condition.broadcast()
        return .received(entry.element)
    }

    func close() {
        condition.lock(); defer { condition.unlock() }
        isClosed = true
        items.removeAll()
        occupiedWeight = 0
        condition.broadcast()
    }
}

extension BoundedFrameQueue.DequeueOutcome: Equatable where Element: Equatable {}
