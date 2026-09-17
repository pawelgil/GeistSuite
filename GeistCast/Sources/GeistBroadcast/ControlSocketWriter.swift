import Darwin
import Foundation
import Synchronization

final class ControlSocketWriter: Sendable {
    private struct State {
        var closeCompletion: (@Sendable () -> Void)?
        var didReportFailure = false
        var isAccepting = true
        var pendingCount = 0
    }

    private let capacity: Int
    private let fd: Int32
    private let onFailure: @Sendable () -> Void
    private let queue: DispatchQueue
    private let state = Mutex(State())
    private let write: @Sendable (Int32, Data) -> Bool

    init(
        fd: Int32,
        capacity: Int = 16,
        onFailure: @escaping @Sendable () -> Void,
        write: @escaping @Sendable (Int32, Data) -> Bool = ControlSocketWriter.writeAll
    ) {
        precondition(capacity > 0)
        self.fd = fd
        self.capacity = capacity
        self.onFailure = onFailure
        self.write = write
        self.queue = DispatchQueue(label: "com.geist.broadcast.control-write.\(fd)")
    }

    @discardableResult
    func enqueue(_ data: Data) -> Bool {
        let accepted = state.withLock { state in
            guard state.isAccepting else { return false }
            guard state.pendingCount < capacity else {
                state.isAccepting = false
                return false
            }
            state.pendingCount += 1
            queue.async { [self] in
                finishWrite(succeeded: write(fd, data))
            }
            return true
        }
        guard accepted else {
            reportFailure()
            return false
        }
        return true
    }

    func close(completion: @escaping @Sendable () -> Void) {
        let finishImmediately = state.withLock { state in
            state.isAccepting = false
            guard state.pendingCount > 0 else { return true }
            state.closeCompletion = completion
            return false
        }
        if finishImmediately { queue.async(execute: completion) }
    }

    private func finishWrite(succeeded: Bool) {
        let result = state.withLock { state -> (reportFailure: Bool, close: (@Sendable () -> Void)?) in
            state.pendingCount -= 1
            let shouldReportFailure = !succeeded && !state.didReportFailure
            if shouldReportFailure {
                state.didReportFailure = true
                state.isAccepting = false
            }
            let closeCompletion = state.pendingCount == 0 ? state.closeCompletion : nil
            if closeCompletion != nil { state.closeCompletion = nil }
            return (shouldReportFailure, closeCompletion)
        }
        if result.reportFailure {
            shutdown(fd, SHUT_RDWR)
            onFailure()
        }
        result.close?()
    }

    private func reportFailure() {
        let shouldReport = state.withLock { state in
            guard !state.didReportFailure else { return false }
            state.didReportFailure = true
            return true
        }
        guard shouldReport else { return }
        shutdown(fd, SHUT_RDWR)
        onFailure()
    }

    private static func writeAll(fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { ptr -> Bool in
            guard let base = ptr.baseAddress else { return true }
            var remaining = ptr.count
            var offset = 0
            while remaining > 0 {
                let count = Darwin.write(fd, base.advanced(by: offset), remaining)
                if count <= 0 { return false }
                remaining -= count
                offset += count
            }
            return true
        }
    }
}
