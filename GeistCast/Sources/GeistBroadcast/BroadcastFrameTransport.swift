import Darwin
import Foundation
import Synchronization

final class BroadcastFrameTransport: Sendable {
    // MARK: Nested Types

    enum Error: Swift.Error, Equatable {
        case alreadyStarted
    }

    private enum Phase {
        case idle
        case listening
        case stopped
    }

    private final class Connection: Sendable {
        // MARK: Properties

        let id = UUID()
        let fd: Int32
        let token = WorkerToken()

        private let closed = Mutex(false)

        // MARK: Lifecycle

        init(fd: Int32) {
            self.fd = fd
        }

        // MARK: Functions

        func shutdown() {
            closed.withLock { isClosed in
                if !isClosed { Darwin.shutdown(fd, SHUT_RDWR) }
            }
        }

        func close() {
            closed.withLock { isClosed in
                guard !isClosed else { return }
                isClosed = true
                Darwin.close(fd)
            }
        }
    }

    private struct State {
        var phase = Phase.idle
        var listener: UnixSocketListener?
        var active: Connection?
        var pendingFD: Int32?
    }

    private final class WorkerToken: Sendable {
        // MARK: Properties

        private let active = Mutex(true)

        // MARK: Functions

        func deactivate() {
            active.withLock { $0 = false }
        }

        func performIfActive<Result: Sendable>(_ operation: () -> Result) -> Result? {
            active.withLock { isActive in
                guard isActive else { return nil }
                return operation()
            }
        }
    }

    // MARK: Properties

    let path: String
    let sink: any BroadcastSink

    private let state = Mutex(State())
    private let videoQueue: BoundedFrameQueue<Data>
    private let micQueue: BoundedFrameQueue<Data>
    private let serveQueue = DispatchQueue(label: "com.geist.broadcast.frame-serve")

    // MARK: Lifecycle

    init(path: String) {
        self.path = path
        let videoQueue = BoundedFrameQueue<Data>(capacity: 1)
        let micQueue = BoundedFrameQueue<Data>(capacity: 16)
        self.videoQueue = videoQueue
        self.micQueue = micQueue
        sink = SessionBroadcastSink(videoQueue: videoQueue, micQueue: micQueue)
    }

    deinit {
        stop()
    }

    // MARK: Static Functions

    private static func serve(
        _ connection: Connection, videoQueue: BoundedFrameQueue<Data>, micQueue: BoundedFrameQueue<Data>,
    ) {
        while true {
            guard let iteration = connection.token.performIfActive({
                var wroteAny = false
                var openCount = 0
                for queue in [micQueue, videoQueue] {
                    switch queue.dequeue(timeoutSeconds: 0) {
                    case let .received(payload):
                        guard writeAll(fd: connection.fd, data: payload) else { return (false, 0) }
                        wroteAny = true
                        openCount += 1
                    case .empty:
                        openCount += 1
                    case .closed:
                        break
                    }
                }
                return (wroteAny, openCount)
            }) else { return }
            if iteration.1 == 0 { return }
            if !iteration.0 { usleep(5000) }
        }
    }

    private static func writeAll(fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return true }
            var offset = 0
            while offset < bytes.count {
                let count = write(fd, base.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }

    // MARK: Functions

    func start(onFatalFailure: @escaping @Sendable () -> Void) throws {
        let listener = try state.withLock { state in
            guard state.phase == .idle else { throw Error.alreadyStarted }
            let listener = try UnixSocketListener(
                path: path, backlog: 4,
                onAccept: { [weak self] fd in
                    guard let self else {
                        shutdown(fd, SHUT_RDWR)
                        close(fd)
                        return
                    }
                    accept(fd)
                },
                onFailure: onFatalFailure,
            )
            state.listener = listener
            state.phase = .listening
            return listener
        }
        listener.activate()
    }

    func stop() {
        let listener = state.withLock { state -> UnixSocketListener? in
            guard state.phase != .stopped else { return nil }
            state.phase = .stopped
            let listener = state.listener
            state.listener = nil
            videoQueue.close()
            micQueue.close()
            if let pending = state.pendingFD {
                shutdown(pending, SHUT_RDWR)
                close(pending)
                state.pendingFD = nil
            }
            if let active = state.active { deactivate(active) }
            return listener
        }
        listener?.stop()
    }

    private func accept(_ fd: Int32) {
        state.withLock { state in
            guard state.phase == .listening else {
                shutdown(fd, SHUT_RDWR)
                close(fd)
                return
            }
            if let active = state.active {
                if let pending = state.pendingFD {
                    shutdown(pending, SHUT_RDWR)
                    close(pending)
                }
                state.pendingFD = fd
                deactivate(active)
            } else {
                startWorker(fd: fd, state: &state)
            }
        }
    }

    private func deactivate(_ connection: Connection) {
        // The worker holds its token during writes; shutdown must unblock the write before taking that lock.
        connection.shutdown()
        connection.token.deactivate()
    }

    private func startWorker(fd: Int32, state: inout State) {
        let connection = Connection(fd: fd)
        state.active = connection
        let videoQueue = videoQueue
        let micQueue = micQueue
        serveQueue.async { [weak self] in
            Self.serve(connection, videoQueue: videoQueue, micQueue: micQueue)
            if let self { workerEnded(connection) }
            else { connection.close() }
        }
    }

    private func workerEnded(_ connection: Connection) {
        state.withLock { state in
            connection.close()
            guard state.active?.id == connection.id else { return }
            state.active = nil
            guard state.phase == .listening, let replacement = state.pendingFD else { return }
            state.pendingFD = nil
            startWorker(fd: replacement, state: &state)
        }
    }
}
