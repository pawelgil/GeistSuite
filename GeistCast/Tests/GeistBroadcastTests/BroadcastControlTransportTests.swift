import Darwin
import Foundation
@testable import GeistBroadcast
import Testing

struct BroadcastControlTransportTests {
    @Test(.timeLimit(.minutes(1)))
    func `control pipelined messages preserves identity and order through disconnect`() async throws {
        let (sut, path, events) = try createSUT()
        defer { sut.stop() }
        let peer = try connect(to: path)
        defer { close(peer) }
        var iterator = events.makeAsyncIterator()
        let connection = try await requireConnected(iterator.next())
        let messages: [WireMessage] = [.helloHost, .userPressedStart(micEnabled: false)]

        try write(messages, to: peer)
        shutdown(peer, SHUT_WR)
        let trace = await remainingTrace(&iterator)

        #expect(connection.peerPID == getpid())
        #expect(trace == messages.map { .message(connection, $0) } + [.disconnected(connection)])
        await #expect(throws: SocketReadError.closed) { try await readBytes(from: peer, count: 1) }
    }

    @Test(.timeLimit(.minutes(1)))
    func `control send writes messages in order`() async throws {
        let (sut, path, events) = try createSUT()
        defer { sut.stop() }
        let peer = try connect(to: path)
        defer { close(peer) }
        var iterator = events.makeAsyncIterator()
        let connection = try await requireConnected(iterator.next())

        sut.send(.pause(requestID: "first"), to: connection.id)
        sut.send(.resume(requestID: "second"), to: connection.id)

        #expect(try await readWireMessage(from: peer) == .pause(requestID: "first"))
        #expect(try await readWireMessage(from: peer) == .resume(requestID: "second"))
        sut.stop()
        #expect(await remainingTrace(&iterator) == [.disconnected(connection)])
    }

    @Test(.timeLimit(.minutes(1)))
    func `control stop while connected handler suspends does not wait for handler`() async throws {
        let release = AsyncSignal()
        let (sut, path, events) = try createSUT(beforeReturn: { event in
            if case .connected = event { await release.wait() }
        })
        let peer = try connect(to: path)
        defer { close(peer); release.fire(); sut.stop() }
        var iterator = events.makeAsyncIterator()
        let connection = try await requireConnected(iterator.next())
        sut.send(.helloHost, to: connection.id)
        #expect(try await readWireMessage(from: peer) == .helloHost)

        sut.stop()
        sut.stop()
        release.fire()

        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(await remainingTrace(&iterator) == [.disconnected(connection)])
        await #expect(throws: SocketReadError.closed) { try await readBytes(from: peer, count: 1) }
    }

    @Test(.timeLimit(.minutes(1)))
    func `control peer closes with pending write reports one disconnect`() async throws {
        let release = AsyncSignal()
        let (sut, path, events) = try createSUT(beforeReturn: { event in
            if case .connected = event { await release.wait() }
        })
        defer { release.fire(); sut.stop() }
        let peer = try connect(to: path)
        var iterator = events.makeAsyncIterator()
        let connection = try await requireConnected(iterator.next())

        close(peer)
        sut.send(.finish, to: connection.id)
        release.fire()

        #expect(await remainingTrace(&iterator) == [.disconnected(connection)])
        sut.send(.finish, to: connection.id)
        sut.shutdown(connection.id)
    }

    @Test(.timeLimit(.minutes(1)))
    func `control connection replaced stale identity cannot affect replacement`() async throws {
        let path = socketPath()
        let sut = BroadcastControlTransport(path: path)
        let events = AsyncStream<BroadcastControlTransport.Event>.makeStream()
        try sut.start { events.continuation.yield($0) }
        defer { sut.stop(); events.continuation.finish() }
        var iterator = events.stream.makeAsyncIterator()
        let firstPeer = try connect(to: path)
        defer { close(firstPeer) }
        let first = try await requireConnected(iterator.next())
        sut.shutdown(first.id)
        #expect(try await requireDisconnected(iterator.next()) == first)
        let secondPeer = try connect(to: path)
        defer { close(secondPeer) }
        let second = try await requireConnected(iterator.next())

        sut.send(.finish, to: first.id)
        sut.shutdown(first.id)
        sut.send(.helloHost, to: second.id)

        #expect(first.id != second.id)
        await #expect(throws: SocketReadError.closed) { try await readBytes(from: firstPeer, count: 1) }
        #expect(try await readWireMessage(from: secondPeer) == .helloHost)
        sut.stop()
        #expect(try await requireDisconnected(iterator.next()) == second)
    }

    @Test func `control restart after stop is rejected`() throws {
        let (sut, _, _) = try createSUT()
        sut.stop()

        #expect(throws: BroadcastControlTransport.Error.self) { try sut.start { _ in } }
    }

    private func createSUT(
        beforeReturn: @escaping @Sendable (BroadcastControlTransport.Event) async -> Void = { _ in },
    ) throws -> (BroadcastControlTransport, String, AsyncStream<BroadcastControlTransport.Event>) {
        let path = socketPath()
        let sut = BroadcastControlTransport(path: path)
        let events = AsyncStream<BroadcastControlTransport.Event>.makeStream()
        try sut.start { event in
            events.continuation.yield(event)
            await beforeReturn(event)
            if case .disconnected = event { events.continuation.finish() }
        }
        return (sut, path, events.stream)
    }

    private func requireConnected(_ event: BroadcastControlTransport.Event?) throws -> BroadcastControlTransport.Connection {
        let event = try #require(event)
        guard case let .connected(connection) = event else { throw ControlTestError.unexpectedEvent }
        return connection
    }

    private func requireDisconnected(_ event: BroadcastControlTransport.Event?) throws -> BroadcastControlTransport.Connection {
        let event = try #require(event)
        guard case let .disconnected(connection) = event else { throw ControlTestError.unexpectedEvent }
        return connection
    }

    private func remainingTrace(_ iterator: inout AsyncStream<BroadcastControlTransport.Event>.Iterator) async -> [Trace] {
        var trace: [Trace] = []
        while let event = await iterator.next() {
            switch event {
            case let .connected(connection): trace.append(.connected(connection))
            case let .messages(connection, messages): trace.append(contentsOf: messages.map { .message(connection, $0) })
            case let .disconnected(connection): trace.append(.disconnected(connection))
            case .listenerFailed: trace.append(.listenerFailed)
            }
        }
        return trace
    }

    private func socketPath() -> String {
        "/tmp/control-\(UUID().uuidString).sock"
    }

    private func write(_ messages: [WireMessage], to fd: Int32) throws {
        let data = messages.reduce(into: Data()) { $0.append(WireEncoder().encode($1)) }
        let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        #expect(count == data.count)
    }

    private func connect(to path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlTestError.socket(errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 104) { destination in
                _ = path.withCString { strlcpy(destination, $0, 104) }
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let error = errno
            close(fd)
            throw ControlTestError.connect(error)
        }
        return fd
    }
}

private enum Trace: Equatable {
    case connected(BroadcastControlTransport.Connection)
    case message(BroadcastControlTransport.Connection, WireMessage)
    case disconnected(BroadcastControlTransport.Connection)
    case listenerFailed
}

private enum ControlTestError: Error {
    case socket(Int32)
    case connect(Int32)
    case unexpectedEvent
}
