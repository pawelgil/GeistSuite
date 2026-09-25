import AVFoundation
import Foundation

final class BroadcastMediaSources {
    // MARK: Properties

    private let simulator: String
    private let simctlSetPath: String?
    private let videoCapture: VideoCaptureConfig
    private var micAudio: MicAudioConfig
    private let sink: any BroadcastSink
    private var videoSource: (any BroadcastSource)?
    private var micSource: (any BroadcastSource)?

    // MARK: Computed Properties

    var isMicAttached: Bool {
        micSource != nil
    }

    var isMacOSMicAuthorized: Bool {
        switch micAudio {
        case .systemMicrophone:
            AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .custom, .mediaFile:
            true
        case .disabled:
            false
        }
    }

    var isMicEnabledByDefault: Bool {
        switch micAudio {
        case .custom, .mediaFile:
            true
        case .disabled, .systemMicrophone:
            false
        }
    }

    // MARK: Lifecycle

    init(
        simulator: String, simctlSetPath: String?, videoCapture: VideoCaptureConfig,
        micAudio: MicAudioConfig, sink: any BroadcastSink,
    ) {
        self.simulator = simulator
        self.simctlSetPath = simctlSetPath
        self.videoCapture = videoCapture
        self.micAudio = micAudio
        self.sink = sink
    }

    // MARK: Functions

    func startVideo() {
        guard videoSource == nil, let source = makeVideoSource() else { return }
        do {
            try source.start(into: sink)
            videoSource = source
        } catch {
            log.warn("Session: video source start failed: \(error)")
        }
    }

    func stopVideo() {
        videoSource?.stop()
        videoSource = nil
    }

    func setMicEnabled(_ enabled: Bool) {
        if enabled { attachMicSource() }
        else { detachMicSource() }
    }

    func stopAll() {
        stopVideo()
        detachMicSource()
    }

    func setMicAudio(_ config: MicAudioConfig) {
        micAudio = config
    }

    private func makeVideoSource() -> (any BroadcastSource)? {
        switch videoCapture {
        case .simulatorScreen:
            guard let udid = UUID(uuidString: simulator) else {
                log.warn("Session: simulator '\(simulator)' is not a valid UUID; skipping simulator-screen capture")
                return nil
            }
            do {
                return try SimulatorScreenBroadcastSource(udid: udid, simctlSetPath: simctlSetPath)
            } catch {
                log.warn("Session: simulator-screen capture init failed: \(error)")
                return nil
            }
        case let .custom(producer):
            return CustomVideoBroadcastSource(producer)
        }
    }

    private func attachMicSource() {
        guard micSource == nil else { return }
        let source: (any BroadcastSource)? = switch micAudio {
        case .systemMicrophone: SystemMicrophoneBroadcastSource()
        case let .mediaFile(url): MediaFileMicAudioSource(url: url)
        case let .custom(producer): CustomMicAudioBroadcastSource(producer)
        case .disabled: nil
        }
        guard let source else { return }
        do {
            try source.start(into: sink)
            micSource = source
        } catch {
            log.warn("Session: mic source attach failed: \(error)")
        }
    }

    private func detachMicSource() {
        micSource?.stop()
        micSource = nil
    }
}
