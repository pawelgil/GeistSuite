import CoreMedia
import CoreVideo
import Foundation

final class CustomVideoBroadcastSource: BroadcastSource {
    private let producer: any VideoFrameProducer

    init(_ producer: any VideoFrameProducer) {
        self.producer = producer
    }

    func start(into sink: any BroadcastSink) throws {
        try producer.start { [sink] buffer, _ in
            sink.sendVideo(buffer)
        }
    }

    func stop() {
        producer.stop()
    }
}
