import Foundation
import Testing
@testable import GeistCamera

@Suite("WireHello")
struct WireHelloTests {
    @Test func encoded_emptySlots_emitsVersionAndZeroCount() {
        let hello = WireHello(slots: [])

        let bytes = hello.encoded()

        #expect(bytes.count == 8)
        let version: UInt32 = bytes.readLE(at: 0)
        let count: UInt32 = bytes.readLE(at: 4)
        #expect(version == Wire.version)
        #expect(count == 0)
    }

    @Test func encoded_threeSlots_emitsSlotsInOrder() {
        let s0 = WireSlotInfo(kind: 0, width: 1920, height: 1080, pixelFormat: 0x420f,
                               fpsNum: 30, fpsDen: 1, features: 0)
        let s1 = WireSlotInfo(kind: 1, width: 1280, height: 720, pixelFormat: 0x420f,
                               fpsNum: 60, fpsDen: 1, features: 1)
        let s2 = WireSlotInfo(kind: 2, width: 0, height: 1, pixelFormat: 0,
                               fpsNum: 48000, fpsDen: 1, features: 0)
        let hello = WireHello(slots: [s0, s1, s2])

        let bytes = hello.encoded()

        let slotSize = WireSlotInfo.encodedSize
        #expect(bytes.count == 8 + 3 * slotSize)
        // First slot starts at offset 8.
        let kind0: UInt32 = bytes.readLE(at: 8)
        let width0: UInt32 = bytes.readLE(at: 12)
        #expect(kind0 == 0)
        #expect(width0 == 1920)
        // Second slot at offset 8 + slotSize.
        let kind1: UInt32 = bytes.readLE(at: 8 + slotSize)
        #expect(kind1 == 1)
        let features1: UInt32 = bytes.readLE(at: 8 + slotSize + 24)
        #expect(features1 == 1)
        // Third slot at offset 8 + 2*slotSize. fps_num is at +16.
        let fpsNum2: UInt32 = bytes.readLE(at: 8 + 2 * slotSize + 16)
        #expect(fpsNum2 == 48000)
    }
}

@Suite("WireHelloAck")
struct WireHelloAckTests {
    @Test func decode_validPayload_extractsVersionAndInitialActive() {
        var payload = Data()
        payload.appendLE(UInt32(1))
        payload.appendLE(UInt32(0))
        payload.appendLE(UInt32(1))
        payload.appendLE(UInt32(0))

        let ack = WireHelloAck.decode(payload)

        let unwrapped = try? #require(ack)
        #expect(unwrapped?.version == 1)
        #expect(unwrapped?.initialActive == [0, 1, 0])
    }

    @Test func decode_shortPayload_returnsNil() {
        let payload = Data([0x01, 0x02])

        let ack = WireHelloAck.decode(payload)

        #expect(ack == nil)
    }
}

@Suite("WireSlotActive")
struct WireSlotActiveTests {
    @Test func decode_validPayload_extractsSlotAndActive() {
        var payload = Data()
        payload.appendLE(UInt32(2))
        payload.appendLE(UInt32(1))

        let msg = WireSlotActive.decode(payload)

        #expect(msg?.slot == 2)
        #expect(msg?.active == 1)
    }

    @Test func decode_wrongPayloadSize_returnsNil() {
        let payload = Data(count: 7)

        let msg = WireSlotActive.decode(payload)

        #expect(msg == nil)
    }
}

@Suite("WireDemandUpdate")
struct WireDemandUpdateTests {
    @Test func decode_validPayload_extractsSlotAndFlags() {
        var payload = Data()
        payload.appendLE(UInt32(0))
        payload.appendLE(UInt32(1))
        payload.appendLE(UInt32(0))

        let msg = WireDemandUpdate.decode(payload)

        #expect(msg?.slot == 0)
        #expect(msg?.wantsQR == 1)
        #expect(msg?.wantsFace == 0)
    }

    @Test func decode_wrongPayloadSize_returnsNil() {
        let payload = Data(count: 11)

        let msg = WireDemandUpdate.decode(payload)

        #expect(msg == nil)
    }
}

@Suite("WireRecordingState")
struct WireRecordingStateTests {
    @Test func decode_active_returnsTrueFlag() {
        var payload = Data()
        payload.appendLE(UInt32(1))

        let msg = WireRecordingState.decode(payload)

        #expect(msg?.active == 1)
    }

    @Test func decode_idle_returnsZeroFlag() {
        var payload = Data()
        payload.appendLE(UInt32(0))

        let msg = WireRecordingState.decode(payload)

        #expect(msg?.active == 0)
    }

    @Test func decode_wrongPayloadSize_returnsNil() {
        let payload = Data(count: 3)

        let msg = WireRecordingState.decode(payload)

        #expect(msg == nil)
    }
}

