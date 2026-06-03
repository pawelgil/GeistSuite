import Accelerate
import AVFoundation
import CoreAudio
import CoreMedia
import Foundation
import Synchronization

// Captures from the macOS default audio input via AVCaptureSession.
//
// We previously used AVAudioEngine here. That worked for the built-in
// mic but silently produced zero buffers when AirPods (or any other
// Bluetooth input) became the default — AVAudioEngine's input AudioUnit
// caches the bound device at init time and Apple's aggregate-device
// machinery doesn't always include hot-plugged Bluetooth inputs. The
// AVCaptureSession path with an explicit `AVCaptureDeviceInput` resolves
// the current default each time the session is built and survives the
// device shuffles. It's also what AVFoundation documents as the right
// API for audio capture on macOS.
//
// AVCaptureSession also pins to whatever AVCaptureDeviceInput we add at
// start time — so a mid-broadcast input switch (built-in → AirPods or
// the reverse) wouldn't carry over by default. We listen for the system
// default-input-device change via CoreAudio HAL and tear down + rebuild
// the session on the fly. The AGC adapts inside the same delegate.
//
// Output is force-resampled to 48 kHz mono Float32 PCM, then passed
// through a peak-following AGC/limiter so loudness lands in the same
// ballpark as FaceTime/QuickTime instead of the raw ~-30 dBFS level
// AVCaptureAudioDataOutput produces with no processing. See `VoiceAGC`
// below for the details.
final class SystemMicrophoneBroadcastSource: BroadcastSource, @unchecked Sendable {
    private let delegate = AudioSinkDelegate()
    private let queue = DispatchQueue(label: "com.geistcast.systemmic")
    private let state = Mutex(SessionState())

    private struct SessionState {
        var session: AVCaptureSession?
        var sink: (any BroadcastSink)?
        var listenerInstalled = false
    }

    init() {}

    // Defensive: if a future caller drops the source without invoking
    // stop(), the HAL would still hold an Unmanaged(passUnretained)
    // pointer to a deallocated `self` and the next default-input change
    // would fire the C callback with a dangling pointer (use-after-free).
    // Every call site today nils the source right after stop() so this
    // never executes, but the safety net is cheap.
    deinit {
        removeDefaultInputListener()
    }

    func start(into sink: any BroadcastSink) throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw MicError.permissionNotGranted
        }
        delegate.bind(sink: sink)
        try state.withLock { (s: inout SessionState) in
            s.sink = sink
            try Self.buildSession(into: &s, delegate: delegate, queue: queue)
        }
        installDefaultInputListener()
        Log.notice("SystemMic session started")
    }

    func stop() {
        removeDefaultInputListener()
        let snapshot = delegate.unbind()
        state.withLock { s in
            s.session?.stopRunning()
            s.session = nil
            s.sink = nil
        }
        Log.notice("SystemMic stop: buffers=\(snapshot.buffers) samples=\(snapshot.samples)")
    }

    // MARK: - Session lifecycle

    private static func buildSession(into s: inout SessionState,
                                     delegate: AudioSinkDelegate,
                                     queue: DispatchQueue) throws {
        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw MicError.noMicrophoneAvailable
        }
        Log.notice("SystemMic device='\(device.localizedName)' uid=\(device.uniqueID)")

        let session = AVCaptureSession()
        session.beginConfiguration()
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw MicError.sessionInputRejected
        }
        session.addInput(input)

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
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw MicError.sessionOutputRejected
        }
        session.addOutput(output)
        session.commitConfiguration()
        output.setSampleBufferDelegate(delegate, queue: queue)

        s.session?.stopRunning()
        s.session = session
        session.startRunning()
    }

    fileprivate func handleDefaultDeviceChanged() {
        queue.async { [weak self] in
            guard let self else { return }
            self.state.withLock { (s: inout SessionState) in
                guard s.sink != nil else { return } // already stopped
                do {
                    try Self.buildSession(into: &s, delegate: self.delegate, queue: self.queue)
                    Log.notice("SystemMic rebuilt session for new default input")
                } catch {
                    Log.warn("SystemMic rebuild on default-device change failed: \(error)")
                }
            }
        }
    }

    // MARK: - HAL listener

    private func installDefaultInputListener() {
        state.withLock { s in
            guard !s.listenerInstalled else { return }
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let opaque = Unmanaged.passUnretained(self).toOpaque()
            let status = AudioObjectAddPropertyListener(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                defaultInputListenerCallback,
                opaque
            )
            if status == noErr {
                s.listenerInstalled = true
            } else {
                Log.warn("SystemMic: AudioObjectAddPropertyListener failed status=\(status)")
            }
        }
    }

    private func removeDefaultInputListener() {
        state.withLock { s in
            guard s.listenerInstalled else { return }
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let opaque = Unmanaged.passUnretained(self).toOpaque()
            _ = AudioObjectRemovePropertyListener(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                defaultInputListenerCallback,
                opaque
            )
            s.listenerInstalled = false
        }
    }
}

