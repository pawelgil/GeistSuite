import CoreMedia
import CoreVideo
import Foundation

/// PTS clock is arbitrary; the extension only uses relative ordering.
public protocol VideoFrameProducer: AnyObject, Sendable {
    func start(producing handler: @escaping @Sendable (CVPixelBuffer, CMTime) -> Void) throws
    func stop()
}

public enum VideoCaptureConfig: Sendable {
    case simulatorScreen
    case custom(any VideoFrameProducer)
}
