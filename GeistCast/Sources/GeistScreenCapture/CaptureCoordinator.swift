import AVFoundation
import CoreVideo
import Foundation

protocol ScreenFrameCapturing: Sendable {
    func start(delivering handler: @escaping @Sendable (CVPixelBuffer) -> Void) throws
    func stop()
}

protocol MicrophoneCapturing: Sendable {
    func start(delivering handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws
    func stop()
}

protocol CaptureFrameWriting: Sendable {
    func write(_ data: Data)
}

actor CaptureCoordinator {
    // MARK: Nested Types

    enum Error: Swift.Error, Equatable {
        case busy
    }

    // MARK: Properties

    private let screen: any ScreenFrameCapturing
    private let microphone: any MicrophoneCapturing
    private let writer: any CaptureFrameWriting
    private let encoder = ScreenCaptureFrameEncoder()
    private var activeOutputs: CaptureOutputs = []

    // MARK: Lifecycle

    init(
        screen: any ScreenFrameCapturing,
        microphone: any MicrophoneCapturing,
        writer: any CaptureFrameWriting
    ) {
        self.screen = screen
        self.microphone = microphone
        self.writer = writer
    }

    // MARK: Functions

    func start(outputs: CaptureOutputs) throws {
        guard activeOutputs.isEmpty else { throw Error.busy }
        do {
            try startRequestedSources(outputs)
            activeOutputs = outputs
        } catch {
            stopRequestedSources(outputs)
            throw error
        }
    }

    func stop() {
        stopRequestedSources(activeOutputs)
        activeOutputs = []
    }

    private func startRequestedSources(_ outputs: CaptureOutputs) throws {
        if outputs.contains(.screen) {
            try screen.start { [encoder, writer] pixelBuffer in
                guard let data = encoder.encodeVideo(pixelBuffer) else { return }
                writer.write(data)
            }
        }
        if outputs.contains(.microphone) {
            try microphone.start { [encoder, writer] buffer in
                guard let data = encoder.encodeMicrophone(buffer) else { return }
                writer.write(data)
            }
        }
    }

    private func stopRequestedSources(_ outputs: CaptureOutputs) {
        if outputs.contains(.microphone) { microphone.stop() }
        if outputs.contains(.screen) { screen.stop() }
    }
}
