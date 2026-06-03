import Accelerate
import CoreVideo
import Foundation

/// Remaps 8-bit 4:2:0 bi-planar pixel data between full range (`420f`, luma and
/// chroma 0–255) and video range (`420v`, luma 16–235, chroma 16–240). The two
/// formats are byte-identical in layout and differ only in numeric range, so the
/// conversion is a per-sample table lookup over the already-serialized planar
/// bytes.
struct Yuv420RangeRemap {
    private let lumaLUT: [UInt8]
    private let chromaLUT: [UInt8]

    /// A remap from `source` to `dest`, or nil when the pair isn't a
    /// full↔video 4:2:0 conversion (identical formats, or any non-420 format).
    init?(from source: OSType, to dest: OSType) {
        guard let s = Self.range(of: source),
              let d = Self.range(of: dest),
              s != d else { return nil }
        switch (s, d) {
        case (.full, .video):
            lumaLUT = Self.lut(Self.fullToVideoLuma)
            chromaLUT = Self.lut(Self.fullToVideoChroma)
        case (.video, .full):
            lumaLUT = Self.lut(Self.videoToFullLuma)
            chromaLUT = Self.lut(Self.videoToFullChroma)
        default:
            return nil
        }
    }

    /// Range-converts tightly-packed planar 4:2:0 bytes: `width*height` luma
    /// bytes followed by `width*height/2` interleaved CbCr bytes. Runs on the
    /// camera's capture queue per frame, so the lookup is SIMD (vImage) rather
    /// than a scalar loop — a scalar loop in a `-Onone` build is slow enough at
    /// full camera resolution to make AVCaptureSession drop frames.
    func remapped(planar420 data: Data, width: Int, height: Int) -> Data {
        let lumaCount = width * height
        var out = data
        out.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress, raw.count >= lumaCount + lumaCount / 2 else { return }
            var luma = vImage_Buffer(data: base,
                                     height: vImagePixelCount(height),
                                     width: vImagePixelCount(width),
                                     rowBytes: width)
            lumaLUT.withUnsafeBufferPointer { lut in
                _ = vImageTableLookUp_Planar8(&luma, &luma, lut.baseAddress!, vImage_Flags(kvImageNoFlags))
            }
            var chroma = vImage_Buffer(data: base.advanced(by: lumaCount),
                                       height: vImagePixelCount(height / 2),
                                       width: vImagePixelCount(width),
                                       rowBytes: width)
            chromaLUT.withUnsafeBufferPointer { lut in
                _ = vImageTableLookUp_Planar8(&chroma, &chroma, lut.baseAddress!, vImage_Flags(kvImageNoFlags))
            }
        }
        return out
    }

    private enum Range { case full, video }

    private static func range(of osType: OSType) -> Range? {
        switch osType {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:  return .full
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: return .video
        default: return nil
        }
    }

    private static func lut(_ transform: (Int) -> Int) -> [UInt8] {
        (0...255).map { UInt8(clamping: transform($0)) }
    }

    // Rec. 601/709 8-bit: video-range luma spans 16–235 (219), chroma 16–240 (224).
    private static func fullToVideoLuma(_ v: Int)   -> Int { Int((Double(v) * 219.0 / 255.0).rounded()) + 16 }
    private static func fullToVideoChroma(_ v: Int) -> Int { Int((Double(v - 128) * 224.0 / 255.0).rounded()) + 128 }
    private static func videoToFullLuma(_ v: Int)   -> Int { Int((Double(v - 16) * 255.0 / 219.0).rounded()) }
    private static func videoToFullChroma(_ v: Int) -> Int { Int((Double(v - 128) * 255.0 / 224.0).rounded()) + 128 }
}
