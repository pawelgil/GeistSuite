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
    private let listenFd: Int32
    private let path: String
    private let connFd = Mutex<Int32>(-1)
    private let inboundContinuation: AsyncStream<InboundMessage>.Continuation
    let inbound: AsyncStream<InboundMessage>
    private let acceptTask = Mutex<Task<Void, Never>?>(nil)
    private let readTask = Mutex<Task<Void, Never>?>(nil)

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
        let id = UUID().uuidString.prefix(8)
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("geistcam-test-\(id).sock")
        return try TestFeederServer(path: path)
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

        let (instream, incont) = AsyncStream<InboundMessage>.makeStream()
        self.inbound = instream
        self.inboundContinuation = incont

        let task = Task { [weak self] in
            guard let self else { return }
            let conn = accept(self.listenFd, nil, nil)
            if conn < 0 { return }
            self.connFd.withLock { $0 = conn }
            self.readTask.withLock {
                $0 = Task { await self.readLoop(fd: conn) }
            }
        }
        acceptTask.withLock { $0 = task }
    }

    func send(_ type: WireMessageType, payload: Data) {
        let fd = connFd.withLock { $0 }
        guard fd >= 0 else { return }
        let framed = Data.framed(type, payload: payload)
        framed.withUnsafeBytes { buf in
            _ = Darwin.send(fd, buf.baseAddress, buf.count, 0)
        }
    }

    func waitForConnection(timeout: TimeInterval = 5.0) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let fd = connFd.withLock { $0 }
            if fd >= 0 { return }
            try? await Task.sleep(for: .milliseconds(20))
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
        let conn = connFd.withLock { cur -> Int32 in
            let v = cur
            cur = -1
            return v
        }
        if conn >= 0 { Darwin.close(conn) }
        Darwin.close(listenFd)
        unlink(path)
        acceptTask.withLock { $0?.cancel(); $0 = nil }
        readTask.withLock { $0?.cancel(); $0 = nil }
        inboundContinuation.finish()
    }

    private func readLoop(fd: Int32) async {
        while !Task.isCancelled {
            guard let header = await readExactly(fd: fd, count: 8) else { return }
            let length: UInt32 = header.readLE(at: 0)
            let typeRaw: UInt32 = header.readLE(at: 4)
            let payloadLength = Int(length) - 4
            guard payloadLength >= 0 else { return }
            let payload: Data
            if payloadLength == 0 {
                payload = Data()
            } else {
                guard let p = await readExactly(fd: fd, count: payloadLength) else { return }
                payload = p
            }
            guard let type = WireMessageType(rawValue: typeRaw) else { continue }
            inboundContinuation.yield(InboundMessage(type: type, payload: payload))
        }
    }

    private func readExactly(fd: Int32, count: Int) async -> Data? {
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
