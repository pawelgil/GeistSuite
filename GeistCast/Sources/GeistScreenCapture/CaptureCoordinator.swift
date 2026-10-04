import CoreMedia
import AVFoundation
import CoreVideo
import Foundation
import Synchronization

protocol ScreenFrameCapturing: Sendable {
    func start(delivering handler: @escaping @Sendable (CVPixelBuffer, CMTime) -> Void) throws
    func stop()
}

protocol MicrophoneCapturing: Sendable {
    func start(delivering handler: @escaping @Sendable (AVAudioPCMBuffer, CMTime) -> Void) throws
    func stop()
}

protocol CaptureFrameWriting: Sendable {
    func write(_ data: Data)
}

actor CaptureCoordinator {
    enum Error: Swift.Error, Equatable {
        case busy
    }

    private let screen: any ScreenFrameCapturing
    private let microphone: any MicrophoneCapturing
    private let writer: any CaptureFrameWriting
    private let encoder = ScreenCaptureFrameEncoder()
    private var activeOutputs: CaptureOutputs = []
    private var delivery: CaptureDelivery?

    init(
        screen: any ScreenFrameCapturing,
        microphone: any MicrophoneCapturing,
        writer: any CaptureFrameWriting
    ) {
        self.screen = screen
        self.microphone = microphone
        self.writer = writer
    }

    deinit {
        delivery?.stop()
        if activeOutputs.contains(.microphone) { microphone.stop() }
        if activeOutputs.contains(.screen) { screen.stop() }
    }

    func start(outputs: CaptureOutputs) throws {
        guard activeOutputs.isEmpty else { throw Error.busy }
        do {
            let delivery = CaptureDelivery(writer: writer)
            self.delivery = delivery
            try startRequestedSources(outputs, delivery: delivery)
            activeOutputs = outputs
        } catch {
            delivery?.stop()
            delivery = nil
            stopRequestedSources(outputs)
            throw error
        }
    }

    func activate() {
        delivery?.activate()
    }

    func stop() {
        delivery?.stop()
        delivery = nil
        stopRequestedSources(activeOutputs)
        activeOutputs = []
    }

    private func startRequestedSources(_ outputs: CaptureOutputs, delivery: CaptureDelivery) throws {
        if outputs.contains(.screen) {
            try screen.start { [encoder, delivery] pixelBuffer, timestamp in
                guard let data = encoder.encodeVideo(pixelBuffer, presentationTime: timestamp) else { return }
                delivery.write(data, type: .screen)
            }
        }
        if outputs.contains(.microphone) {
            try microphone.start { [encoder, delivery] buffer, timestamp in
                guard let data = encoder.encodeMicrophone(buffer, presentationTime: timestamp) else { return }
                delivery.write(data, type: .microphone)
            }
        }
    }

    private func stopRequestedSources(_ outputs: CaptureOutputs) {
        if outputs.contains(.microphone) { microphone.stop() }
        if outputs.contains(.screen) { screen.stop() }
    }
}

private final class CaptureDelivery: Sendable {
    private struct State {
        var active = false
        var stopped = false
        var pending: [UInt32: Data] = [:]
    }

    private let state = Mutex(State())
    private let writer: any CaptureFrameWriting

    init(writer: any CaptureFrameWriting) {
        self.writer = writer
    }

    func write(_ data: Data, type: CaptureOutputs) {
        state.withLock {
            guard !$0.stopped else { return }
            if $0.active {
                writer.write(data)
            } else {
                // Capture can emit a static screen's only frame before the start acknowledgement.
                $0.pending[type.rawValue] = data
            }
        }
    }

    func activate() {
        state.withLock {
            guard !$0.stopped else { return }
            $0.active = true
            for frame in $0.pending.values { writer.write(frame) }
            $0.pending.removeAll()
        }
    }

    func stop() {
        state.withLock {
            $0.stopped = true
            $0.pending.removeAll()
        }
    }
}
