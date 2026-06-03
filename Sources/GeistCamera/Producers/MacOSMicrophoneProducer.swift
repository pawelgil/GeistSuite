import Accelerate
import AVFoundation
import CoreAudio
import CoreMedia
import Dispatch
import Foundation
import Synchronization
import GeistKit

// Force-resampled to 48 kHz mono float32 PCM. Host must request mic access
// before attaching (start throws otherwise).
public final class MacOSMicrophoneProducer: AudioFrameProducer, Sendable {
    public let declaredFormat = AudioSlotFormat(sampleRate: 48000, channels: 1)

    private let core: MicrophoneCore

    public init(_ spec: MacOSMicrophoneDevice = .default) async throws {
        self.core = try await MicrophoneCore(spec)
    }

    public func start(into sink: any AudioFrameSink) throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        guard status == .authorized else {
            throw MacOSMicrophoneError.permissionNotGranted(status)
        }
        let core = self.core
        Task { @CameraActor in core.start(into: sink) }
    }

    public func stop() {
        let core = self.core
        Task { @CameraActor in core.stop() }
    }
}

public enum MacOSMicrophoneError: Error, CustomStringConvertible {
    case noMicrophoneAvailable
    case deviceNotFound(String)
    case sessionInputRejected
    case sessionOutputRejected
    case permissionNotGranted(AVAuthorizationStatus)

    public var description: String {
        switch self {
        case .noMicrophoneAvailable:
            return "No macOS microphone available"
        case .deviceNotFound(let uid):
            return "Audio AVCaptureDevice with uniqueID '\(uid)' not found"
        case .sessionInputRejected:
            return "AVCaptureSession refused the microphone input"
        case .sessionOutputRejected:
            return "AVCaptureSession refused the audio data output"
        case .permissionNotGranted(let status):
            return "Microphone permission is \(status) — call AVCaptureDevice.requestAccess(for: .audio) before attaching, and ensure your host app's Info.plist has NSMicrophoneUsageDescription"
        }
    }
}

@CameraActor
private final class MicrophoneCore {
    private let spec: MacOSMicrophoneDevice
    private let delegate = AudioSinkDelegate()
    private var session: AVCaptureSession?
    private var running = false

    init(_ spec: MacOSMicrophoneDevice) throws {
        self.spec = spec
        try rebuildSession()
        if case .default = spec {
            DefaultInputDeviceObserver.shared.subscribe(self)
        }
    }

    nonisolated deinit {
        DefaultInputDeviceObserver.shared.unsubscribe(self)
    }

    func start(into sink: any AudioFrameSink) {
        delegate.setSink(sink)
        if running { return }
        running = true
        session?.startRunning()
    }

    func stop() {
        running = false
        session?.stopRunning()
        delegate.setSink(nil)
    }

    fileprivate func handleDefaultDeviceChanged() {
        do {
            try rebuildSession()
        } catch {
            Log.warn("MacOSMicrophone: rebuild on default-device change failed: \(error)")
        }
    }

    private func rebuildSession() throws {
        let device: AVCaptureDevice
        switch spec {
        case .default:
            guard let d = AVCaptureDevice.default(for: .audio) else {
                throw MacOSMicrophoneError.noMicrophoneAvailable
            }
            device = d
        case .uniqueID(let uid):
            guard let d = AVCaptureDevice(uniqueID: uid) else {
                throw MacOSMicrophoneError.deviceNotFound(uid)
            }
            device = d
        }

        let newSession = AVCaptureSession()
        newSession.beginConfiguration()
        let input = try AVCaptureDeviceInput(device: device)
        guard newSession.canAddInput(input) else {
            newSession.commitConfiguration()
            throw MacOSMicrophoneError.sessionInputRejected
        }
        newSession.addInput(input)

        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        guard newSession.canAddOutput(output) else {
            newSession.commitConfiguration()
            throw MacOSMicrophoneError.sessionOutputRejected
        }
        newSession.addOutput(output)
        newSession.commitConfiguration()
        output.setSampleBufferDelegate(delegate, queue: CameraActor.shared.serialQueue)

        session?.stopRunning()
        session = newSession
        if running { newSession.startRunning() }
        Log.notice("MacOSMicrophone: bound to '\(device.localizedName)' (uid=\(device.uniqueID))")
    }
}

// One process-wide listener fans default-input-device changes out to all live
// MicrophoneCore instances. Cores hold weak entries — so dead cores are
// cleaned up lazily on the next change, no explicit teardown needed.
private final class DefaultInputDeviceObserver: @unchecked Sendable {
    static let shared = DefaultInputDeviceObserver()

    private let lock = NSLock()
    private var subscribers: [ObjectIdentifier: WeakCore] = [:]
    private var installed = false

    private struct WeakCore { weak var value: MicrophoneCore? }

    private init() {}

    func subscribe(_ core: MicrophoneCore) {
        lock.lock()
        subscribers[ObjectIdentifier(core)] = WeakCore(value: core)
        let needsInstall = !installed
        if needsInstall { installed = true }
        lock.unlock()
        if needsInstall { installListener() }
    }

    func unsubscribe(_ core: MicrophoneCore) {
        lock.lock()
        subscribers.removeValue(forKey: ObjectIdentifier(core))
        lock.unlock()
    }

