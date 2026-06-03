import Darwin
import Foundation
import Synchronization

final class SocketClient: Sendable, FrameTransport {
    enum ConnectError: Error {
        case socketCreateFailed(Int32)
        case connectTimeout
        case pathTooLong
    }

    struct InboundMessage: Sendable {
        let type: WireMessageType
        let payload: Data
    }

    private nonisolated let path: String
    private let fd = Atomic<Int32>(-1)
    private let readTask = Mutex<Task<Void, Never>?>(nil)
    private let writerTask = Mutex<Task<Void, Never>?>(nil)

    let inbound: AsyncStream<InboundMessage>
    private let inboundContinuation: AsyncStream<InboundMessage>.Continuation

    // Drop frames on shim stall rather than growing memory unboundedly.
    // 4 frames ≈ 130ms at 30 fps; long enough to absorb jitter, short enough
    // to keep memory bounded under sustained back-pressure.
    private let writeStream: AsyncStream<Data>
    private let writeContinuation: AsyncStream<Data>.Continuation

    init(path: String) {
        self.path = path
        let (instream, incont) = AsyncStream<InboundMessage>.makeStream()
        self.inbound = instream
        self.inboundContinuation = incont
        let (wstream, wcont) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(4))
        self.writeStream = wstream
        self.writeContinuation = wcont
    }

    // Shim binds asynchronously after dlopen, so we connect-with-retry.
    func connect(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? attemptConnect()) == true {
                Log.notice("connected to shim at \(self.path)")
                startReadLoop()
                startWriter()
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw ConnectError.connectTimeout
    }

    private func attemptConnect() throws -> Bool {
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        if sock < 0 { throw ConnectError.socketCreateFailed(errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        if pathBytes.count >= maxLen {
            Darwin.close(sock)
            throw ConnectError.pathTooLong
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            for (i, b) in pathBytes.enumerated() {
                dst[i] = b
            }
            dst[pathBytes.count] = 0
        }

        let rv = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(sock, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rv < 0 {
            Darwin.close(sock)
            return false
        }
        fd.store(sock, ordering: .relaxed)
        return true
    }

    private func startReadLoop() {
        let sock = fd.load(ordering: .relaxed)
        let cont = self.inboundContinuation
        let p = self.path
        let task = Task.detached(priority: .userInitiated) {
            Self.runReadLoop(fd: sock, continuation: cont, path: p)
        }
        readTask.withLock { $0 = task }
    }

    private static func runReadLoop(fd: Int32, continuation: AsyncStream<InboundMessage>.Continuation, path: String) {
        while !Task.isCancelled {
            var lengthBytes = Data(count: 4)
            if !readExact(fd: fd, into: &lengthBytes, count: 4) { break }
            let length: UInt32 = lengthBytes.readLE(at: 0)
            if length < 4 || length > 64 * 1024 * 1024 {
                Log.warn("bad inbound length \(length); dropping")
                break
            }
            var payload = Data(count: Int(length))
            if !readExact(fd: fd, into: &payload, count: Int(length)) { break }

            let typeRaw: UInt32 = payload.readLE(at: 0)
            guard let type = WireMessageType(rawValue: typeRaw) else {
                Log.warn("unknown inbound message type \(typeRaw)")
                continue
            }
            let body = payload.subdata(in: 4..<payload.count)
            continuation.yield(InboundMessage(type: type, payload: body))
        }
        continuation.finish()
        Log.notice("read loop ended for \(path)")
    }

    private static func readExact(fd: Int32, into buf: inout Data, count: Int) -> Bool {
        var read = 0
        return buf.withUnsafeMutableBytes { rawPtr -> Bool in
            guard let base = rawPtr.baseAddress else { return false }
            while read < count {
                let r = recv(fd, base.advanced(by: read), count - read, 0)
                if r <= 0 {
                    if r < 0 && errno == EINTR { continue }
                    return false
                }
                read += r
            }
            return true
        }
    }

    private func startWriter() {
        let sock = fd.load(ordering: .relaxed)
        let stream = self.writeStream
        let task = Task.detached(priority: .userInitiated) {
            for await frame in stream {
                Self.writeAll(fd: sock, frame: frame)
            }
        }
        writerTask.withLock { $0 = task }
    }

    private static func writeAll(fd: Int32, frame: Data) {
        frame.withUnsafeBytes { rawPtr in
            guard let base = rawPtr.baseAddress else { return }
            var sent = 0
            while sent < frame.count {
                let w = Darwin.send(fd, base.advanced(by: sent), frame.count - sent, 0)
                if w <= 0 {
                    if w < 0 && errno == EINTR { continue }
                    return
                }
                sent += w
            }
        }
    }

    func send(_ frame: Data) {
        writeContinuation.yield(frame)
    }

    func close() {
        let oldFd = fd.exchange(-1, ordering: .relaxed)
        writeContinuation.finish()
        inboundContinuation.finish()
        readTask.withLock { $0?.cancel(); $0 = nil }
        writerTask.withLock { $0?.cancel(); $0 = nil }
        if oldFd >= 0 { Darwin.close(oldFd) }
    }
}
