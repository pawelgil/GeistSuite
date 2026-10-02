import Darwin
import Foundation
@testable import GeistScreenCapture
import Synchronization
import Testing

struct SocketFrameWriterTests {
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
        sut.bind(sockets[0])

        sut.write(expected)
        sut.close()

        #expect(finished.wait(timeout: .now() + 2) == .success)
        #expect(received.withLock { $0 } == expected)
    }
}
