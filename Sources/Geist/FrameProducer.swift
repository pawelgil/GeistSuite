import AVFoundation
import CoreMedia
import CoreVideo

public protocol VideoFrameProducer: AnyObject, Sendable {
    var declaredFormat: VideoSlotFormat { get }
    func start(into sink: any VideoFrameSink) throws
    func stop()
    func reformat(to target: VideoSlotFormat)
}

extension VideoFrameProducer {
    public func reformat(to target: VideoSlotFormat) {}
}

public protocol VideoFrameSink: AnyObject, Sendable {
    func sendVideo(_ pixelBuffer: CVPixelBuffer, pts: CMTime, duration: CMTime)
}

public protocol AudioFrameProducer: AnyObject, Sendable {
    var declaredFormat: AudioSlotFormat { get }
    func start(into sink: any AudioFrameSink) throws
    func stop()
}

public protocol AudioFrameSink: AnyObject, Sendable {
    func sendAudio(_ samples: AVAudioPCMBuffer, pts: CMTime)
}
