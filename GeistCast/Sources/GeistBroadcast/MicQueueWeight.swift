import Foundation

enum MicQueueWeight {
    // MARK: Static Properties

    static let maximumCost = FrameHeader.byteCount + 4800 * 4

    private static let nominalBytesPerFrame = 4.0
    private static let nominalSampleRate = 48000.0

    // MARK: Static Functions

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
