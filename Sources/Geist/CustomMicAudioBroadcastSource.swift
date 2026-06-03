import AVFoundation
import CoreMedia
import Foundation

final class CustomMicAudioBroadcastSource: BroadcastSource {
    private let producer: any AudioFrameProducer

    init(_ producer: any AudioFrameProducer) {
        self.producer = producer
    }

    func start(into sink: any BroadcastSink) throws {
        try producer.start(into: BroadcastAudioSinkAdapter(downstream: sink))
    }

    func stop() {
        producer.stop()
    }
}

private final class BroadcastAudioSinkAdapter: AudioFrameSink, Sendable {
    let downstream: any BroadcastSink

    init(downstream: any BroadcastSink) {
        self.downstream = downstream
    }

    func sendAudio(_ samples: AVAudioPCMBuffer, pts _: CMTime) {
        downstream.sendMicAudio(samples)
    }
}
