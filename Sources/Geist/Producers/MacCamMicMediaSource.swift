import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Synchronization

/// MediaSource for a Mac camera + microphone pair sharing one AVCaptureSession
/// (and therefore one master clock). Builds on the SharedMacOSCameraSource
/// pool so multiple consumers of the same physical camera (e.g. both back and
/// front slots set to the mac cam) share a single session.
public final class MacCamMicMediaSource: MediaSource, @unchecked Sendable {
    public let hasVideo: Bool = true
    public let hasAudio: Bool
    public let features: MediaSourceFeatures = [.allowsFrontMirror]
    public var declaredVideoFormat: VideoSlotFormat? { sharedFormatSnapshot }
    public var declaredAudioFormat: AudioSlotFormat? {
        hasAudio ? AudioSlotFormat(sampleRate: 48000, channels: 1) : nil
    }

    private let camDevice: MacOSCameraDevice
    private let sharedFormatSnapshot: VideoSlotFormat
    private let activeSink = Mutex<(any MediaSink)?>(nil)
    private let videoSubID = Mutex<ObjectIdentifier?>(nil)
    private let audioSubID = Mutex<ObjectIdentifier?>(nil)
    private let videoBridge = Mutex<VideoBridge?>(nil)
    private let audioBridge = Mutex<AudioBridge?>(nil)

    /// Constructs the MediaSource. Requires both camera and microphone
    /// permissions to be authorized at this point — AVF cannot recover from
    /// `.notDetermined` mid-session.
    public init(camDevice: MacOSCameraDevice = .default, includeMic: Bool = true) async throws {
        self.camDevice = camDevice
        self.hasAudio = includeMic
        let shared = try await SharedMacOSCameraSource.sharedSession(for: camDevice)
        self.sharedFormatSnapshot = shared.declaredFormat
    }

    public func start(into sink: any MediaSink) throws {
        let camStatus = AVCaptureDevice.authorizationStatus(for: .video)
        guard camStatus == .authorized else {
            throw MacOSCameraError.permissionNotGranted(camStatus)
        }
        if hasAudio {
            let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            guard micStatus == .authorized else {
                throw MacOSCameraError.micPermissionNotGranted(micStatus)
            }
        }
        activeSink.withLock { $0 = sink }

        let video = VideoBridge(sink: sink)
        videoBridge.withLock { $0 = video }
        let vid = ObjectIdentifier(video)
        videoSubID.withLock { $0 = vid }

        let audio = hasAudio ? AudioBridge(sink: sink) : nil
        if let audio { audioBridge.withLock { $0 = audio } }
        let aid = audio.map { ObjectIdentifier($0) }
        if let aid { audioSubID.withLock { $0 = aid } }

        let camDevice = self.camDevice
        let hasAudio = self.hasAudio
        Task { @CameraActor in
            do {
                let shared = try await SharedMacOSCameraSource.sharedSession(for: camDevice)
                shared.add(video, id: vid)
                if hasAudio, let audio, let aid {
                    try shared.addAudioSubscriber(audio, id: aid)
                }
            } catch {
                Log.warn("MacCamMicMediaSource start failed: \(error)")
            }
        }
    }

    public func stop() {
        let vid = videoSubID.withLock { id -> ObjectIdentifier? in let r = id; id = nil; return r }
        let aid = audioSubID.withLock { id -> ObjectIdentifier? in let r = id; id = nil; return r }
        videoBridge.withLock { $0 = nil }
        audioBridge.withLock { $0 = nil }
        activeSink.withLock { $0 = nil }
        let camDevice = self.camDevice
        Task { @CameraActor in
            do {
                let shared = try await SharedMacOSCameraSource.sharedSession(for: camDevice)
                if let vid { shared.remove(id: vid) }
                if let aid { shared.removeAudioSubscriber(id: aid) }
            } catch {
                Log.warn("MacCamMicMediaSource stop: pool lookup failed: \(error)")
            }
        }
    }
}

private final class VideoBridge: VideoFrameSink, @unchecked Sendable {
    private let sink: any MediaSink
    init(sink: any MediaSink) { self.sink = sink }
    func sendVideo(_ pixelBuffer: CVPixelBuffer, pts: CMTime, duration: CMTime) {
        sink.sendVideo(pixelBuffer, pts: pts, duration: duration)
    }
}

private final class AudioBridge: SharedSessionAudioSubscriber, @unchecked Sendable {
    private let sink: any MediaSink
    init(sink: any MediaSink) { self.sink = sink }
    func receiveAudio(_ pcm: AVAudioPCMBuffer, pts: CMTime) {
        sink.sendAudio(pcm, pts: pts)
    }
}
