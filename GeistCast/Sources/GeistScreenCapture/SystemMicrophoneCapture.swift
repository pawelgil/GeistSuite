import AVFoundation
import CoreMedia
import Foundation
import Synchronization

final class SystemMicrophoneCapture: MicrophoneCapturing {
    enum Error: Swift.Error {
        case permissionNotGranted
        case unavailable
    }

    private let delegate = MicrophoneSampleDelegate()
    private let queue = DispatchQueue(label: "com.geist.screencapture.microphone")
    private let session = Mutex<CaptureSessionBox?>(nil)

    func start(delivering handler: @escaping @Sendable (AVAudioPCMBuffer, CMTime) -> Void) throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw Error.permissionNotGranted
        }
        guard let device = AVCaptureDevice.default(for: .audio) else { throw Error.unavailable }
        let captureSession = try makeSession(device: device)
        session.withLock {
            delegate.bind(handler)
            $0 = CaptureSessionBox(captureSession)
            captureSession.startRunning()
        }
    }

    func stop() {
        session.withLock { current in
            delegate.unbind()
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
    let value: AVCaptureSession

    init(_ value: AVCaptureSession) {
        self.value = value
    }
}

/// The mutex protects all mutable callback state.
private final class MicrophoneSampleDelegate: NSObject,
    AVCaptureAudioDataOutputSampleBufferDelegate,
    @unchecked Sendable
{
    // A box keeps callbacks out of generic closure reabstraction, which can recurse in Swift 6.
    private final class Handler: Sendable {
        let invoke: @Sendable (AVAudioPCMBuffer, CMTime) -> Void

        init(_ invoke: @escaping @Sendable (AVAudioPCMBuffer, CMTime) -> Void) {
            self.invoke = invoke
        }
    }

    private let handler = Mutex<Handler?>(nil)

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
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let totalLength = CMBlockBufferGetDataLength(block)
        guard buffers.reduce(0, { $0 + Int($1.mDataByteSize) }) == totalLength else { return false }
        var offset = 0
        for audioBuffer in buffers {
            guard let destination = audioBuffer.mData else { return false }
            let count = Int(audioBuffer.mDataByteSize)
            guard CMBlockBufferCopyDataBytes(block, atOffset: offset, dataLength: count,
                                            destination: destination) == noErr else { return false }
            offset += count
        }
        return true
    }

    func bind(_ handler: @escaping @Sendable (AVAudioPCMBuffer, CMTime) -> Void) {
        self.handler.withLock { $0 = Handler(handler) }
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
        handler.withLock { $0 }?.invoke(buffer, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }
}
