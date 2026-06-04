import AVFoundation
import CoreMedia
import Foundation

final class CustomMicAudioBroadcastSource: BroadcastSource {
    private let producer: any MicAudioProducer

    init(_ producer: any MicAudioProducer) {
        self.producer = producer
    }

    func start(into sink: any BroadcastSink) throws {
        try producer.start { [sink] buffer, _ in
            sink.sendMicAudio(buffer)
        }
    }

    func stop() {
        producer.stop()
    }
}
