import CoreVideo
import Foundation
import SimulatorScreenCapture
import Synchronization

final class SimulatorScreenFrameSource: ScreenFrameCapturing {
    // MARK: Properties

    private let capture = Mutex<SimulatorScreenCapture?>(nil)
    private let setPath: String?
    private let simulator: UUID

    // MARK: Lifecycle

    init(simulator: UUID, setPath: String?) {
        self.simulator = simulator
        self.setPath = setPath
    }

    // MARK: Functions

    func start(delivering handler: @escaping @Sendable (CVPixelBuffer) -> Void) throws {
        let activeCapture = try SimulatorScreenCapture(udid: simulator, setPath: setPath)
        try activeCapture.start { frame in handler(frame.pixelBuffer) }
        capture.withLock { $0 = activeCapture }
    }

    func stop() {
        capture.withLock { activeCapture in
            activeCapture?.stop()
            activeCapture = nil
        }
    }
}
