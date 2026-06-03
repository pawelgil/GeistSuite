import Accelerate
import AVFoundation
import CoreAudio
import CoreMedia
import CoreVideo
import Dispatch
import Foundation
import Synchronization

public enum MacOSCameraError: Error, CustomStringConvertible {
    case noCameraAvailable
    case deviceNotFound(String)
    case sessionInputRejected
    case sessionOutputRejected
    case permissionNotGranted(AVAuthorizationStatus)
    case noMicrophoneAvailable
    case micPermissionNotGranted(AVAuthorizationStatus)

    public var description: String {
        switch self {
        case .noCameraAvailable:
            return "No macOS camera available (AVCaptureDevice.default(for: .video) returned nil)"
        case .deviceNotFound(let uid):
            return "AVCaptureDevice with uniqueID '\(uid)' not found"
        case .sessionInputRejected:
            return "AVCaptureSession refused the camera input"
        case .sessionOutputRejected:
            return "AVCaptureSession refused the video data output"
        case .permissionNotGranted(let status):
            return "Camera permission is \(status) — call AVCaptureDevice.requestAccess(for: .video) before attaching"
        case .noMicrophoneAvailable:
            return "No macOS microphone available"
        case .micPermissionNotGranted(let status):
            return "Microphone permission is \(status) — call AVCaptureDevice.requestAccess(for: .audio) before attaching"
        }
    }
}

// One AVCaptureSession per physical camera device, video and (optional) audio
// fanned out to N subscribers each. Audio rides the same session clock as the
// cam, so MediaSource-backed consumers get cam+mic sync for free.
public enum SharedMacOSCameraSource {
    public static func producer(device: MacOSCameraDevice = .default) async throws -> any VideoFrameProducer {
        let resolved = try resolveDevice(device)
        let shared = try await Pool.shared.get(deviceUID: resolved.uniqueID, device: resolved)
        return SubscriberProducer(shared: shared)
    }

    @CameraActor
    static func sharedSession(for device: MacOSCameraDevice) async throws -> SharedDeviceSession {
        let resolved = try resolveDevice(device)
        return try Pool.shared.get(deviceUID: resolved.uniqueID, device: resolved)
    }

    private static func resolveDevice(_ spec: MacOSCameraDevice) throws -> AVCaptureDevice {
        switch spec {
        case .default:
            guard let d = AVCaptureDevice.default(for: .video) else {
                throw MacOSCameraError.noCameraAvailable
            }
            return d
        case .uniqueID(let uid):
            guard let d = AVCaptureDevice(uniqueID: uid) else {
                throw MacOSCameraError.deviceNotFound(uid)
            }
            return d
        }
    }
}

@CameraActor
private final class Pool {
    static let shared = Pool()
    private var storage: [String: SharedDeviceSession] = [:]

    func get(deviceUID: String, device: sending AVCaptureDevice) throws -> SharedDeviceSession {
        if let existing = storage[deviceUID] { return existing }
        let made = try SharedDeviceSession(device: device)
        storage[deviceUID] = made
        return made
    }
}

protocol SharedSessionAudioSubscriber: AnyObject, Sendable {
    func receiveAudio(_ pcm: AVAudioPCMBuffer, pts: CMTime)
}