@Suite("WireActiveFormat")
struct WireActiveFormatTests {
    @Test func decode_validPayload_extractsAllFields() {
        var payload = Data()
        payload.appendLE(UInt32(1))
        payload.appendLE(UInt32(1920))
        payload.appendLE(UInt32(1080))
        payload.appendLE(UInt32(0x34323066))

        let msg = WireActiveFormat.decode(payload)

        #expect(msg?.slot == 1)
        #expect(msg?.width == 1920)
        #expect(msg?.height == 1080)
        #expect(msg?.pixelFormat == 0x34323066)
    }

    @Test func decode_wrongPayloadSize_returnsNil() {
        let payload = Data(count: 15)

        let msg = WireActiveFormat.decode(payload)

        #expect(msg == nil)
    }
}

@Suite("WireVideoFrameHeader")
struct WireVideoFrameHeaderTests {
    @Test func encoded_writesExpectedFieldsInOrder() {
        let h = WireVideoFrameHeader(slot: 0, width: 1280, height: 720,
                                      pixelFormat: 0x420f, ptsNs: 1_000_000_000,
                                      durationNs: 33_333_333, bytesLen: 1_382_400)

        let bytes = h.encoded()

        #expect(bytes.count == 40)
        let slot: UInt32 = bytes.readLE(at: 0)
        let width: UInt32 = bytes.readLE(at: 4)
        let height: UInt32 = bytes.readLE(at: 8)
        let pixfmt: UInt32 = bytes.readLE(at: 12)
        let pts: Int64 = Int64(bitPattern: bytes.readLE(at: 16) as UInt64)
        let dur: Int64 = Int64(bitPattern: bytes.readLE(at: 24) as UInt64)
        let bytesLen: UInt32 = bytes.readLE(at: 32)
        #expect(slot == 0)
        #expect(width == 1280)
        #expect(height == 720)
        #expect(pixfmt == 0x420f)
        #expect(pts == 1_000_000_000)
        #expect(dur == 33_333_333)
        #expect(bytesLen == 1_382_400)
    }
}

@Suite("WireAudioFrameHeader")
struct WireAudioFrameHeaderTests {
    @Test func encoded_writesExpectedFieldsInOrder() {
        let h = WireAudioFrameHeader(slot: 2, sampleCount: 1024, sampleRate: 48000,
                                      channels: 1, format: 0x6c70636d,
                                      bitsPerChannel: 32, ptsNs: 21_333_333,
                                      bytesLen: 4096)

        let bytes = h.encoded()

        #expect(bytes.count == 40)
        let slot: UInt32 = bytes.readLE(at: 0)
        let sampleCount: UInt32 = bytes.readLE(at: 4)
        let sampleRate: UInt32 = bytes.readLE(at: 8)
        let channels: UInt32 = bytes.readLE(at: 12)
        let format: UInt32 = bytes.readLE(at: 16)
        let bits: UInt32 = bytes.readLE(at: 20)
        let pts: Int64 = Int64(bitPattern: bytes.readLE(at: 24) as UInt64)
        let bytesLen: UInt32 = bytes.readLE(at: 32)
        #expect(slot == 2)
        #expect(sampleCount == 1024)
        #expect(sampleRate == 48000)
        #expect(channels == 1)
        #expect(format == 0x6c70636d)
        #expect(bits == 32)
        #expect(pts == 21_333_333)
        #expect(bytesLen == 4096)
    }
}

@Suite("WireMetadataResults")
struct WireMetadataResultsTests {
    @Test func encoded_emptyObjects_emitsSlotAndZeroCount() {
        let r = WireMetadataResults(slot: 1, objects: [])

        let bytes = r.encoded()

        #expect(bytes.count == 8)
        let slot: UInt32 = bytes.readLE(at: 0)
        let count: UInt32 = bytes.readLE(at: 4)
        #expect(slot == 1)
        #expect(count == 0)
    }

    @Test func encoded_qrObject_emitsHeaderPlusUtf8Payload() {
        let qr = WireMetadataObject(kind: .qr, faceID: 0,
                                     boundsX: 0.1, boundsY: 0.2,
                                     boundsW: 0.3, boundsH: 0.4,
                                     stringValue: "abc")
        let r = WireMetadataResults(slot: 0, objects: [qr])

        let bytes = r.encoded()

        // 8 (header) + 32 (object header) + 3 (utf8)
        #expect(bytes.count == 8 + 32 + 3)
        let stringLen: UInt32 = bytes.readLE(at: 8 + 24)
        #expect(stringLen == 3)
        let utf8 = bytes.subdata(in: (8 + 32)..<(8 + 32 + 3))
        #expect(String(data: utf8, encoding: .utf8) == "abc")
    }
}

@Suite("Data.framed")
struct DataFramedTests {
    @Test func framed_prependsLengthAndTypeBeforePayload() {
        let payload = Data([0xAA, 0xBB, 0xCC])

        let framed = Data.framed(.helloAck, payload: payload)

        #expect(framed.count == 8 + payload.count)
        let length: UInt32 = framed.readLE(at: 0)
        let type: UInt32 = framed.readLE(at: 4)
        #expect(length == 4 + UInt32(payload.count))
        #expect(type == WireMessageType.helloAck.rawValue)
        #expect(Array(framed.suffix(3)) == [0xAA, 0xBB, 0xCC])
    }
}
