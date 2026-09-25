import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
@testable import GeistBroadcast
import Synchronization
import Testing

struct BroadcastMediaSourcesTests {
    @Test func `video repeated start and stop only starts and stops once`() {
        let producer = VideoProducerSpy()
        let sut = createSUT(video: .custom(producer))

        sut.startVideo()
        sut.startVideo()
        sut.stopVideo()
        sut.stopVideo()

        #expect(producer.events == ["start", "stop"])
    }

    @Test func `video restart after stop starts producer again`() {
        let producer = VideoProducerSpy()
        let sut = createSUT(video: .custom(producer))
        sut.startVideo()
        sut.stopVideo()

        sut.startVideo()

        #expect(producer.events == ["start", "stop", "start"])
    }

    @Test func `mic repeated enable and disable only starts and stops once`() {
        let producer = MicProducerSpy()
        let sut = createSUT(mic: .custom(producer))

        sut.setMicEnabled(true)
        #expect(sut.isMicAttached)
        sut.setMicEnabled(true)
        sut.setMicEnabled(false)
        sut.setMicEnabled(false)

        #expect(!sut.isMicAttached)
        #expect(producer.events == ["start", "stop"])
    }

    @Test func `sources repeated stop all stops both once`() {
        let video = VideoProducerSpy()
        let mic = MicProducerSpy()
        let sut = createSUT(video: .custom(video), mic: .custom(mic))
        sut.startVideo()
        sut.setMicEnabled(true)

        sut.stopAll()
        sut.stopAll()

        #expect(video.events == ["start", "stop"])
        #expect(mic.events == ["start", "stop"])
        #expect(!sut.isMicAttached)
    }

    @Test func `mic config changed while attached keeps source until detached`() {
        let original = MicProducerSpy()
        let replacement = MicProducerSpy()
        let sut = createSUT(mic: .custom(original))
        sut.setMicEnabled(true)

        sut.setMicAudio(.custom(replacement))
        sut.setMicEnabled(true)

        #expect(original.events == ["start"])
        #expect(replacement.events.isEmpty)
        sut.setMicEnabled(false)
        sut.setMicEnabled(true)
        #expect(original.events == ["start", "stop"])
        #expect(replacement.events == ["start"])
    }

    @Test func `mic disabled does not attach or advertise availability`() {
        let sut = createSUT()

        sut.setMicEnabled(true)

        #expect(!sut.isMicAttached)
        #expect(!sut.isMacOSMicAuthorized)
        #expect(!sut.isMicEnabledByDefault)
    }

    @Test func `mic custom and file default on without microphone permission`() {
        let sut = createSUT(mic: .custom(MicProducerSpy()))

        #expect(sut.isMacOSMicAuthorized)
        #expect(sut.isMicEnabledByDefault)
        sut.setMicAudio(.mediaFile(URL(fileURLWithPath: "/unused-fixture.wav")))
        #expect(sut.isMacOSMicAuthorized)
        #expect(sut.isMicEnabledByDefault)
    }

    @Test func `mic system microphone default off and uses host authorization`() {
        let sut = createSUT(mic: .systemMicrophone)

        #expect(!sut.isMicEnabledByDefault)
        #expect(sut.isMacOSMicAuthorized == (AVCaptureDevice.authorizationStatus(for: .audio) == .authorized))
    }

    @Test func `mic failed start does not retain source`() {
        let sut = createSUT(mic: .custom(FailingMicProducerStub()))
        sut.setMicEnabled(true)
        #expect(!sut.isMicAttached)
        let replacement = MicProducerSpy()
        sut.setMicAudio(.custom(replacement))

        sut.setMicEnabled(true)

        #expect(sut.isMicAttached)
        #expect(replacement.events == ["start"])
    }

    private func createSUT(
        video: VideoCaptureConfig = .custom(VideoProducerSpy()), mic: MicAudioConfig = .disabled,
    ) -> BroadcastMediaSources {
        BroadcastMediaSources(
            simulator: UUID().uuidString, simctlSetPath: nil,
            videoCapture: video, micAudio: mic, sink: DummySink(),
        )
    }
}

private final class VideoProducerSpy: VideoFrameProducer {
    // MARK: Properties

    private let recordedEvents = Mutex<[String]>([])

    // MARK: Computed Properties

    var events: [String] {
        recordedEvents.withLock { $0 }
    }

    // MARK: Functions

    func start(producing _: @escaping @Sendable (CVPixelBuffer, CMTime) -> Void) throws {
        recordedEvents.withLock { $0.append("start") }
    }

    func stop() {
        recordedEvents.withLock { $0.append("stop") }
    }
}

private final class MicProducerSpy: MicAudioProducer {
    // MARK: Properties

    private let recordedEvents = Mutex<[String]>([])

    // MARK: Computed Properties

    var events: [String] {
        recordedEvents.withLock { $0 }
    }

    // MARK: Functions

    func start(producing _: @escaping @Sendable (AVAudioPCMBuffer, CMTime) -> Void) throws {
        recordedEvents.withLock { $0.append("start") }
    }

    func stop() {
        recordedEvents.withLock { $0.append("stop") }
    }
}

private final class FailingMicProducerStub: MicAudioProducer {
    // MARK: Nested Types

    private enum Failure: Error { case unavailable }

    // MARK: Functions

    func start(producing _: @escaping @Sendable (AVAudioPCMBuffer, CMTime) -> Void) throws {
        throw Failure.unavailable
    }

    func stop() {}
}

private final class DummySink: BroadcastSink {
    func sendVideo(_: CVPixelBuffer) {}
    func sendMicAudio(_: AVAudioPCMBuffer) {}
}
