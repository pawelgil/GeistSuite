import Darwin
import Foundation
import Synchronization

final class SocketFrameWriter: CaptureFrameWriting, Sendable {
    // MARK: Properties

    private let descriptor = Mutex<Int32?>(nil)

    // MARK: Static Functions

    private static func close(_ fd: Int32) {
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }

    private static func writeAll(_ fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return true }
            var offset = 0
            let deadline = DispatchTime.now().uptimeNanoseconds + 500_000_000
            while offset < bytes.count {
                let count = Darwin.send(
                    fd,
                    base.advanced(by: offset),
                    bytes.count - offset,
                    MSG_DONTWAIT
                )
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    let now = DispatchTime.now().uptimeNanoseconds
                    guard now < deadline else { return false }
                    var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    let remaining = Int32(max(1, (deadline - now) / 1_000_000))
                    guard Darwin.poll(&descriptor, 1, remaining) > 0 else { return false }
                } else {
                    return false
                }
            }
            return true
        }
    }

    // MARK: Functions

    func bind(_ fd: Int32) {
        descriptor.withLock { current in
            if let current { Self.close(current) }
            current = fd
        }
    }

    func write(_ data: Data) {
        descriptor.withLock { fd in
            guard let current = fd else { return }
            guard Self.writeAll(current, data: data) else {
                Self.close(current)
                fd = nil
                return
            }
        }
    }

    func close() {
        descriptor.withLock { fd in
            if let current = fd { Self.close(current) }
            fd = nil
        }
    }
}
