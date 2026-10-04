import Darwin
import Foundation

// The source is immutable after initialization; Dispatch serializes its handlers and cancellation.
final class CaptureListener: @unchecked Sendable {
    private let source: DispatchSourceRead
    private let path: String
    private let identity: SocketIdentity

    init(path: String, accepting handler: @escaping @Sendable (CaptureConnection) -> Void) throws {
        let descriptor = try Self.open(path: path)
        self.path = path
        guard let identity = SocketIdentity(path: path) else {
            Darwin.close(descriptor)
            throw GeistScreenCaptureSession.Error.bind(errno: ENOENT)
        }
        self.identity = identity
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor,
            queue: DispatchQueue(label: "com.geist.screencapture.accept"))
        source.setEventHandler {
            let client = Darwin.accept(descriptor, nil, nil)
            if client >= 0 { handler(CaptureConnection(client)) }
        }
        // Closing in the cancellation handler keeps in-flight accept calls off reused descriptors.
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
        self.source = source
    }

    deinit { stop() }

    func stop() {
        source.cancel()
        if SocketIdentity(path: path) == identity { unlink(path) }
    }

    private static func open(path: String) throws -> Int32 {
        typealias Error = GeistScreenCaptureSession.Error
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Error.socketCreate(errno: errno) }
        do {
            guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0,
                  fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else { throw Error.socketCreate(errno: errno) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
                throw Error.bind(errno: ENAMETOOLONG)
            }
            withUnsafeMutableBytes(of: &address.sun_path) { bytes in
                path.utf8CString.withUnsafeBytes { bytes.copyBytes(from: $0) }
            }
            try withUnsafePointer(to: &address) { pointer in
                try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    let length = socklen_t(MemoryLayout<sockaddr_un>.size)
                    if Darwin.bind(descriptor, address, length) != 0 {
                        guard errno == EADDRINUSE,
                              removeStaleSocket(path: path, address: address, length: length),
                              Darwin.bind(descriptor, address, length) == 0 else {
                            throw Error.bind(errno: errno)
                        }
                    }
                }
            }
            guard chmod(path, S_IRUSR | S_IWUSR) == 0 else {
                let code = errno
                unlink(path)
                throw Error.bind(errno: code)
            }
            guard Darwin.listen(descriptor, 16) == 0 else {
                let code = errno
                unlink(path)
                throw Error.listen(errno: code)
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func removeStaleSocket(path: String, address: UnsafePointer<sockaddr>, length: socklen_t) -> Bool {
        guard let identity = SocketIdentity(path: path) else { return false }
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { return false }
        defer { Darwin.close(probe) }
        guard fcntl(probe, F_SETFL, O_NONBLOCK) == 0,
              Darwin.connect(probe, address, length) != 0, errno == ECONNREFUSED,
              SocketIdentity(path: path) == identity else { return false }
        return unlink(path) == 0
    }
}

private struct SocketIdentity: Equatable {
    let device: dev_t
    let inode: ino_t

    init?(path: String) {
        var metadata = stat()
        guard lstat(path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFSOCK,
              metadata.st_uid == geteuid() else { return nil }
        device = metadata.st_dev
        inode = metadata.st_ino
    }
}
