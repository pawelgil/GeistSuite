import Foundation
import Testing
@testable import GeistBroadcast

@Suite("WireDecoder")
struct WireDecoderTests {

    @Test
    func feed_startedLine_yieldsBroadcastStarted() {
        var sut = WireDecoder()

        let messages = sut.feed(line(
            #"{"type":"started","simulatorUDID":"S","hostAppBundleID":"H","extensionBundleID":"E","startedAt":"2026-01-01T00:00:00Z"}"#
        ))

        #expect(messages == [.broadcastStarted(referenceBroadcast)])
    }

    @Test
    func feed_endedLine_yieldsBroadcastEnded() {
        var sut = WireDecoder()

        let messages = sut.feed(line(
            #"{"type":"ended","simulatorUDID":"S","hostAppBundleID":"H","extensionBundleID":"E","startedAt":"2026-01-01T00:00:00Z"}"#
        ))

        #expect(messages == [.broadcastEnded(referenceBroadcast)])
    }

    @Test
    func feed_helloHostLine_yieldsHelloHost() {
        var sut = WireDecoder()

        let messages = sut.feed(line(#"{"type":"hello","role":"host"}"#))

        #expect(messages == [.helloHost])
    }

    @Test
    func feed_helloExtensionLine_yieldsHelloExtensionWithBundleID() {
        var sut = WireDecoder()

        let messages = sut.feed(line(
            #"{"type":"hello","role":"extension","extensionBundleID":"E"}"#
        ))

        #expect(messages == [.helloExtension(extensionBundleID: "E")])
    }

    @Test
    func feed_stateLineRecording_yieldsStateWithBroadcast() {
        var sut = WireDecoder()

        let messages = sut.feed(line(
            #"{"type":"state","recording":true,"simulatorUDID":"S","hostAppBundleID":"H","extensionBundleID":"E","startedAt":"2026-01-01T00:00:00Z"}"#
        ))

        #expect(messages == [
            .state(recording: true, broadcast: referenceBroadcast,
                   micEnabled: false, macOSMicAuthorized: true)
        ])
    }

