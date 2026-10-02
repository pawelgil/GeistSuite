import AVFoundation
import CoreMedia
import Foundation
import Synchronization

final class SystemMicrophoneCapture: MicrophoneCapturing {
    // MARK: Nested Types

    enum Error: Swift.Error {
        case permissionNotGranted
        case unavailable
    }

    // MARK: Properties

    private let delegate = MicrophoneSampleDelegate()
    private let queue = DispatchQueue(label: "com.geist.screencapture.microphone")
    private let session = Mutex<CaptureSessionBox?>(nil)

    // MARK: Functions

    func start(delivering handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw Error.permissionNotGranted
        }
        guard let device = AVCaptureDevice.default(for: .audio) else { throw Error.unavailable }
        let captureSession = try makeSession(device: device)
        delegate.bind(handler)
        session.withLock { $0 = CaptureSessionBox(captureSession) }
        captureSession.startRunning()
    }

    func stop() {
        delegate.unbind()
        session.withLock { current in
            current?.value.stopRunning()
            current = nil
        }
    }

    private func makeSession(device: AVCaptureDevice) throws -> AVCaptureSession {
        let captureSession = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        guard captureSession.canAddInput(input), captureSession.canAddOutput(output) else {
            throw Error.unavailable
        }
        captureSession.addInput(input)
        captureSession.addOutput(output)
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        output.setSampleBufferDelegate(delegate, queue: queue)
        return captureSession
    }
}

/// The immutable session is accessed only while the owning mutex is held.
private final class CaptureSessionBox: @unchecked Sendable {
    // MARK: Properties

    let value: AVCaptureSession

    // MARK: Lifecycle

    init(_ value: AVCaptureSession) {
        self.value = value
    }
}

/// The mutex protects all mutable callback state.
private final class MicrophoneSampleDelegate: NSObject,
    AVCaptureAudioDataOutputSampleBufferDelegate,
    @unchecked Sendable
{
    // MARK: Properties

    private let handler = Mutex<(@Sendable (AVAudioPCMBuffer) -> Void)?>(nil)

    // MARK: Static Functions

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description)
        else { return nil }
        var basicDescription = stream.pointee
        guard let format = AVAudioFormat(streamDescription: &basicDescription) else { return nil }
        return copyPCM(sampleBuffer, format: format)
    }

    private static func copyPCM(
        _ sampleBuffer: CMSampleBuffer,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(frames)
              ),
              let block = CMSampleBufferGetDataBuffer(sampleBuffer)
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        return copyBlock(block, into: buffer) ? buffer : nil
    }

    private static func copyBlock(_ block: CMBlockBuffer, into buffer: AVAudioPCMBuffer) -> Bool {
        var length = 0
        var totalLength = 0
        var source: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            block,
            atOffset: 0,
            lengthAtOffsetOut: &length,
            totalLengthOut: &totalLength,
            dataPointerOut: &source
        )
        guard status == noErr,
              let source,
              let destination = buffer.floatChannelData?[0]
        else { return false }
        memcpy(destination, source, totalLength)
        return true
    }

    // MARK: Functions

    func bind(_ handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        self.handler.withLock { $0 = handler }
    }

    func unbind() {
        handler.withLock { $0 = nil }
    }

    func captureOutput(
        _: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from _: AVCaptureConnection
    ) {
        guard let buffer = Self.pcmBuffer(from: sampleBuffer) else { return }
        handler.withLock { $0 }?(buffer)
    }
}
