import Foundation

// Single-medium attach cases for `session.attach(_:to:)`. For paired A/V with
// guaranteed sync (mp4 files, mac cam + mic), use `MediaSource` types via
// `session.attachMediaSource(_:video:audio:)`.
public enum GeistCamSource: Sendable {
    case stillImage(URL, fps: Int = 30)
    case macOSCamera(MacOSCameraDevice = .default)
    case macOSMicrophone(MacOSMicrophoneDevice = .default)
    case customVideo(any VideoFrameProducer)
    case customAudio(any AudioFrameProducer)
}

public enum MacOSCameraDevice: Sendable {
    case `default`
    case uniqueID(String)
}

public enum MacOSMicrophoneDevice: Sendable {
    case `default`
    case uniqueID(String)
}