    @Test
    func feed_stateLineRecordingWithMicEnabled_yieldsStateWithMicEnabledTrue() {
        var sut = WireDecoder()

        let messages = sut.feed(line(
            #"{"type":"state","recording":true,"simulatorUDID":"S","hostAppBundleID":"H","extensionBundleID":"E","startedAt":"2026-01-01T00:00:00Z","micEnabled":true,"macOSMicAuthorized":true}"#
        ))

        #expect(messages == [
            .state(recording: true, broadcast: referenceBroadcast,
                   micEnabled: true, macOSMicAuthorized: true)
        ])
    }

    @Test
    func feed_stateLineNotRecording_yieldsStateWithNilBroadcast() {
        var sut = WireDecoder()

        let messages = sut.feed(line(#"{"type":"state","recording":false}"#))

        #expect(messages == [
            .state(recording: false, broadcast: nil,
                   micEnabled: false, macOSMicAuthorized: true)
        ])
    }

    @Test
    func feed_stateLineWithMacOSMicNotAuthorized_yieldsStateMacOSMicAuthorizedFalse() {
        var sut = WireDecoder()

        let messages = sut.feed(line(
            #"{"type":"state","recording":false,"macOSMicAuthorized":false}"#
        ))

        #expect(messages == [
            .state(recording: false, broadcast: nil,
                   micEnabled: false, macOSMicAuthorized: false)
        ])
    }

    @Test
    func feed_userPressedStartLine_yieldsUserPressedStart() {
        var sut = WireDecoder()

        let messages = sut.feed(line(#"{"type":"user_pressed_start","micEnabled":true}"#))

        #expect(messages == [.userPressedStart(micEnabled: true)])
    }

    @Test
    func feed_userPressedStartLine_withoutMicField_defaultsToFalse() {
        var sut = WireDecoder()

        let messages = sut.feed(line(#"{"type":"user_pressed_start"}"#))

        #expect(messages == [.userPressedStart(micEnabled: false)])
    }

    @Test
    func feed_userPressedStopLine_yieldsUserPressedStop() {
        var sut = WireDecoder()

        let messages = sut.feed(line(#"{"type":"user_pressed_stop"}"#))

        #expect(messages == [.userPressedStop])
    }

    @Test
    func feed_beginLine_yieldsBeginWithBroadcast() {
        var sut = WireDecoder()

        let messages = sut.feed(line(
            #"{"type":"begin","simulatorUDID":"S","hostAppBundleID":"H","extensionBundleID":"E","startedAt":"2026-01-01T00:00:00Z"}"#
        ))

        #expect(messages == [.begin(referenceBroadcast)])
    }

    @Test
    func feed_finishLine_yieldsFinish() {
        var sut = WireDecoder()

        let messages = sut.feed(line(#"{"type":"finish"}"#))

        #expect(messages == [.finish])
    }

    @Test
    func feed_pauseLine_yieldsPause() {
        var sut = WireDecoder()

        let messages = sut.feed(line(#"{"type":"pause"}"#))

        #expect(messages == [.pause])
    }

    @Test
    func feed_resumeLine_yieldsResume() {
        var sut = WireDecoder()

        let messages = sut.feed(line(#"{"type":"resume"}"#))

        #expect(messages == [.resume])
    }

    @Test
    func feed_setMicAudioReadinessLine_yieldsSetMicAudioReadiness() {
        var sut = WireDecoder()

        let messages = sut.feed(line(
            #"{"type":"set_mic_audio_readiness","ready":true}"#
        ))

        #expect(messages == [.setMicAudioReadiness(ready: true)])
    }

    @Test
    func feed_userToggledMicLine_yieldsUserToggledMic() {
        var sut = WireDecoder()

        let messages = sut.feed(line(
            #"{"type":"user_toggled_mic","enabled":true}"#
        ))

        #expect(messages == [.userToggledMic(enabled: true)])
    }

    @Test
    func feed_unknownType_yieldsNoMessages() {
        var sut = WireDecoder()

        let messages = sut.feed(line(#"{"type":"surprise"}"#))

        #expect(messages.isEmpty)
    }

    @Test
    func feed_lineSplitAcrossChunks_yieldsMessageOnceComplete() {
        var sut = WireDecoder()
        let full = line(#"{"type":"finish"}"#)
        let split = full.count / 2

        let firstBatch = sut.feed(full.prefix(split))
        let secondBatch = sut.feed(full.suffix(from: split))

        #expect(firstBatch.isEmpty)
        #expect(secondBatch == [.finish])
    }

    private var referenceBroadcast: Broadcast {
        Broadcast(
            simulatorUDID: "S",
            hostAppBundleID: "H",
            extensionBundleID: "E",
            startedAt: ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")!
        )
    }

    private func line(_ s: String) -> Data {
        Data((s + "\n").utf8)
    }
}

@Suite("WireEncoder")
struct WireEncoderTests {

    @Test(arguments: WireMessage.encoderRoundtripFixtures)
    func encode_thenDecode_roundTripsMessage(message: WireMessage) {
        let encoder = WireEncoder()
        var decoder = WireDecoder()

        let bytes = encoder.encode(message)
        let messages = decoder.feed(bytes)

        #expect(messages == [message])
    }
}

private extension WireMessage {
    static let encoderRoundtripFixtures: [WireMessage] = [
        .broadcastStarted(makeBroadcast()),
        .broadcastEnded(makeBroadcast()),
        .helloHost,
        .helloExtension(extensionBundleID: "com.ext"),
        .state(recording: true, broadcast: makeBroadcast(),
               micEnabled: true, macOSMicAuthorized: true),
        .state(recording: true, broadcast: makeBroadcast(),
               micEnabled: false, macOSMicAuthorized: false),
        .state(recording: false, broadcast: nil,
               micEnabled: false, macOSMicAuthorized: true),
        .userPressedStart(micEnabled: false),
        .userPressedStop,
        .begin(makeBroadcast()),
        .finish,
        .pause,
        .resume,
        .extensionTerminated(errorDomain: "Dom", errorCode: 42, errorMessage: "boom"),
        .setMicAudioReadiness(ready: false),
        .setMicAudioReadiness(ready: true),
        .userToggledMic(enabled: false),
        .userToggledMic(enabled: true),
    ]
}

private func makeBroadcast() -> Broadcast {
    Broadcast(
        simulatorUDID: "S",
        hostAppBundleID: "H",
        extensionBundleID: "E",
        startedAt: ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")!
    )
}

@Suite("FrameHeader")
struct FrameHeaderTests {

    @Test(arguments: FrameHeader.roundtripFixtures)
    func encoded_thenDecoded_roundTripsAllFields(header: FrameHeader) throws {
        let bytes = header.encoded()
        let decoded = try #require(FrameHeader.decoded(from: bytes))

        #expect(decoded == header)
    }

    @Test
    func encoded_producesExactFixedSizeBlob() {
        let header = FrameHeader.video(
            pixelFormatFourCC: FrameHeader.nv12VideoRange,
            width: 320, height: 240,
            bytesPerRowPlane0: 320, bytesPerRowPlane1: 320, payloadSize: 115200
        )

        let bytes = header.encoded()

        #expect(bytes.count == FrameHeader.byteCount)
    }

    @Test
    func decoded_blobWithoutMagic_returnsNil() {
        let bogus = Data(count: FrameHeader.byteCount)

        let decoded = FrameHeader.decoded(from: bogus)

        #expect(decoded == nil)
    }

    @Test
    func decoded_shorterThanHeader_returnsNil() {
        let truncated = Data(count: FrameHeader.byteCount - 1)

        let decoded = FrameHeader.decoded(from: truncated)

        #expect(decoded == nil)
    }
}

private extension FrameHeader {
    static let roundtripFixtures: [FrameHeader] = [
        FrameHeader.video(
            pixelFormatFourCC: FrameHeader.bgra32,
            width: 320, height: 240,
            bytesPerRowPlane0: 1280, bytesPerRowPlane1: 0, payloadSize: 307200
        ),
        FrameHeader.video(
            pixelFormatFourCC: FrameHeader.nv12VideoRange,
            width: 320, height: 240,
            bytesPerRowPlane0: 320, bytesPerRowPlane1: 320, payloadSize: 115200
        ),
        FrameHeader.audio(
            stream: .audioMic,
            sampleRate: 44100, channelCount: 1,
            sampleFormat: .pcmInt16, isInterleaved: true,
            sampleCount: 1024, payloadSize: 2048
        ),
        FrameHeader.audio(
            stream: .audioApp,
            sampleRate: 48000, channelCount: 2,
            sampleFormat: .pcmFloat32, isInterleaved: false,
            sampleCount: 480, payloadSize: 3840
        ),
    ]
}
