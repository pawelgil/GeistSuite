import Foundation

struct BroadcastAttemptState {
    // MARK: Nested Types

    struct Attempt {
        // MARK: Properties

        let id: UUID

        fileprivate let termination: ProcessTermination

        // MARK: Functions

        func forwardTermination(from process: ProcessTermination) {
            process.forward(to: termination)
        }
    }

    private struct Current {
        let attempt: Attempt
        var announcedProcessID: Int32?
    }

    // MARK: Properties

    private(set) var sequence: UInt64 = 0

    private var current: Current?

    // MARK: Computed Properties

    var id: UUID? {
        current?.attempt.id
    }

    // MARK: Functions

    mutating func begin(processTermination: ProcessTermination? = nil) -> Attempt {
        let attempt = Attempt(id: UUID(), termination: ProcessTermination())
        if let processTermination { attempt.forwardTermination(from: processTermination) }
        current = Current(attempt: attempt)
        sequence += 1
        return attempt
    }

    mutating func end(
        reason: BroadcastEnd.Reason, processID: Int32?, timestamp: Date = Date()
    ) -> BroadcastEnd? {
        guard let current else { return nil }
        let end = BroadcastEnd(
            attemptID: current.attempt.id, processID: processID, timestamp: timestamp,
            reason: reason, termination: current.attempt.termination, sequence: sequence
        )
        discard()
        return end
    }

    mutating func discard() {
        current = nil
    }

    mutating func announce(processID: Int32?) -> BroadcastLifecycleEvent? {
        guard current != nil, let processID else { return nil }
        guard current?.announcedProcessID != processID else { return nil }
        current?.announcedProcessID = processID
        return processStarted(processID: processID)
    }

    func processStarted(processID: Int32?) -> BroadcastLifecycleEvent? {
        guard let id, let processID else { return nil }
        return .processStarted(attemptID: id, processID: processID, sequence: sequence)
    }
}
