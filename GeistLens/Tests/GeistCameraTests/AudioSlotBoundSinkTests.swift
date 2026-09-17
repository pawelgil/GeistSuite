import AVFoundation
import CoreMedia
import Foundation
import Synchronization
import Testing
@testable import GeistCamera

@Suite("AudioSlotBoundSink")
struct AudioSlotBoundSinkTests {
    @Test func sendAudioReportingAdmission_TransportAccepts_ReturnsAcceptedAndMarksHeartbeat() {
        let transport = FrameTransportRecordingSpy()
        let heartbeat = FrameHeartbeat()
        let sink = makeSink(transport: transport, heartbeat: heartbeat)

        let admission = sink.sendAudioReportingAdmission(makeBuffer(), pts: .zero)

        #expect(admission == .accepted)
        #expect(transport.sentFrames.count == 1)
        #expect(heartbeat.read() != 0)
    }

    @Test func sendAudioReportingAdmission_TransportRejects_ReturnsReasonWithoutMarkingHeartbeat() {
        let transport = FrameTransportRejectionStub(rejection: .capacity)
        let heartbeat = FrameHeartbeat()
        let sink = makeSink(transport: transport, heartbeat: heartbeat)

        let admission = sink.sendAudioReportingAdmission(makeBuffer(), pts: .zero)

        #expect(admission == .rejected(.capacity))
        #expect(heartbeat.read() == 0)
    }

    @Test func sendAudioReportingAdmission_TransportUnavailable_ReturnsUnavailable() {
        let transport = FrameTransportRejectionStub(rejection: .unavailable)
        let sink = makeSink(transport: transport, heartbeat: FrameHeartbeat())

        let admission = sink.sendAudioReportingAdmission(makeBuffer(), pts: .zero)

        #expect(admission == .rejected(.unavailable))
    }

    @Test func sendAudioReportingAdmission_FormatMismatch_ReturnsInvalidFormatWithoutSending() {
        let transport = FrameTransportRecordingSpy()
        let heartbeat = FrameHeartbeat()
        let sink = makeSink(transport: transport, heartbeat: heartbeat)

        let admission = sink.sendAudioReportingAdmission(makeBuffer(sampleRate: 44_100), pts: .zero)

        #expect(admission == .rejected(.invalidFormat))
        #expect(transport.sentFrames.isEmpty)
        #expect(heartbeat.read() == 0)
    }

    @Test func sendAudio_LegacyCall_DelegatesToTransportOnce() {
        let transport = FrameTransportRecordingSpy()
        let sink = makeSink(transport: transport, heartbeat: FrameHeartbeat())

        sink.sendAudio(makeBuffer(), pts: .zero)

        #expect(transport.sentFrames.count == 1)
    }

    private func makeBuffer(sampleRate: Double = 48_000) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
        buffer.frameLength = 1
        buffer.floatChannelData![0][0] = 0.25
        return buffer
    }

    private func makeSink(
        transport: any FrameTransport,
        heartbeat: FrameHeartbeat
    ) -> AudioSlotBoundSink {
        AudioSlotBoundSink(
            wireIndex: 2,
            declaredFormat: AudioSlotFormat(sampleRate: 48_000, channels: 1),
            client: transport,
            heartbeat: heartbeat
        )
    }
}

private final class FrameTransportRecordingSpy: FrameTransport, Sendable {
    private let frames = Mutex<[OutboundFrame]>([])

    var sentFrames: [OutboundFrame] {
        frames.withLock { $0 }
    }

    func send(_ frame: OutboundFrame) -> FrameAdmission {
        frames.withLock { $0.append(frame) }
        return .accepted
    }
}

private struct FrameTransportRejectionStub: FrameTransport {
    let rejection: AudioFrameRejection

    func send(_: OutboundFrame) -> FrameAdmission {
        .rejected(rejection)
    }
}
