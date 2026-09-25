import Darwin
import Foundation
@testable import GeistBroadcast
import Synchronization
import Testing

struct UnixSocketListenerTests {
    @Test(arguments: [EAGAIN, EWOULDBLOCK])
    func `accept error listener drained returns drained`(error: Int32) {
        #expect(UnixSocketListener.acceptErrorAction(errno: error) == .drained)
    }

    @Test func `accept error interrupted returns retry`() {
        #expect(UnixSocketListener.acceptErrorAction(errno: EINTR) == .retry)
    }

    @Test func `accept error permanent failure returns fail`() {
        #expect(UnixSocketListener.acceptErrorAction(errno: EBADF) == .fail)
    }

    @Test func `listener stop before activation removes only its socket`() throws {
        let path = socketPath()
        let sut = try createSUT(path: path)

        sut.stop()
        sut.activate()
        sut.stop()

        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(throws: ListenerTestError.connect(ENOENT)) { try connect(to: path) }
    }

    @Test func `listener stop after path replacement preserves replacement`() throws {
        let path = socketPath()
        let original = try createSUT(path: path)
        let replacement = try createSUT(path: path)
        defer { replacement.stop() }

        original.stop()

        #expect(FileManager.default.fileExists(atPath: path))
        let peer = try connect(to: path)
        close(peer)
    }

    @Test func `listener deinit without activation removes socket`() throws {
        let path = socketPath()
        var sut: UnixSocketListener? = try createSUT(path: path)
        #expect(sut != nil)

        sut = nil

        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func `listener invalid path reports bind failure`() {
        #expect(throws: UnixSocketListener.Error.bind(errno: ENAMETOOLONG)) {
            try createSUT(path: "/tmp/" + String(repeating: "x", count: 110))
        }
    }

    @Test func `listener occupied directory preserves directory`() throws {
        let path = socketPath()
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(throws: UnixSocketListener.Error.bind(errno: EADDRINUSE)) {
            try createSUT(path: path)
        }

        var directory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: path, isDirectory: &directory))
        #expect(directory.boolValue)
    }

    @Test(.timeLimit(.minutes(1)))
    func `listener accept transfers blocking signal safe socket`() async throws {
        let path = socketPath()
        let accepted = AsyncStream<Int32>.makeStream()
        let sut = try createSUT(path: path, onAccept: { accepted.continuation.yield($0) })
        sut.activate()
        let peer = try connect(to: path)
        defer { close(peer); sut.stop() }
        var iterator = accepted.stream.makeAsyncIterator()

        let fd = try #require(await iterator.next())
        defer { close(fd) }
        sut.stop()

        #expect(fcntl(fd, F_GETFL) & O_NONBLOCK == 0)
        var noSigPipe: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        #expect(getsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, &size) == 0)
        #expect(noSigPipe == 1)
        #expect(write(peer, [UInt8(42)], 1) == 1)
        #expect(try await readBytes(from: fd, count: 1) == Data([42]))
    }

    @Test(.timeLimit(.minutes(1)))
    func `listener stop during accept callback does not report failure`() async throws {
        let entered = AsyncSignal()
        let completed = AsyncSignal()
        let release = DispatchSemaphore(value: 0)
        let failures = Mutex(0)
        let path = socketPath()
        let sut = try UnixSocketListener(path: path, backlog: 8, onAccept: { fd in
            entered.fire()
            release.wait()
            close(fd)
            completed.fire()
        }, onFailure: { failures.withLock { $0 += 1 } })
        sut.activate()
        let peer = try connect(to: path)
        defer { close(peer) }
        await entered.wait()

        sut.stop()
        sut.activate()
        release.signal()
        await completed.wait()

        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(failures.withLock { $0 } == 0)
    }

    private func createSUT(
        path: String, onAccept: @escaping @Sendable (Int32) -> Void = { close($0) },
    ) throws -> UnixSocketListener {
        try UnixSocketListener(path: path, backlog: 8, onAccept: onAccept, onFailure: {})
    }

    private func socketPath() -> String {
        "/tmp/listener-\(UUID().uuidString).sock"
    }

    private func connect(to path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ListenerTestError.socket(errno) }
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
            throw ListenerTestError.connect(error)
        }
        return fd
    }
}

private enum ListenerTestError: Error, Equatable {
    case socket(Int32)
    case connect(Int32)
}
