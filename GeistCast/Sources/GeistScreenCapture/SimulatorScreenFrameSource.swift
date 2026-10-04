import CoreMedia
import CoreVideo
import Foundation
import SimulatorScreenCapture
import Synchronization

final class SimulatorScreenFrameSource: ScreenFrameCapturing {
    private let capture = Mutex<SimulatorScreenCapture?>(nil)
    private let setPath: String?
    private let simulator: UUID

    init(simulator: UUID, setPath: String?) {
        self.simulator = simulator
        self.setPath = setPath
    }

    func start(delivering handler: @escaping @Sendable (CVPixelBuffer, CMTime) -> Void) throws {
        let activeCapture = try SimulatorScreenCapture(udid: simulator, setPath: setPath)
        try activeCapture.start { frame in handler(frame.pixelBuffer, CMClockGetTime(CMClockGetHostTimeClock())) }
        capture.withLock { $0 = activeCapture }
    }

    func stop() {
        capture.withLock { activeCapture in
            activeCapture?.stop()
            activeCapture = nil
        }
    }
}
