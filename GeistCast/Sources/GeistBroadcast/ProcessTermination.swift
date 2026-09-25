import Foundation
import Synchronization

final class ProcessTermination: ProcessTerminationReceipt {
    // MARK: Nested Types

    private struct State {
        var value: Int32?
        var waiters: [UUID: CheckedContinuation<Int32, any Error>] = [:]
        var observers: [@Sendable (Int32) -> Void] = []
    }

    // MARK: Properties

    private let state = Mutex(State())

    // MARK: Computed Properties

    var value: Int32? {
        state.withLock { $0.value }
    }

    // MARK: Lifecycle

    init() {}

    // MARK: Functions

    func wait() async throws -> Int32 {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.withLock { state in
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else if let value = state.value {
                        continuation.resume(returning: value)
                    } else {
                        state.waiters[id] = continuation
                    }
                }
            }
        } onCancel: {
            let waiter = self.state.withLock { $0.waiters.removeValue(forKey: id) }
            waiter?.resume(throwing: CancellationError())
        }
    }

    func record(_ value: Int32) {
        let completed: State? = state.withLock { state in
            guard state.value == nil else { return nil }
            state.value = value
            let completed = state
            state.waiters.removeAll()
            state.observers.removeAll()
            return completed
        }
        guard let completed else { return }
        for waiter in completed.waiters.values {
            waiter.resume(returning: value)
        }
        for observer in completed.observers {
            observer(value)
        }
    }

    func forward(to target: ProcessTermination) {
        let value = state.withLock { state -> Int32? in
            if let value = state.value { return value }
            state.observers.append { target.record($0) }
            return nil
        }
        if let value { target.record(value) }
    }
}
