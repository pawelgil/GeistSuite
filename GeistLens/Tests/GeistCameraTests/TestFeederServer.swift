import Darwin
import Foundation
import Synchronization
@testable import GeistCamera

/// AF_UNIX server used by GeistCamSession tests. Stands in for the shim:
/// accepts the session's outgoing connection, parses framed messages from
/// the session, and sends framed messages back. The session's wire protocol
/// is the contract being exercised.
///
/// One connection per server instance. Construct with `listen()`; the server
/// is ready to accept as soon as it returns.
final class TestFeederServer: @unchecked Sendable {
    private struct SocketState {
        var connectionFD: Int32 = -1
        var isClosed = false
    }

    private let listenFd: Int32
    private let path: String
    private let acceptSource: DispatchSourceRead
    private let ioQueue = DispatchQueue(label: "com.geist.camera-tests.feeder-socket")
    private let sendGroup = DispatchGroup()
    private let socketState = Mutex(SocketState())
    private let clientCloseContinuation: AsyncStream<Void>.Continuation
    private let inboundContinuation: AsyncStream<InboundMessage>.Continuation
    private let clientClose: AsyncStream<Void>
    let inbound: AsyncStream<InboundMessage>

    struct InboundMessage: Sendable {
        let type: WireMessageType
        let payload: Data
    }

    enum ServerError: Error {
        case socketCreateFailed(Int32)
        case bindFailed(Int32)
        case listenFailed(Int32)
        case pathTooLong
    }

    var socketPath: String { path }

    static func listen() throws -> TestFeederServer {
        try TestFeederServer(path: uniqueSocketPath())
    }

    static func uniqueSocketPath() -> String {
        let id = UUID().uuidString.prefix(8)
        return (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("geistcam-test-\(id).sock")
    }

    private init(path: String) throws {
        self.path = path
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { throw ServerError.socketCreateFailed(errno) }
        self.listenFd = fd

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        if bytes.count >= capacity {
            Darwin.close(fd)
            throw ServerError.pathTooLong
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            for (i, b) in bytes.enumerated() {
                dst[i] = b
            }
            dst[bytes.count] = 0
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, addrLen)
            }
        }
        if bindResult < 0 {
            Darwin.close(fd)
            throw ServerError.bindFailed(errno)
        }
        if Darwin.listen(fd, 1) < 0 {
            Darwin.close(fd)
            throw ServerError.listenFailed(errno)
        }
        let flags = fcntl(fd, F_GETFL)
        if flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0 {
            Darwin.close(fd)
            throw ServerError.listenFailed(errno)
        }

        let (instream, incont) = AsyncStream<InboundMessage>.makeStream()
        self.inbound = instream
        self.inboundContinuation = incont
        let (closeStream, closeContinuation) = AsyncStream<Void>.makeStream()
        self.clientClose = closeStream
        self.clientCloseContinuation = closeContinuation

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        self.acceptSource = source
        source.setEventHandler { [weak self] in
            self?.acceptAndRead()
        }
        source.setCancelHandler { [inboundContinuation, listenFd, path] in
            Darwin.close(listenFd)
            unlink(path)
            inboundContinuation.finish()
        }
        // Blocking socket calls stay off Swift's cooperative executor.
        source.activate()
    }

    func send(_ type: WireMessageType, payload: Data) {
        sendRaw(Data.framed(type, payload: payload))
    }

    func sendRaw(_ data: Data) {
        let fd = socketState.withLock { state -> Int32 in
            guard !state.isClosed, state.connectionFD >= 0 else { return -1 }
            sendGroup.enter()
            return state.connectionFD
        }
        guard fd >= 0 else { return }
        defer { sendGroup.leave() }
        data.withUnsafeBytes { buf in
            _ = Darwin.send(fd, buf.baseAddress, buf.count, 0)
        }
    }

    func waitForConnection(timeout: TimeInterval = 5.0) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let fd = socketState.withLock { $0.connectionFD }
            if fd >= 0 { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func finishSending() -> Bool {
        let fd = socketState.withLock { state -> Int32 in
            guard !state.isClosed else { return -1 }
            return state.connectionFD
        }
        guard fd >= 0 else { return false }
        return shutdown(fd, SHUT_WR) == 0
    }

    func waitForClientClose(timeout: TimeInterval = 2.0) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { [clientClose] in
                for await _ in clientClose { return true }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    func firstInbound(matching type: WireMessageType,
                       timeout: TimeInterval = 2.0) async -> InboundMessage? {
        await withTaskGroup(of: InboundMessage?.self) { group in
            group.addTask { [inbound] in
                for await msg in inbound {
                    if msg.type == type { return msg }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    func close() {
        let shouldCancel = socketState.withLock { state -> Bool in
            guard !state.isClosed else { return false }
            state.isClosed = true
            if state.connectionFD >= 0 { shutdown(state.connectionFD, SHUT_RDWR) }
            return true
        }
        guard shouldCancel else { return }
        acceptSource.cancel()
    }

    private func acceptAndRead() {
        let connectionFD = accept(listenFd, nil, nil)
        guard connectionFD >= 0 else { return }
        let flags = fcntl(connectionFD, F_GETFL)
        if flags >= 0 { _ = fcntl(connectionFD, F_SETFL, flags & ~O_NONBLOCK) }
        var noSigPipe: Int32 = 1
        setsockopt(
            connectionFD,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )
        acceptSource.cancel()
        let published = socketState.withLock { state in
            guard !state.isClosed else { return false }
            state.connectionFD = connectionFD
            return true
        }
        guard published else {
            shutdown(connectionFD, SHUT_RDWR)
            Darwin.close(connectionFD)
            return
        }
        readLoop(fd: connectionFD)
        clientCloseContinuation.yield()
        clientCloseContinuation.finish()
        let ownsConnection = socketState.withLock { state in
            guard state.connectionFD == connectionFD else { return false }
            state.isClosed = true
            state.connectionFD = -1
            shutdown(connectionFD, SHUT_RDWR)
            return true
        }
        guard ownsConnection else { return }
        sendGroup.wait()
        Darwin.close(connectionFD)
    }

    private func readLoop(fd: Int32) {
        while true {
            guard let header = readExactly(fd: fd, count: 8) else { return }
            let length: UInt32 = header.readLE(at: 0)
            let typeRaw: UInt32 = header.readLE(at: 4)
            let payloadLength = Int(length) - 4
            guard payloadLength >= 0 else { return }
            let payload: Data
            if payloadLength == 0 {
                payload = Data()
            } else {
                guard let p = readExactly(fd: fd, count: payloadLength) else { return }
                payload = p
            }
            guard let type = WireMessageType(rawValue: typeRaw) else { continue }
            inboundContinuation.yield(InboundMessage(type: type, payload: payload))
        }
    }

    private func readExactly(fd: Int32, count: Int) -> Data? {
        var buf = Data(count: count)
        var read = 0
        while read < count {
            let n: Int = buf.withUnsafeMutableBytes { ptr in
                guard let base = ptr.baseAddress else { return -1 }
                return recv(fd, base.advanced(by: read), count - read, 0)
            }
            if n <= 0 { return nil }
            read += n
        }
        return buf
    }
}
