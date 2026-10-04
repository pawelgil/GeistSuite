import Foundation
import Synchronization

final class SocketFrameWriter: CaptureFrameWriting, Sendable {
    private let connection = Mutex<CaptureConnection?>(nil)

    @discardableResult
    func bind(_ client: CaptureConnection, initialData: Data = Data()) -> Bool {
        connection.withLock { current in
            current?.shutdown()
            current = nil
            guard client.write(initialData) else { return false }
            current = client
            return true
        }
    }

    func write(_ data: Data) {
        connection.withLock { current in
            guard let client = current, !client.write(data) else { return }
            client.shutdown()
            current = nil
        }
    }

    func close() {
        connection.withLock { current in
            current?.shutdown()
            current = nil
        }
    }
}
