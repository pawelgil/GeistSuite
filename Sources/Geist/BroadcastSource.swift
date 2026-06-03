import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

// A source owns its own pacing (wall-clock, hardware callback, file PTS)
// and pushes samples to the sink at real-ReplayKit rates.
protocol BroadcastSource: AnyObject, Sendable {
    func start(into sink: any BroadcastSink) throws
    func stop()
}

protocol BroadcastSink: AnyObject, Sendable {
    func sendVideo(_ pixelBuffer: CVPixelBuffer)
    func sendMicAudio(_ samples: AVAudioPCMBuffer)
}
