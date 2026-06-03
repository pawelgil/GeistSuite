import CoreMedia
import CoreVideo
import Foundation

final class CustomVideoBroadcastSource: BroadcastSource {
    private let producer: any VideoFrameProducer

    init(_ producer: any VideoFrameProducer) {
        self.producer = producer
    }

    func start(into sink: any BroadcastSink) throws {
        try producer.start(into: BroadcastVideoSinkAdapter(downstream: sink))
    }

    func stop() {
        producer.stop()
    }
}

private final class BroadcastVideoSinkAdapter: VideoFrameSink, Sendable {
    let downstream: any BroadcastSink

    init(downstream: any BroadcastSink) {
        self.downstream = downstream
    }

    func sendVideo(_ pixelBuffer: CVPixelBuffer, pts _: CMTime, duration _: CMTime) {
        downstream.sendVideo(pixelBuffer)
    }
}