private func defaultInputListenerCallback(
    objectID: AudioObjectID,
    numAddresses: UInt32,
    addresses: UnsafePointer<AudioObjectPropertyAddress>,
    clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData else { return noErr }
    let source = Unmanaged<SystemMicrophoneBroadcastSource>
        .fromOpaque(clientData)
        .takeUnretainedValue()
    source.handleDefaultDeviceChanged()
    return noErr
}

private enum MicError: Error, CustomStringConvertible {
    case permissionNotGranted
    case noMicrophoneAvailable
    case sessionInputRejected
    case sessionOutputRejected

    var description: String {
        switch self {
        case .permissionNotGranted: return "microphone permission not granted"
        case .noMicrophoneAvailable: return "no default audio input device"
        case .sessionInputRejected: return "AVCaptureSession refused the microphone input"
        case .sessionOutputRejected: return "AVCaptureSession refused the audio data output"
        }
    }
}

private final class AudioSinkDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let state = Mutex<DelegateState>(DelegateState())

    fileprivate struct DelegateState {
        var sink: (any BroadcastSink)?
        var firstBufferLogged = false
        var samples: UInt64 = 0
        var buffers: UInt64 = 0
        // Rebuilt lazily on the first buffer (and on any subsequent
        // sample-rate change) using the actual buffer format, so the
        // attack/release coefficients track reality rather than what
        // we asked AVCaptureAudioDataOutput for.
        var agc: VoiceAGC?
    }

    func bind(sink: any BroadcastSink) {
        state.withLock { s in
            s.sink = sink
            s.firstBufferLogged = false
            s.samples = 0
            s.buffers = 0
            s.agc = nil
        }
    }

    func unbind() -> (buffers: UInt64, samples: UInt64) {
        state.withLock { s in
            let snapshot = (s.buffers, s.samples)
            s.sink = nil
            return snapshot
        }
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pcm = Self.audioPCMBuffer(from: sampleBuffer) else { return }
        let sinkSnapshot = state.withLock { s -> (any BroadcastSink)? in
            guard s.sink != nil else { return nil }
            if !s.firstBufferLogged {
                let bf = pcm.format
                Log.notice("SystemMic first buffer: sr=\(bf.sampleRate) ch=\(bf.channelCount) frames=\(pcm.frameLength)")
                s.firstBufferLogged = true
            }
            s.buffers &+= 1
            s.samples &+= UInt64(pcm.frameLength)
            let bufferSR = Float(pcm.format.sampleRate)
            if s.agc?.sampleRate != bufferSR {
                s.agc = VoiceAGC(sampleRate: bufferSR)
            }
            if let dst = pcm.floatChannelData?[0] {
                s.agc?.process(samples: dst, count: Int(pcm.frameLength))
            }
            return s.sink
        }
        sinkSnapshot?.sendMicAudio(pcm)
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
              let pcm = AVAudioPCMBuffer(pcmFormat: avFormat,
                                          frameCapacity: AVAudioFrameCount(frames)) else {
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
fileprivate struct VoiceAGC {
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
