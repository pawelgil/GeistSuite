import AVFoundation
import CoreMedia
import Foundation

public protocol MicAudioProducer: AnyObject, Sendable {
    func start(producing handler: @escaping @Sendable (AVAudioPCMBuffer, CMTime) -> Void) throws
    func stop()
}

/// `.disabled` overrides the picker's mic toggle — mic audio never ships.
public enum MicAudioConfig: Sendable {
    case systemMicrophone
    case mediaFile(URL)
    case custom(any MicAudioProducer)
    case disabled
}
