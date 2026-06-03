import AVFoundation
import CoreMedia
import Foundation

/// `.disabled` overrides the picker's mic toggle — mic audio never ships.
public enum MicSource: Sendable {
    case systemMicrophone
    case mediaFile(URL)
    case custom(any AudioFrameProducer)
    case disabled
}
