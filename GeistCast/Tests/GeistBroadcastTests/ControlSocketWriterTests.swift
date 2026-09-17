import Darwin
import Foundation
import Synchronization
import Testing
@testable import GeistBroadcast

@Suite struct ControlSocketWriterTests {
    @Test
    func close_AfterQueuedMessages_WritesInOrderThenCompletes() async {
        let writes = Mutex<[Data]>([])
        let didClose = Mutex(false)
        let sut = ControlSocketWriter(
            fd: -1,
            onFailure: {},
            write: { _, data in
                writes.withLock { $0.append(data) }
                return true
            }
        )

        #expect(sut.enqueue(Data([1])))
        #expect(sut.enqueue(Data([2])))
        #expect(sut.enqueue(Data([3])))
        sut.close { didClose.withLock { $0 = true } }

        #expect(await waitUntil { didClose.withLock { $0 } })
        #expect(writes.withLock { $0 } == [Data([1]), Data([2]), Data([3])])
    }

    @Test
    func close_WhileWriteIsBlocked_DoesNotCloseUntilWriteFinishes() async {
        let gate = DispatchSemaphore(value: 0)
        let didEnterWrite = Mutex(false)
        let closeCount = Mutex(0)
        let sut = ControlSocketWriter(
            fd: -1,
            onFailure: {},
            write: { _, _ in
                didEnterWrite.withLock { $0 = true }
                gate.wait()
                return true
            }
        )
        #expect(sut.enqueue(Data([1])))
        #expect(await waitUntil { didEnterWrite.withLock { $0 } })

        sut.close { closeCount.withLock { $0 += 1 } }
        #expect(closeCount.withLock { $0 } == 0)
        gate.signal()

        #expect(await waitUntil { closeCount.withLock { $0 } == 1 })
    }

    @Test
    func enqueue_WhenBackpressuredCapacityExceeded_ReportsFailureOnce() async {
        let gate = DispatchSemaphore(value: 0)
        let didEnterWrite = Mutex(false)
        let failures = Mutex(0)
        let sut = ControlSocketWriter(
            fd: -1,
            capacity: 1,
            onFailure: { failures.withLock { $0 += 1 } },
            write: { _, _ in
                didEnterWrite.withLock { $0 = true }
                gate.wait()
                return true
            }
        )

        #expect(sut.enqueue(Data([1])))
        #expect(await waitUntil { didEnterWrite.withLock { $0 } })
        #expect(!sut.enqueue(Data([2])))
        #expect(!sut.enqueue(Data([3])))
        gate.signal()

        #expect(await waitUntil { failures.withLock { $0 } == 1 })
    }

    @Test
    func enqueue_WhenWriteFails_ReportsFailureAndRejectsLaterMessages() async {
        let failures = Mutex(0)
        let sut = ControlSocketWriter(
            fd: -1,
            onFailure: { failures.withLock { $0 += 1 } },
            write: { _, _ in false }
        )

        #expect(sut.enqueue(Data([1])))
        #expect(await waitUntil { failures.withLock { $0 } == 1 })
        #expect(!sut.enqueue(Data([2])))
        #expect(failures.withLock { $0 } == 1)
    }

    @Test
    func enqueue_WhenPeerClosed_ReportsFailureWithoutTerminatingProcess() async throws {
        var sockets = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else {
            throw SocketWriterTestError.socketpair(errno)
        }
        let writerFD = sockets[0]
        var noSigPipe: Int32 = 1
        setsockopt(
            writerFD,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )
        close(sockets[1])
        let failures = Mutex(0)
        let didClose = Mutex(false)
        let sut = ControlSocketWriter(
            fd: writerFD,
            onFailure: { failures.withLock { $0 += 1 } }
        )

        #expect(sut.enqueue(Data([1])))
        #expect(await waitUntil { failures.withLock { $0 } == 1 })
        sut.close {
            close(writerFD)
            didClose.withLock { $0 = true }
        }

        #expect(await waitUntil { didClose.withLock { $0 } })
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
}

private enum SocketWriterTestError: Error {
    case socketpair(Int32)
}