@CameraActor
final class SharedDeviceSession: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated let declaredFormat: VideoSlotFormat
    nonisolated let declaredAudioFormat = AudioSlotFormat(sampleRate: 48000, channels: 1)

    private let session: AVCaptureSession
    private var subscribers: [ObjectIdentifier: any VideoFrameSink] = [:]
    private var audioSubscribers: [ObjectIdentifier: any SharedSessionAudioSubscriber] = [:]
    private var audioInput: AVCaptureDeviceInput?
    private var audioOutput: AVCaptureAudioDataOutput?

    init(device: AVCaptureDevice) throws {
        let session = AVCaptureSession()
        session.beginConfiguration()
        // Pick the highest 420-compatible native format so subscribers only ever
        // need to downscale (or pass-through). Falling back to .high preset if
        // we can't choose explicitly.
        if let best = Self.highestNativeFormat(for: device) {
            try? device.lockForConfiguration()
            device.activeFormat = best
            device.unlockForConfiguration()
        } else if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw MacOSCameraError.sessionInputRejected
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        output.alwaysDiscardsLateVideoFrames = true
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw MacOSCameraError.sessionOutputRejected
        }
        session.addOutput(output)
        session.commitConfiguration()

        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let fpsRaw = device.activeFormat.videoSupportedFrameRateRanges.first?.maxFrameRate ?? 30
        self.declaredFormat = VideoSlotFormat(
            width: Int(dims.width), height: Int(dims.height),
            pixelFormat: .yuv420FullRange,
            fps: Int(fpsRaw.rounded())
        )
        self.session = session
        super.init()
        // AVF delivers samples on this queue — the same queue backing CameraActor.
        // Lets captureOutput use assumeIsolated for zero-overhead actor access.
        output.setSampleBufferDelegate(self, queue: CameraActor.shared.serialQueue)

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(handleInterrupted(_:)),
                       name: AVCaptureSession.wasInterruptedNotification, object: session)
        nc.addObserver(self, selector: #selector(handleInterruptionEnded(_:)),
                       name: AVCaptureSession.interruptionEndedNotification, object: session)
        nc.addObserver(self, selector: #selector(handleRuntimeError(_:)),
                       name: AVCaptureSession.runtimeErrorNotification, object: session)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc nonisolated private func handleInterrupted(_ note: Notification) {
        Log.notice("AVCaptureSession interrupted")
    }

    @objc nonisolated private func handleInterruptionEnded(_ note: Notification) {
        Task { @CameraActor [weak self] in
            guard let self else { return }
            if hasAnySubscriber() && !session.isRunning {
                session.startRunning()
            }
        }
    }

    @objc nonisolated private func handleRuntimeError(_ note: Notification) {
        let err = note.userInfo?[AVCaptureSessionErrorKey] as? Error
        Log.warn("AVCaptureSession runtime error: \(String(describing: err)) — restarting")
        Task { @CameraActor [weak self] in
            guard let self else { return }
            if hasAnySubscriber() {
                session.startRunning()
            }
        }
    }

    private func hasAnySubscriber() -> Bool {
        !subscribers.isEmpty || !audioSubscribers.isEmpty
    }

    func add(_ sink: any VideoFrameSink, id: ObjectIdentifier) {
        let wasEmpty = !hasAnySubscriber()
        subscribers[id] = sink
        if wasEmpty {
            session.startRunning()
        }
    }

    func remove(id: ObjectIdentifier) {
        subscribers.removeValue(forKey: id)
        if !hasAnySubscriber() {
            session.stopRunning()
        }
    }

    func addAudioSubscriber(_ subscriber: any SharedSessionAudioSubscriber, id: ObjectIdentifier) throws {
        let wasEmpty = !hasAnySubscriber()
        let wasFirstAudio = audioSubscribers.isEmpty
        if audioInput == nil {
            try addMicInput()
        }
        audioSubscribers[id] = subscriber
        if wasFirstAudio {
            DefaultInputDeviceWatcher.shared.subscribe(self)
        }
        if wasEmpty {
            session.startRunning()
        }
    }

    func removeAudioSubscriber(id: ObjectIdentifier) {
        audioSubscribers.removeValue(forKey: id)
        if audioSubscribers.isEmpty {
            DefaultInputDeviceWatcher.shared.unsubscribe(self)
            removeMicInput()
        }
        if !hasAnySubscriber() {
            session.stopRunning()
        }
    }

    func rebuildAudioInputForDefaultDeviceChange() {
        guard audioInput != nil else { return }
        // The default mic device changed (e.g. AirPods connected). Swap inputs
        // in place while keeping audio subscribers attached.
        do {
            removeMicInput()
            try addMicInput()
        } catch {
            Log.warn("MacOSCamera: rebuilding mic input failed: \(error)")
        }
    }

    private func addMicInput() throws {
        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw MacOSCameraError.noMicrophoneAvailable
        }
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        guard status == .authorized else {
            throw MacOSCameraError.micPermissionNotGranted(status)
        }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw MacOSCameraError.sessionInputRejected
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
            session.removeInput(input)
            session.commitConfiguration()
            throw MacOSCameraError.sessionOutputRejected
        }
        session.addOutput(output)
        session.commitConfiguration()
        output.setSampleBufferDelegate(self, queue: CameraActor.shared.serialQueue)
        audioInput = input
        audioOutput = output
        Log.notice("MacOSCamera: mic input added '\(device.localizedName)' (uid=\(device.uniqueID))")
    }

    private func removeMicInput() {
        session.beginConfiguration()
        if let input = audioInput { session.removeInput(input) }
        if let output = audioOutput { session.removeOutput(output) }
        session.commitConfiguration()
        audioInput = nil
        audioOutput = nil
    }

    private static func highestNativeFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let yuvFormats = device.formats.filter { format in
            let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            return subtype == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                || subtype == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }
        let candidates = yuvFormats.isEmpty ? device.formats : yuvFormats
        return candidates.max { a, b in
            let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
            let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            return Int(da.width) * Int(da.height) < Int(db.width) * Int(db.height)
        }
    }

    func shutdown() {
        session.stopRunning()
        subscribers.removeAll()
    }

    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                    didOutput sampleBuffer: CMSampleBuffer,
                                    from connection: AVCaptureConnection) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if output is AVCaptureAudioDataOutput {
            guard let pcm = MicAudioBuffer.fromSampleBuffer(sampleBuffer, applyGain: true) else { return }
            let wrapped = UncheckedPCM(value: pcm)
            // AVF delivers on CameraActor.shared.serialQueue — same executor.
            CameraActor.assumeIsolated {
                for sub in audioSubscribers.values {
                    sub.receiveAudio(wrapped.value, pts: pts)
                }
            }
            return
        }
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let dur = CMSampleBufferGetDuration(sampleBuffer)
        let wrapped = UncheckedBuffer(value: pb)
        CameraActor.assumeIsolated {
            for sink in subscribers.values {
                sink.sendVideo(wrapped.value, pts: pts, duration: dur)
            }
        }
    }
}

