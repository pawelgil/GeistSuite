import Darwin
import Foundation
import GeistCamera

final class ControlServer: @unchecked Sendable {
    private let handler: ControlHandler
    private var listenFd: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "geistlens.control")

    init(handler: ControlHandler) {
        self.handler = handler
    }

    func start() throws {
        let path = ControlSocket.path
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlServerError.socketFailed(errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < cap else {
            close(fd)
            throw ControlServerError.pathTooLong(path)
        }
        _ = path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dstPtr in
                dstPtr.withMemoryRebound(to: CChar.self, capacity: cap) { dst in
                    strlcpy(dst, src, cap)
                }
            }
        }

        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, len)
            }
        }
        guard bindResult == 0 else {
            let e = errno
            close(fd)
            throw ControlServerError.bindFailed(e)
        }

        chmod(path, 0o600)

        guard listen(fd, 16) == 0 else {
            let e = errno
            close(fd)
            throw ControlServerError.listenFailed(e)
        }

        listenFd = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptConnections(on: fd) }
        src.setCancelHandler { close(fd) }
        acceptSource = src
        src.resume()

        Log.notice("ControlServer: listening at \(path)")
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        listenFd = -1
        try? FileManager.default.removeItem(atPath: ControlSocket.path)
    }

    private func acceptConnections(on fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                return
            }
            serveConnection(fd: client)
        }
    }

    private func serveConnection(fd: Int32) {
        let handler = self.handler
        Task.detached {
            defer { close(fd) }
            do {
                let requestData = try ControlSocketIO.readLine(fd: fd)
                let request = try JSONDecoder().decode(ControlRequest.self, from: requestData)
                let response = await handler.handle(request)
                let payload = try JSONEncoder().encode(response)
                ControlSocketIO.writeLine(fd: fd, payload: payload)
            } catch {
                Log.warn("ControlServer: request failed: \(error)")
                let err = ControlResponse.error(.init(message: "\(error)"))
                if let payload = try? JSONEncoder().encode(err) {
                    ControlSocketIO.writeLine(fd: fd, payload: payload)
                }
            }
        }
    }
}

enum ControlServerError: Error, CustomStringConvertible {
    case socketFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
    case pathTooLong(String)

    var description: String {
        switch self {
        case .socketFailed(let e): return "socket() failed: errno=\(e)"
        case .bindFailed(let e): return "bind() failed: errno=\(e) (\(String(cString: strerror(e))))"
        case .listenFailed(let e): return "listen() failed: errno=\(e)"
        case .pathTooLong(let p): return "control socket path exceeds sun_path: \(p)"
        }
    }
}

enum ControlSocketIO {
    static func readLine(fd: Int32) throws -> Data {
        var buffer = Data()
        var byte: UInt8 = 0
        while buffer.count < 64 * 1024 {
            let n = read(fd, &byte, 1)
            if n == 0 { break }
            if n < 0 {
                if errno == EINTR { continue }
                throw ControlIOError.readFailed(errno)
            }
            if byte == UInt8(ascii: "\n") { break }
            buffer.append(byte)
        }
        return buffer
    }

    static func writeLine(fd: Int32, payload: Data) {
        var data = payload
        data.append(UInt8(ascii: "\n"))
        data.withUnsafeBytes { raw in
            var ptr = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            var remaining = data.count
            while remaining > 0 {
                let written = write(fd, ptr, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    return
                }
                ptr = ptr.advanced(by: written)
                remaining -= written
            }
        }
    }
}

enum ControlIOError: Error {
    case readFailed(Int32)
}
