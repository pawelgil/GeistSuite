import Darwin
import Foundation

final class CaptureConnection: Sendable {
    let descriptor: Int32

    init(_ descriptor: Int32) {
        self.descriptor = descriptor
        var enabled: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
    }

    deinit {
        Darwin.close(descriptor)
    }

    func shutdown() {
        Darwin.shutdown(descriptor, SHUT_RDWR)
    }

    var isDisconnected: Bool {
        var byte: UInt8 = 0
        let result = recv(descriptor, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        return result == 0 || result < 0 && ![EAGAIN, EWOULDBLOCK, EINTR].contains(errno)
    }

    func read(count: Int, timeout: Int = 2) -> Data? {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout) * 1_000_000_000
        var data = Data(count: count)
        let succeeded = data.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return count == 0 }
            var offset = 0
            while offset < count {
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else { return false }
                let result = Darwin.read(descriptor, base.advanced(by: offset), count - offset)
                if result > 0 {
                    offset += result
                } else if result < 0, errno == EINTR {
                    continue
                } else if result < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    guard waitForInput(timeout: Int32(max(1, (deadline - now) / 1_000_000))) else { return false }
                } else {
                    return false
                }
            }
            return true
        }
        return succeeded ? data : nil
    }

    func waitForDisconnect() {
        var byte: UInt8 = 0
        while true {
            let count = Darwin.read(descriptor, &byte, 1)
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                if waitForInput(timeout: -1) { continue }
            }
            return
        }
    }

    private func waitForInput(timeout: Int32) -> Bool {
        var pending = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let result = poll(&pending, 1, timeout)
        return result > 0 || result < 0 && errno == EINTR
    }

    func write(_ data: Data) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return true }
            var offset = 0
            let deadline = DispatchTime.now().uptimeNanoseconds + 500_000_000
            while offset < bytes.count {
                guard DispatchTime.now().uptimeNanoseconds < deadline else { return false }
                let count = send(descriptor, base.advanced(by: offset), bytes.count - offset, MSG_DONTWAIT)
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    let now = DispatchTime.now().uptimeNanoseconds
                    guard now < deadline else { return false }
                    var pending = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                    let remaining = Int32(max(1, (deadline - now) / 1_000_000))
                    let result = poll(&pending, 1, remaining)
                    if result < 0, errno == EINTR { continue }
                    guard result > 0, pending.revents & Int16(POLLOUT) != 0 else { return false }
                } else {
                    return false
                }
            }
            return true
        }
    }
}
