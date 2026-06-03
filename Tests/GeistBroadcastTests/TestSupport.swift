import CoreMedia
import CoreVideo
import Foundation
import Darwin
@testable import GeistBroadcast

/// One-shot signal. After `fire()` is called once, all current AND future
/// waiters return immediately. Use this when a test wants to know an event
/// has happened *at least once* — typical for "this broadcast started" or
/// "this spawner was called."
final class AsyncSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var fired = false

    func fire() {
        let toResume: [CheckedContinuation<Void, Never>] = lock.withLock {
            guard !fired else { return [] }
            fired = true
            defer { continuations.removeAll() }
            return continuations
        }
        for cont in toResume { cont.resume() }
    }

    func wait() async {
        await withCheckedContinuation { cont in
            let resumeImmediately: Bool = lock.withLock {
                if fired { return true }
                continuations.append(cont)
                return false
            }
            if resumeImmediately { cont.resume() }
        }
    }
}

enum SocketReadError: Error, Equatable {
    case timeout
    case closed
    case errno(Int32)
}

private func makeTimeval(seconds: Double) -> timeval {
    let whole = Int(seconds)
    let micros = Int32((seconds - Double(whole)) * 1_000_000)
    return timeval(tv_sec: whole, tv_usec: micros)
}

// The socket helpers below use a generous default kernel timeout so that
// CPU contention from parallel test scheduling (Swift Testing runs suites
// concurrently by default) cannot cause spurious .timeout errors. The
// timeout is an upper bound only — passing tests still return the moment
// the SUT writes the expected bytes; only genuinely-stuck SUTs hit it.
private let defaultSocketTimeoutSeconds: Double = 10

func readWireMessage(from fd: Int32, timeoutSeconds: Double = defaultSocketTimeoutSeconds) async throws -> WireMessage {
    return try await Task.detached(priority: .userInitiated) {
        var tv = makeTimeval(seconds: timeoutSeconds)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var decoder = WireDecoder()
        var byte: UInt8 = 0
        while true {
            let n = withUnsafeMutablePointer(to: &byte) { ptr in
                Darwin.read(fd, ptr, 1)
            }
            if n > 0 {
                let messages = decoder.feed(Data([byte]))
                if let first = messages.first { return first }
                continue
            }
            if n == 0 { throw SocketReadError.closed }
            let err = errno
            if err == EAGAIN || err == EWOULDBLOCK { throw SocketReadError.timeout }
            throw SocketReadError.errno(err)
        }
    }.value
}

func readBytes(from fd: Int32, count: Int, timeoutSeconds: Double = defaultSocketTimeoutSeconds) async throws -> Data {
    return try await Task.detached(priority: .userInitiated) {
        var tv = makeTimeval(seconds: timeoutSeconds)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var data = Data(count: count)
        var off = 0
        while off < count {
            let n = data.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                return Darwin.read(fd, base.advanced(by: off), count - off)
            }
            if n > 0 { off += n; continue }
            if n == 0 { throw SocketReadError.closed }
            let err = errno
            if err == EAGAIN || err == EWOULDBLOCK { throw SocketReadError.timeout }
            throw SocketReadError.errno(err)
        }
        return data
    }.value
}