/// PCM extraction + +9.5dB gain. Shared between the shared cam-pool's mic
/// branch and the standalone `MacOSMicrophoneProducer` so both produce
/// identically-leveled audio.
enum MicAudioBuffer {
    static func fromSampleBuffer(_ sb: CMSampleBuffer, applyGain: Bool) -> AVAudioPCMBuffer? {
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
        if applyGain {
            // AVCaptureAudioDataOutput hands us raw float without AGC, so the
            // perceived loudness is well below what QuickTime/Zoom produce.
            // +9.5dB with a hard clamp gets us into the expected range.
            var gain: Float = 3.0
            var lo: Float = -1.0
            var hi: Float = 1.0
            let n = vDSP_Length(totalLength / MemoryLayout<Float>.size)
            vDSP_vsmul(dst, 1, &gain, dst, 1, n)
            vDSP_vclip(dst, 1, &lo, &hi, dst, 1, n)
        }
        return pcm
    }
}

private final class SubscriberProducer: VideoFrameProducer, Sendable {
    let declaredFormat: VideoSlotFormat
    private let shared: SharedDeviceSession
    private let registeredID = Mutex<ObjectIdentifier?>(nil)

    init(shared: SharedDeviceSession) {
        self.shared = shared
        self.declaredFormat = shared.declaredFormat
    }

    func start(into sink: any VideoFrameSink) throws {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        guard status == .authorized else {
            throw MacOSCameraError.permissionNotGranted(status)
        }
        let id = ObjectIdentifier(sink)
        registeredID.withLock { $0 = id }
        let shared = self.shared
        Task { @CameraActor in shared.add(sink, id: id) }
    }

    func stop() {
        let id = registeredID.withLock { current -> ObjectIdentifier? in
            let result = current
            current = nil
            return result
        }
        if let id {
            let shared = self.shared
            Task { @CameraActor in shared.remove(id: id) }
        }
    }

    func reformat(to target: VideoSlotFormat) {
        _ = target  // Shim handles aspect/orientation normalization.
    }
}

// Process-wide listener on the system default-input-device property. Fans
// changes out to all SharedDeviceSessions currently hosting a mic input; each
// rebuilds its audio input in place to follow the new default device.
private final class DefaultInputDeviceWatcher: @unchecked Sendable {
    static let shared = DefaultInputDeviceWatcher()

    private let lock = NSLock()
    private var subscribers: [ObjectIdentifier: WeakBox] = [:]
    private var installed = false

    private struct WeakBox { weak var value: SharedDeviceSession? }

    private init() {}

    func subscribe(_ session: SharedDeviceSession) {
        lock.lock()
        subscribers[ObjectIdentifier(session)] = WeakBox(value: session)
        let needsInstall = !installed
        if needsInstall { installed = true }
        lock.unlock()
        if needsInstall { installListener() }
    }

    func unsubscribe(_ session: SharedDeviceSession) {
        lock.lock()
        subscribers.removeValue(forKey: ObjectIdentifier(session))
        lock.unlock()
    }

    fileprivate func dispatch() {
        lock.lock()
        let sessions = subscribers.values.compactMap { $0.value }
        subscribers = subscribers.filter { $0.value.value != nil }
        lock.unlock()
        for s in sessions {
            Task { @CameraActor in s.rebuildAudioInputForDefaultDeviceChange() }
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
            sharedDefaultInputDeviceChangedCallback,
            nil
        )
        if status != noErr {
            Log.warn("MacOSCamera: default-input listener install failed (\(status))")
        }
    }
}

private func sharedDefaultInputDeviceChangedCallback(
    objectID: AudioObjectID,
    numAddresses: UInt32,
    addresses: UnsafePointer<AudioObjectPropertyAddress>,
    clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    DefaultInputDeviceWatcher.shared.dispatch()
    return noErr
}
