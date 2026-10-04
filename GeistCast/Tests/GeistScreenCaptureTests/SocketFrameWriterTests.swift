import Darwin
import Foundation
@testable import GeistScreenCapture
import Synchronization
import Testing

struct SocketFrameWriterTests {
    @Test
    func write_UnresponsiveClient_DisconnectsWithinDeadline() throws {
        var sockets: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
        defer { Darwin.close(sockets[1]) }
        let sut = SocketFrameWriter()
        sut.bind(CaptureConnection(sockets[0]))
        let start = ContinuousClock.now

        sut.write(Data(repeating: 0xA5, count: 8 * 1024 * 1024))

        #expect(start.duration(to: .now) < .seconds(1))
        var bytes = [UInt8](repeating: 0, count: 16384)
        var count = 0
        repeat { count = Darwin.read(sockets[1], &bytes, bytes.count) } while count > 0
        #expect(count == 0)
    }

    @Test
    func write_DisconnectedClient_DoesNotRaiseSIGPIPE() throws {
        var sockets: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
        let sut = SocketFrameWriter()
        sut.bind(CaptureConnection(sockets[0]))
        Darwin.close(sockets[1])

        sut.write(Data([1]))
        sut.close()
    }

    @Test
    func write_LargePayloadWithBackpressure_DeliversCompleteData() {
        var sockets: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
        var sendBufferSize: Int32 = 4096
        setsockopt(
            sockets[0],
            SOL_SOCKET,
            SO_SNDBUF,
            &sendBufferSize,
            socklen_t(MemoryLayout<Int32>.size)
        )
        let expected = Data(repeating: 0xA5, count: 1_048_576)
        let received = Mutex(Data())
        let finished = DispatchSemaphore(value: 0)
        let readSocket = sockets[1]
        DispatchQueue.global().async {
            var chunk = Data(count: 16384)
            while true {
                let count = chunk.withUnsafeMutableBytes {
                    Darwin.read(readSocket, $0.baseAddress, $0.count)
                }
                guard count > 0 else { break }
                received.withLock { $0.append(chunk.prefix(count)) }
            }
            Darwin.close(readSocket)
            finished.signal()
        }
        let sut = SocketFrameWriter()
        sut.bind(CaptureConnection(sockets[0]))

        sut.write(expected)
        sut.close()

        #expect(finished.wait(timeout: .now() + 2) == .success)
        #expect(received.withLock { $0 } == expected)
    }
}