    fileprivate func dispatch() {
        lock.lock()
        let cores = subscribers.values.compactMap { $0.value }
        subscribers = subscribers.filter { $0.value.value != nil }
        lock.unlock()
        for core in cores {
            Task { @CameraActor in core.handleDefaultDeviceChanged() }
        }
    }

    private func installListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            defaultInputDeviceChangedCallback,
            nil
        )
        if status != noErr {
            Log.warn("MacOSMicrophone: AudioObjectAddPropertyListener failed (\(status))")
        }
    }
}

private func defaultInputDeviceChangedCallback(
    objectID: AudioObjectID,
    numAddresses: UInt32,
    addresses: UnsafePointer<AudioObjectPropertyAddress>,
    clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    DefaultInputDeviceObserver.shared.dispatch()
    return noErr
}

private final class AudioSinkDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, Sendable {
    private let state = Mutex<State>(State())

    private struct State {
        var sink: (any AudioFrameSink)?
        // Rebuilt lazily on the first buffer (and on any subsequent
        // sample-rate change) using the actual buffer format, so the
        // attack/release coefficients track reality rather than what
        // we asked AVCaptureAudioDataOutput for.
        var agc: VoiceAGC?
    }

    func setSink(_ value: (any AudioFrameSink)?) {
        state.withLock { s in
            s.sink = value
            s.agc = nil
        }
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pcm = Self.audioPCMBuffer(from: sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let snapshot = state.withLock { s -> (any AudioFrameSink)? in
            guard let sink = s.sink else { return nil }
            let bufferSR = Float(pcm.format.sampleRate)
            if s.agc?.sampleRate != bufferSR {
                s.agc = VoiceAGC(sampleRate: bufferSR)
            }
            if let dst = pcm.floatChannelData?[0] {
                s.agc?.process(samples: dst, count: Int(pcm.frameLength))
            }
            return sink
        }
        snapshot?.sendAudio(pcm, pts: pts)
    }

    private static func audioPCMBuffer(from sb: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sb),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return nil
        }
        var asbd = asbdPtr.pointee
        guard let avFormat = AVAudioFormat(streamDescription: &asbd) else { return nil }

        let frames = CMSampleBufferGetNumSamples(sb)
        guard frames > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: AVAudioFrameCount(frames)) else {
            return nil
        }
        pcm.frameLength = AVAudioFrameCount(frames)

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sb) else { return nil }
        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(blockBuffer,
                                                  atOffset: 0,
                                                  lengthAtOffsetOut: &lengthAtOffset,
                                                  totalLengthOut: &totalLength,
                                                  dataPointerOut: &dataPointer)
        guard status == noErr, let dataPointer, let dst = pcm.floatChannelData?[0] else {
            return nil
        }
        memcpy(dst, dataPointer, totalLength)
        return pcm
    }
}

// Peak-following AGC + limiter sized for voice input.
//
// AVCaptureAudioDataOutput delivers the raw HAL signal — no AGC, no
// noise suppression, ≈30 dB quieter than FaceTime/QuickTime which use
// VoiceProcessingIO. We can't programmatically opt into Voice Isolation
// on macOS (it's user-controlled in System Settings), so this DSP step
// brings loudness into the expected range adaptively: quiet rooms get
// boosted, loud bursts get held back, and a hard ceiling prevents
// clipping at the output.
//
// Design:
//   - Per-buffer peak measurement via vDSP_maxmgv.
//   - Two-pole envelope with separate attack (5 ms) and release (200 ms)
//     time constants so transients are caught quickly but the gain
//     doesn't pump on every word boundary.
//   - Gain target: peak → ≈-3 dBFS (0.7 linear).
//   - Gain bounds: [0.5, 8.0] linear (≈ -6 dB .. +18 dB). The lower
//     bound stops digital silence from being amplified into pure noise.
//   - Final limiter clamps to ±0.99 to keep a hair of headroom.
private struct VoiceAGC {
    let sampleRate: Float
    private let targetPeak: Float = 0.7
    private let attackCoef: Float
    private let releaseCoef: Float
    private let minGain: Float = 0.5
    private let maxGain: Float = 8.0
    private let envelopeFloor: Float = 0.005  // -46 dBFS gate

    private var envelope: Float = 0
    private var gain: Float = 1.0

    init(sampleRate: Float) {
        self.sampleRate = sampleRate
        self.attackCoef = exp(-1.0 / (0.005 * sampleRate))
        self.releaseCoef = exp(-1.0 / (0.200 * sampleRate))
    }

    mutating func process(samples: UnsafeMutablePointer<Float>, count: Int) {
        guard count > 0 else { return }
        let n = vDSP_Length(count)

        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, n)

        let coef = peak > envelope ? attackCoef : releaseCoef
        envelope = coef * envelope + (1.0 - coef) * peak

        let workingEnv = max(envelope, envelopeFloor)
        let targetGain = targetPeak / workingEnv
        let clampedTarget = min(max(targetGain, minGain), maxGain)

        // Smooth the gain across buffers so the boost doesn't step.
        gain = 0.85 * gain + 0.15 * clampedTarget

        var g = gain
        vDSP_vsmul(samples, 1, &g, samples, 1, n)

        var lo: Float = -0.99
        var hi: Float = 0.99
        vDSP_vclip(samples, 1, &lo, &hi, samples, 1, n)
    }
}
