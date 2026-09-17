import Darwin
import Foundation
import Synchronization
import GeistKit

final class SocketClient: Sendable, FrameTransport {
    protocol FrameWriting: Sendable {
        func writeFrame(fd: Int32, frame: Data) -> Bool
    }

    private final class IOState: Sendable {
        struct SocketState {
            var buffer = OutboundFrameBuffer()
            var drainScheduled = false
            var fd: Int32 = -1
            var isClosed = false
        }

        let group = DispatchGroup()
        let socket = Mutex(SocketState())
        let writeQueue = DispatchQueue(label: "com.geist.camera.socket-write")
    }

    private struct SystemFrameWriter: FrameWriting {
        func writeFrame(fd: Int32, frame: Data) -> Bool {
            SocketClient.writeAll(fd: fd, frame: frame)
        }
    }

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
    private let frameWriter: any FrameWriting
    private let ioState = IOState()
    private let readQueue = DispatchQueue(label: "com.geist.camera.socket-read")

    let inbound: AsyncStream<InboundMessage>
    private let inboundContinuation: AsyncStream<InboundMessage>.Continuation

    convenience init(path: String) {
        self.init(path: path, frameWriter: SystemFrameWriter())
    }

    init(path: String, frameWriter: any FrameWriting) {
        self.path = path
        self.frameWriter = frameWriter
        let (instream, incont) = AsyncStream<InboundMessage>.makeStream()
        self.inbound = instream
        self.inboundContinuation = incont
    }

    deinit {
        close()
    }

    // Shim binds asynchronously after dlopen, so we connect-with-retry.
    func connect(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? attemptConnect()) == true {
                log.notice("connected to shim at \(self.path)")
                startReadLoop()
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
        var noSigPipe: Int32 = 1
        setsockopt(
            sock,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )
        return ioState.socket.withLock { state in
            guard !state.isClosed else {
                shutdown(sock, SHUT_RDWR)
                Darwin.close(sock)
                return false
            }
            state.fd = sock
            return true
        }
    }

    private func startReadLoop() {
        let ioState = self.ioState
        let sock = ioState.socket.withLock { state -> Int32 in
            guard !state.isClosed, state.fd >= 0 else { return -1 }
            ioState.group.enter()
            return state.fd
        }
        guard sock >= 0 else { return }
        let cont = self.inboundContinuation
        let p = self.path
        // Blocking socket calls stay off Swift's cooperative executor.
        readQueue.async {
            defer { ioState.group.leave() }
            Self.runReadLoop(fd: sock, continuation: cont, path: p)
        }
    }

    private static func runReadLoop(fd: Int32, continuation: AsyncStream<InboundMessage>.Continuation, path: String) {
        while true {
            var lengthBytes = Data(count: 4)
            if !readExact(fd: fd, into: &lengthBytes, count: 4) { break }
            let length: UInt32 = lengthBytes.readLE(at: 0)
            if length < 4 || length > 64 * 1024 * 1024 {
                log.warn("bad inbound length \(length); dropping")
                break
            }
            var payload = Data(count: Int(length))
            if !readExact(fd: fd, into: &payload, count: Int(length)) { break }

            let typeRaw: UInt32 = payload.readLE(at: 0)
            guard let type = WireMessageType(rawValue: typeRaw) else {
                log.warn("unknown inbound message type \(typeRaw)")
                continue
            }
            let body = payload.subdata(in: 4..<payload.count)
            continuation.yield(InboundMessage(type: type, payload: body))
        }
        continuation.finish()
        log.notice("read loop ended for \(path)")
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

    private static func writeAll(fd: Int32, frame: Data) -> Bool {
        frame.withUnsafeBytes { rawPtr -> Bool in
            guard let base = rawPtr.baseAddress else { return true }
            var sent = 0
            while sent < frame.count {
                let w = Darwin.send(fd, base.advanced(by: sent), frame.count - sent, 0)
                if w <= 0 {
                    if w < 0 && errno == EINTR { continue }
                    return false
                }
                sent += w
            }
            return true
        }
    }

    func send(_ frame: OutboundFrame) -> FrameAdmission {
        let result = ioState.socket.withLock { state -> (FrameAdmission, Int32?) in
            guard !state.isClosed, state.fd >= 0 else {
                return (.rejected(.unavailable), nil)
            }
            let admission = state.buffer.enqueue(frame)
            if admission == .rejected(.capacity) {
                let expectedFD = state.fd
                let fd = Self.beginClose(state: &state, expectedFD: expectedFD)
                return (admission, fd)
            }
            guard admission == .accepted, !state.drainScheduled else {
                return (admission, nil)
            }
            state.drainScheduled = true
            ioState.group.enter()
            return (admission, state.fd)
        }
        guard let fd = result.1 else { return result.0 }
        if result.0 == .rejected(.capacity) {
            Self.finishClose(
                fd: fd,
                ioState: ioState,
                readQueue: readQueue,
                inboundContinuation: inboundContinuation
            )
        } else {
            scheduleDrain(fd: fd)
        }
        return result.0
    }

    func close() {
        guard let fd = ioState.socket.withLock({ state in
            Self.beginClose(state: &state, expectedFD: nil)
        }) else { return }
        Self.finishClose(
            fd: fd,
            ioState: ioState,
            readQueue: readQueue,
            inboundContinuation: inboundContinuation
        )
    }

    private static func beginClose(
        state: inout IOState.SocketState,
        expectedFD: Int32?
    ) -> Int32? {
        guard !state.isClosed else { return nil }
        if let expectedFD, state.fd != expectedFD { return nil }
        state.isClosed = true
        let fd = state.fd
        state.fd = -1
        state.buffer.removeAll()
        return fd
    }

    private static func drain(
        fd: Int32,
        frameWriter: any FrameWriting,
        ioState: IOState,
        readQueue: DispatchQueue,
        inboundContinuation: AsyncStream<InboundMessage>.Continuation
    ) {
        while let frame = nextFrame(fd: fd, ioState: ioState) {
            guard frameWriter.writeFrame(fd: fd, frame: frame.encoded) else {
                guard let closingFD = ioState.socket.withLock({ state in
                    beginClose(state: &state, expectedFD: fd)
                }) else { return }
                finishClose(
                    fd: closingFD,
                    ioState: ioState,
                    readQueue: readQueue,
                    inboundContinuation: inboundContinuation
                )
                return
            }
        }
    }

    private static func finishClose(
        fd: Int32,
        ioState: IOState,
        readQueue: DispatchQueue,
        inboundContinuation: AsyncStream<InboundMessage>.Continuation
    ) {
        if fd >= 0 { shutdown(fd, SHUT_RDWR) }
        ioState.group.notify(queue: readQueue) {
            if fd >= 0 { Darwin.close(fd) }
            inboundContinuation.finish()
        }
    }

    private static func nextFrame(fd: Int32, ioState: IOState) -> OutboundFrame? {
        ioState.socket.withLock { state in
            guard !state.isClosed, state.fd == fd else {
                state.drainScheduled = false
                return nil
            }
            guard let frame = state.buffer.popFirst() else {
                state.drainScheduled = false
                return nil
            }
            return frame
        }
    }

    private func scheduleDrain(fd: Int32) {
        let ioState = self.ioState
        let frameWriter = self.frameWriter
        let readQueue = self.readQueue
        let inboundContinuation = self.inboundContinuation
        ioState.writeQueue.async {
            defer { ioState.group.leave() }
            Self.drain(
                fd: fd,
                frameWriter: frameWriter,
                ioState: ioState,
                readQueue: readQueue,
                inboundContinuation: inboundContinuation
            )
        }
    }
}
