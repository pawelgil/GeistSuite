import CoreMedia
import Foundation
import GeistScreenCaptureShimCore

struct FrameHeader: Equatable {
    static let byteCount = MemoryLayout<geist_sck_frame_header_t>.size

    let streamType: UInt32
    let pixelFormatFourCC: UInt32
    let width: UInt32
    let height: UInt32
    let bytesPerRowPlane0: UInt32
    let bytesPerRowPlane1: UInt32
    let audioSampleRate: UInt32
    let audioChannelCount: UInt32
    let audioSampleFormat: UInt32
    let audioInterleaved: UInt32
    let audioSampleCount: UInt32
    let payloadSize: UInt32
    let timestampSeconds: UInt32
    let timestampNanoseconds: UInt32

    init(
        streamType: UInt32,
        pixelFormatFourCC: UInt32 = 0,
        width: UInt32 = 0,
        height: UInt32 = 0,
        bytesPerRowPlane0: UInt32 = 0,
        bytesPerRowPlane1: UInt32 = 0,
        audioSampleRate: UInt32 = 0,
        audioChannelCount: UInt32 = 0,
        audioSampleFormat: UInt32 = 0,
        audioInterleaved: UInt32 = 0,
        audioSampleCount: UInt32 = 0,
        payloadSize: UInt32,
        presentationTime: CMTime = .zero
    ) {
        self.streamType = streamType
        self.pixelFormatFourCC = pixelFormatFourCC
        self.width = width
        self.height = height
        self.bytesPerRowPlane0 = bytesPerRowPlane0
        self.bytesPerRowPlane1 = bytesPerRowPlane1
        self.audioSampleRate = audioSampleRate
        self.audioChannelCount = audioChannelCount
        self.audioSampleFormat = audioSampleFormat
        self.audioInterleaved = audioInterleaved
        self.audioSampleCount = audioSampleCount
        self.payloadSize = payloadSize
        let nanoseconds = CMTimeConvertScale(presentationTime, timescale: 1_000_000_000, method: .default).value
        timestampSeconds = UInt32(clamping: max(0, nanoseconds) / 1_000_000_000)
        timestampNanoseconds = UInt32(max(0, nanoseconds) % 1_000_000_000)
    }

    private init(raw: geist_sck_frame_header_t) {
        streamType = raw.streamType
        pixelFormatFourCC = raw.pixelFormatFourCC
        width = raw.width
        height = raw.height
        bytesPerRowPlane0 = raw.bytesPerRowPlane0
        bytesPerRowPlane1 = raw.bytesPerRowPlane1
        audioSampleRate = raw.audioSampleRate
        audioChannelCount = raw.audioChannelCount
        audioSampleFormat = raw.audioSampleFormat
        audioInterleaved = raw.audioInterleaved
        audioSampleCount = raw.audioSampleCount
        payloadSize = raw.payloadSize
        timestampSeconds = raw.timestampSeconds
        timestampNanoseconds = raw.timestampNanoseconds
    }

    static func decode(_ data: Data) -> FrameHeader? {
        guard data.count >= byteCount else { return nil }
        let raw = data.withUnsafeBytes {
            $0.loadUnaligned(as: geist_sck_frame_header_t.self)
        }
        guard raw.magic == GEIST_SCK_WIRE_MAGIC else { return nil }
        return FrameHeader(raw: raw)
    }

    func encode() -> Data {
        var raw = geist_sck_frame_header_t(
            magic: GEIST_SCK_WIRE_MAGIC,
            streamType: streamType,
            pixelFormatFourCC: pixelFormatFourCC,
            width: width,
            height: height,
            bytesPerRowPlane0: bytesPerRowPlane0,
            bytesPerRowPlane1: bytesPerRowPlane1,
            audioSampleRate: audioSampleRate,
            audioChannelCount: audioChannelCount,
            audioSampleFormat: audioSampleFormat,
            audioInterleaved: audioInterleaved,
            audioSampleCount: audioSampleCount,
            payloadSize: payloadSize,
            timestampSeconds: timestampSeconds,
            timestampNanoseconds: timestampNanoseconds
        )
        return withUnsafeBytes(of: &raw) { Data($0) }
    }
}
