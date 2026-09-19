import Foundation

enum MicQueueWeight {
    private static let nominalBytesPerFrame = 4.0
    private static let nominalSampleRate = 48_000.0
    static let maximumCost = FrameHeader.byteCount + 4_800 * 4

    static func cost(
        encodedByteCount: Int,
        frameCount: Int,
        sampleRate: Double
    ) -> Int {
        let cappedEncodedByteCount = min(max(encodedByteCount, 1), maximumCost)
        guard sampleRate.isFinite, sampleRate > 0 else {
            return cappedEncodedByteCount
        }

        let durationCost = Double(FrameHeader.byteCount) + ceil(
            Double(frameCount) / sampleRate * nominalSampleRate * nominalBytesPerFrame
        )
        let cappedCost = min(
            Double(maximumCost),
            max(Double(cappedEncodedByteCount), durationCost)
        )
        return Int(cappedCost)
    }
}
