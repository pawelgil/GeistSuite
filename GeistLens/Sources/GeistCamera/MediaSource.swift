import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// A producer of a synchronized audio + video stream from a single backing
/// timeline. Both media types share one clock, one anchor PTS, and (where
/// possible) one underlying reader/session — guaranteeing per-source A/V sync
/// by construction.
///
/// Use this in preference to attaching `VideoFrameProducer` / `AudioFrameProducer`
/// separately when both halves need to stay locked in phase (file playback,
/// camera + mic capture). Mic-only or video-only consumers can keep using the
/// per-medium producer protocols.
public protocol MediaSource: AnyObject, Sendable {
    var hasVideo: Bool { get }
    var hasAudio: Bool { get }
    var declaredVideoFormat: VideoSlotFormat? { get }
    var declaredAudioFormat: AudioSlotFormat? { get }
    var features: MediaSourceFeatures { get }

    func start(into sink: any MediaSink) throws
    func stop()
    func reformat(to target: VideoSlotFormat)
}

public extension MediaSource {
    func reformat(to target: VideoSlotFormat) {}
    var features: MediaSourceFeatures { [] }
}

/// Opt-in behaviors a `MediaSource` advertises about its output. The shim
/// reads these to decide which iOS-side conventions (front-camera mirror,
/// rotation, etc.) apply to this source's frames.
public struct MediaSourceFeatures: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    /// The iOS front-camera mirror convention applies — when this source is
    /// attached to a front-facing slot and the app's connection enables
    /// `isVideoMirrored`, the shim flips the buffer horizontally. Sources
    /// emitting recorded content (mp4, image, pattern) omit this and the
    /// shim leaves their pixels untouched regardless of connection state.
    public static let allowsFrontMirror = MediaSourceFeatures(rawValue: 1 << 0)
}

/// Single sink object that a `MediaSource` emits both video and audio into.
/// Implementations are typically a fan-out wrapper around the lib's per-slot
/// sinks.
public protocol MediaSink: AnyObject, Sendable {
    func sendVideo(_ pixelBuffer: CVPixelBuffer, pts: CMTime, duration: CMTime)
    func sendAudio(_ samples: AVAudioPCMBuffer, pts: CMTime)
}

/// Internal sink wrapper that forwards video / audio calls to optional per-slot
/// sinks. `nil` legs silently drop — used when only one half of a source's
/// output is routed (e.g. file-source video used but its audio not chosen as
/// the session microphone).
final class FanoutMediaSink: MediaSink, @unchecked Sendable {
    private let lock = NSLock()
    private var videoSink: (any VideoFrameSink)?
    private var audioSink: (any AudioFrameSink)?

    init(video: (any VideoFrameSink)? = nil, audio: (any AudioFrameSink)? = nil) {
        self.videoSink = video
        self.audioSink = audio
    }

    func setVideoSink(_ sink: (any VideoFrameSink)?) {
        lock.lock(); defer { lock.unlock() }
        videoSink = sink
    }

    func setAudioSink(_ sink: (any AudioFrameSink)?) {
        lock.lock(); defer { lock.unlock() }
        audioSink = sink
    }

    func sendVideo(_ pixelBuffer: CVPixelBuffer, pts: CMTime, duration: CMTime) {
        lock.lock()
        let sink = videoSink
        lock.unlock()
        sink?.sendVideo(pixelBuffer, pts: pts, duration: duration)
    }

    func sendAudio(_ samples: AVAudioPCMBuffer, pts: CMTime) {
        lock.lock()
        let sink = audioSink
        lock.unlock()
        sink?.sendAudio(samples, pts: pts)
    }
}
