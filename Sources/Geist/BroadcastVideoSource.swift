import CoreMedia
import CoreVideo
import Foundation

public enum BroadcastVideoSource: Sendable {
    case simulatorScreen
    case custom(any VideoFrameProducer)
}
