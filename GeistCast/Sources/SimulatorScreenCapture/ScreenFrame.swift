import CoreVideo

/// @unchecked Sendable: properties are immutable; `CVPixelBuffer` is
/// thread-safe but lacks `Sendable`.
public struct ScreenFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    /// Nanoseconds since the underlying frame source started delivering.
    public let timestampNs: Int64

    public init(pixelBuffer: CVPixelBuffer, timestampNs: Int64) {
        self.pixelBuffer = pixelBuffer
        self.timestampNs = timestampNs
    }
}
