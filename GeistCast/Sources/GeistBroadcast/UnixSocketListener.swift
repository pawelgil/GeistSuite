import Darwin
import Foundation
import Synchronization

final class UnixSocketListener: Sendable {
    // MARK: Nested Types

    enum Error: Swift.Error, Equatable {
        case socketCreate(errno: Int32)
        case bind(errno: Int32)
        case listen(errno: Int32)
    }

    enum AcceptErrorAction { case drained, fail, retry }

    private struct PathIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private enum Phase { case prepared, active, stopped }

    private struct State {
        let source: any DispatchSourceRead
        var phase = Phase.prepared
    }

    // MARK: Properties

    private let fd: Int32
    private let path: String
    private let identity: PathIdentity
    private let onAccept: @Sendable (Int32) -> Void
    private let onFailure: @Sendable () -> Void
    private let state: Mutex<State>

    // MARK: Lifecycle

    init(
        path: String,
        backlog: Int32,
        onAccept: @escaping @Sendable (Int32) -> Void,
        onFailure: @escaping @Sendable () -> Void,
    ) throws {
        let socket = try Self.open(path: path, backlog: backlog)
        fd = socket.fd
        self.path = path
        identity = socket.identity
        self.onAccept = onAccept
        self.onFailure = onFailure
        let queue = DispatchQueue(label: "com.geist.broadcast.accept.\(socket.fd)")
        let source = DispatchSource.makeReadSource(fileDescriptor: socket.fd, queue: queue)
        state = Mutex(State(source: source))
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(socket.fd) }
    }

    deinit { stop() }

    // MARK: Static Functions

    static func acceptErrorAction(errno: Int32) -> AcceptErrorAction {
        if errno == EINTR { return .retry }
        if errno == EAGAIN || errno == EWOULDBLOCK { return .drained }
        return .fail
    }

    private static func configureClient(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    }

    private static func open(path: String, backlog: Int32) throws -> (fd: Int32, identity: PathIdentity) {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Error.socketCreate(errno: errno) }
        do {
            try bind(fd, to: path)
            guard let identity = pathIdentity(path) else { throw Error.bind(errno: errno) }
            do {
                try listen(fd, backlog: backlog)
                return (fd, identity)
            } catch {
                unlinkOwnedPath(path, identity: identity)
                throw error
            }
        } catch {
            close(fd)
            throw error
        }
    }

    private static func bind(_ fd: Int32, to path: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { throw Error.bind(errno: ENAMETOOLONG) }
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                path.withCString { source in strlcpy(destination, source, capacity) }
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw Error.bind(errno: errno) }
    }

    private static func listen(_ fd: Int32, backlog: Int32) throws {
        guard Darwin.listen(fd, backlog) == 0 else { throw Error.listen(errno: errno) }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw Error.listen(errno: errno)
        }
    }

    private static func pathIdentity(_ path: String) -> PathIdentity? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return PathIdentity(device: info.st_dev, inode: info.st_ino)
    }

    private static func unlinkOwnedPath(_ path: String, identity: PathIdentity) {
        if pathIdentity(path) == identity { unlink(path) }
    }

    // MARK: Functions

    func activate() {
        state.withLock { state in
            guard state.phase == .prepared else { return }
            state.phase = .active
            state.source.activate()
        }
    }

    func stop() {
        state.withLock { stop(&$0) }
    }

    private func stop(_ state: inout State) {
        guard state.phase != .stopped else { return }
        Self.unlinkOwnedPath(path, identity: identity)
        state.source.cancel()
        if state.phase == .prepared { state.source.activate() }
        state.phase = .stopped
    }

    private func acceptPending() {
        while state.withLock({ $0.phase == .active }) {
            let clientFD = accept(fd, nil, nil)
            guard clientFD >= 0 else {
                switch Self.acceptErrorAction(errno: errno) {
                case .retry: continue
                case .drained: return
                case .fail:
                    fail()
                    return
                }
            }
            Self.configureClient(clientFD)
            onAccept(clientFD)
        }
    }

    private func fail() {
        let failed = state.withLock { state in
            guard state.phase == .active else { return false }
            stop(&state)
            return true
        }
        if failed { onFailure() }
    }
}
