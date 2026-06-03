import CoreVideo
import Foundation
import Testing
@testable import GeistCamera

@Suite("Yuv420RangeRemap")
struct Yuv420RangeRemapTests {
    private static let full = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    private static let video = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    private static let bgra = kCVPixelFormatType_32BGRA

    // 2x2 frame: 4 luma bytes + 2 interleaved CbCr bytes.
    private static func planar(luma: [UInt8], chroma: [UInt8]) -> Data {
        Data(luma + chroma)
    }

    @Test func init_identicalFormat_returnsNil() {
        #expect(Yuv420RangeRemap(from: Self.full, to: Self.full) == nil)
        #expect(Yuv420RangeRemap(from: Self.video, to: Self.video) == nil)
    }

    @Test func init_nonYUVFormat_returnsNil() {
        #expect(Yuv420RangeRemap(from: Self.bgra, to: Self.video) == nil)
        #expect(Yuv420RangeRemap(from: Self.full, to: Self.bgra) == nil)
    }

    @Test func init_fullVideoPair_succeeds() {
        #expect(Yuv420RangeRemap(from: Self.full, to: Self.video) != nil)
        #expect(Yuv420RangeRemap(from: Self.video, to: Self.full) != nil)
    }

    @Test func remapped_fullToVideo_mapsLumaToStudioRange() {
        let remap = Yuv420RangeRemap(from: Self.full, to: Self.video)!
        let out = Array(remap.remapped(
            planar420: Self.planar(luma: [0, 255, 64, 192], chroma: [128, 128]),
            width: 2, height: 2))
        #expect(out[0] == 16)    // full black → studio black
        #expect(out[1] == 235)   // full white → studio white
        #expect(out[2] > 16 && out[2] < out[3] && out[3] < 235)  // monotonic, inside range
    }

    @Test func remapped_fullToVideo_mapsChromaToStudioRange() {
        let remap = Yuv420RangeRemap(from: Self.full, to: Self.video)!
        let out = Array(remap.remapped(
            planar420: Self.planar(luma: [128, 128, 128, 128], chroma: [0, 255]),
            width: 2, height: 2))
        #expect(out[4] == 16)    // chroma low → 16
        #expect(out[5] == 240)   // chroma high → 240
    }

    @Test func remapped_neutralChromaIsPreserved() {
        let remap = Yuv420RangeRemap(from: Self.full, to: Self.video)!
        let out = Array(remap.remapped(
            planar420: Self.planar(luma: [128, 128, 128, 128], chroma: [128, 128]),
            width: 2, height: 2))
        #expect(out[4] == 128)
        #expect(out[5] == 128)
    }

    @Test func remapped_videoToFull_mapsLumaToFullRange() {
        let remap = Yuv420RangeRemap(from: Self.video, to: Self.full)!
        let out = Array(remap.remapped(
            planar420: Self.planar(luma: [16, 235, 16, 235], chroma: [128, 128]),
            width: 2, height: 2))
        #expect(out[0] == 0)
        #expect(out[1] == 255)
    }
}
