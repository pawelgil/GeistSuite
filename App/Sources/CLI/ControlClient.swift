import Darwin
import Foundation

enum ControlClient {
    static func roundTrip(_ request: ControlRequest) throws -> ControlResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CLIError.daemonUnreachable }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = ControlSocket.path
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < cap else { throw CLIError.daemonUnreachable }
        _ = path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dstPtr in
                dstPtr.withMemoryRebound(to: CChar.self, capacity: cap) { dst in
                    strlcpy(dst, src, cap)
                }
            }
        }

        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectResult = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, len)
            }
        }
        guard connectResult == 0 else { throw CLIError.daemonUnreachable }

        var payload = try JSONEncoder().encode(request)
        payload.append(UInt8(ascii: "\n"))
        payload.withUnsafeBytes { raw in
            var ptr = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            var remaining = payload.count
            while remaining > 0 {
                let n = write(fd, ptr, remaining)
                if n < 0 {
                    if errno == EINTR { continue }
                    return
                }
                ptr = ptr.advanced(by: n)
                remaining -= n
            }
        }

        var responseBytes = Data()
        var byte: UInt8 = 0
        while responseBytes.count < 64 * 1024 {
            let n = read(fd, &byte, 1)
            if n == 0 { break }
            if n < 0 {
                if errno == EINTR { continue }
                throw CLIError.daemonUnreachable
            }
            if byte == UInt8(ascii: "\n") { break }
            responseBytes.append(byte)
        }
        guard !responseBytes.isEmpty else { throw CLIError.daemonUnreachable }
        return try JSONDecoder().decode(ControlResponse.self, from: responseBytes)
    }
}

enum CLIError: Error, CustomStringConvertible {
    case daemonUnreachable
    case usage(String)
    case unknownSource(String)
    case unknownSide(String)
    case unknownCommand(String)

    var description: String {
        switch self {
        case .daemonUnreachable:
            return "GeistLens is not running. Open GeistLens.app and try again."
        case .usage(let msg): return msg
        case .unknownSource(let s): return "unknown source '\(s)'. Use camera[:uid], video:<path>, or image:<path>."
        case .unknownSide(let s): return "unknown side '\(s)'. Use back or front."
        case .unknownCommand(let s): return "unknown command '\(s)'. Run 'geistlens help'."
        }
    }
}
