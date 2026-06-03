import CoreVideo

/// SDR-only. HDR/10-bit variants (`x420`, `xf20`) are out of scope for v1;
/// depth/disparity goes through AVCaptureDepthDataOutput, not here.
public enum PixelFormat: Hashable, Sendable {
    case yuv420FullRange    // kCVPixelFormatType_420YpCbCr8BiPlanarFullRange — default
    case yuv420VideoRange   // kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    case bgra32             // kCVPixelFormatType_32BGRA
}

extension PixelFormat {
    var osType: OSType {
        switch self {
        case .yuv420FullRange:  return kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        case .yuv420VideoRange: return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case .bgra32:           return kCVPixelFormatType_32BGRA
        }
    }

    init?(osType: OSType) {
        switch osType {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:  self = .yuv420FullRange
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: self = .yuv420VideoRange
        case kCVPixelFormatType_32BGRA:                       self = .bgra32
        default: return nil
        }
    }
}
