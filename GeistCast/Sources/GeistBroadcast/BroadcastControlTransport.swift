import Darwin
import Foundation
import Synchronization

final class BroadcastControlTransport: Sendable {
    // MARK: Nested Types

    struct ConnectionID: Hashable {
        private let value = UUID()
    }

    struct Connection: Equatable {
        let id: ConnectionID
        let peerPID: Int32?
    }

    enum Event {
        case connected(Connection)
        case messages(Connection, [WireMessage])
        case disconnected(Connection)
        case listenerFailed
    }

    enum Error: Swift.Error { case alreadyStarted }

    private struct Client {
        let connection: Connection
        let fd: Int32
        let writer: ControlSocketWriter
    }

    private enum Phase { case idle, running, stopped }

    private struct State {
        var phase = Phase.idle
        var listener: UnixSocketListener?
        var clients: [ConnectionID: Client] = [:]
        var handler: (@Sendable (Event) async -> Void)?
    }

    // MARK: Properties

    private let path: String
    private let state = Mutex(State())
    private let readQueue = DispatchQueue(label: "com.geist.broadcast.control-read", attributes: .concurrent)

    // MARK: Lifecycle

    init(path: String) {
        self.path = path
    }

    // MARK: Static Functions

    private static func deliver(_ event: Event, to handler: @escaping @Sendable (Event) async -> Void) {
        let completed = DispatchSemaphore(value: 0)
        Task {
            await handler(event)
            completed.signal()
        }
        completed.wait()
    }

    private static func peerPID(_ fd: Int32) -> Int32? {
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0 else { return nil }
        return pid
    }

    // MARK: Functions

    func start(handler: @escaping @Sendable (Event) async -> Void) throws {
        let listener = try state.withLock { state in
            guard state.phase == .idle else { throw Error.alreadyStarted }
            let listener = try UnixSocketListener(
                path: path, backlog: 8,
                onAccept: { [weak self] fd in
                    guard let self else { close(fd); return }
                    accept(fd)
                },
                onFailure: { Task { await handler(.listenerFailed) } },
            )
            state.listener = listener
            state.handler = handler
            state.phase = .running
            return listener
        }
        listener.activate()
    }

    func send(_ message: WireMessage, to id: ConnectionID) {
        state.withLock { state in
            guard let client = state.clients[id] else { return }
            client.writer.enqueue(WireEncoder().encode(message))
        }
    }

    func shutdown(_ id: ConnectionID) {
        state.withLock { state in
            guard let client = state.clients[id] else { return }
            Darwin.shutdown(client.fd, SHUT_RDWR)
        }
    }

    func stop() {
        state.withLock { state in
            guard state.phase != .stopped else { return }
            state.phase = .stopped
            state.listener?.stop()
            state.listener = nil
            state.handler = nil
            for client in state.clients.values {
                Darwin.shutdown(client.fd, SHUT_RDWR)
            }
        }
    }

    private func accept(_ fd: Int32) {
        let accepted = state.withLock { state -> (Client, @Sendable (Event) async -> Void)? in
            guard state.phase == .running, let handler = state.handler else { return nil }
            let connection = Connection(id: ConnectionID(), peerPID: Self.peerPID(fd))
            // Writer failure shuts down the socket; only the reader reports disconnect and owns final close.
            let writer = ControlSocketWriter(fd: fd, onFailure: {})
            let client = Client(connection: connection, fd: fd, writer: writer)
            state.clients[connection.id] = client
            return (client, handler)
        }
        guard let (client, handler) = accepted else { close(fd); return }
        // stop() wakes the reader; retaining the transport keeps ownership alive through writer drain.
        readQueue.async { [self] in read(client, handler: handler) }
    }

    private func read(_ client: Client, handler: @escaping @Sendable (Event) async -> Void) {
        Self.deliver(.connected(client.connection), to: handler)
        var decoder = WireDecoder()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(client.fd, $0.baseAddress, $0.count) }
            guard count > 0 else { break }
            let messages = decoder.feed(Data(buffer.prefix(count)))
            if !messages.isEmpty { Self.deliver(.messages(client.connection, messages), to: handler) }
        }
        finish(client, handler: handler)
    }

    private func finish(_ client: Client, handler: @escaping @Sendable (Event) async -> Void) {
        state.withLock { state in
            state.clients.removeValue(forKey: client.connection.id)
            Darwin.shutdown(client.fd, SHUT_RDWR)
            client.writer.close { close(client.fd) }
        }
        Self.deliver(.disconnected(client.connection), to: handler)
    }
}
