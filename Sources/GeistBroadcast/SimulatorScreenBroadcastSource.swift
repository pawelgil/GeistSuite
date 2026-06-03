import CoreMedia
import CoreVideo
import Foundation
import SimulatorScreenCapture

final class SimulatorScreenBroadcastSource: BroadcastSource {
    private let capture: SimulatorScreenCapture

    init(udid: UUID, simctlSetPath: String? = nil) throws {
        self.capture = try SimulatorScreenCapture(udid: udid, setPath: simctlSetPath)
    }

    func start(into sink: any BroadcastSink) throws {
        try capture.start { [sink] frame in
            sink.sendVideo(frame.pixelBuffer)
        }
    }

    func stop() {
        capture.stop()
    }
}
