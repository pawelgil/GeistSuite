import CoreMedia
import GeistCameraShimCore
import Testing

struct RecordingTimelineTests {
    @Test
    func AdvanceElapsed_FiniteSourceGapAndInvalidDuration_ProducesFiniteFrameStep() {
        let firstSourceTime = CMTime(value: 55_159_782_042_125, timescale: 1_000_000_000)
        let secondSourceTime = CMTime(value: 55_165_862_042_125, timescale: 1_000_000_000)
        let frameDuration = GeistCamRecordingVideoFrameDuration(.invalid, 25)

        let firstElapsed = GeistCamRecordingAdvanceElapsed(0, .invalid, firstSourceTime, frameDuration)
        let secondElapsed = GeistCamRecordingAdvanceElapsed(
            firstElapsed,
            firstSourceTime,
            secondSourceTime,
            frameDuration
        )

        #expect(firstElapsed == 0)
        #expect(secondElapsed.isFinite)
        expectClose(secondElapsed, 1.0 / 25.0)

        let anchor = CMTime(value: 55_159_782_042_125, timescale: 1_000_000_000)
        let firstTarget = CMTimeAdd(anchor, CMTimeMakeWithSeconds(firstElapsed, preferredTimescale: 600))
        let secondTarget = CMTimeAdd(anchor, CMTimeMakeWithSeconds(secondElapsed, preferredTimescale: 600))
        #expect(firstTarget.isNumeric)
        #expect(secondTarget.isNumeric)
        #expect(CMTimeCompare(secondTarget, firstTarget) > 0)
    }

    @Test(arguments: [CMTime.invalid, CMTime.indefinite, CMTime.positiveInfinity, CMTime.negativeInfinity])
    func AudioFrameDuration_NonnumericDuration_UsesAudioDefault(duration: CMTime) {
        expectClose(GeistCamRecordingAudioFrameDuration(duration), 1024.0 / 48000.0)
    }

    @Test(arguments: [
        CMTime.zero,
        CMTime(value: -1, timescale: 48000),
        CMTime(value: 1001, timescale: 1000),
    ])
    func AudioFrameDuration_OutOfRangeDuration_UsesAudioDefault(duration: CMTime) {
        expectClose(GeistCamRecordingAudioFrameDuration(duration), 1024.0 / 48000.0)
    }

    @Test
    func AudioFrameDuration_ValidDuration_PreservesDuration() {
        expectClose(GeistCamRecordingAudioFrameDuration(CMTime(value: 1, timescale: 48000)), 1.0 / 48000.0)
    }

    @Test(arguments: [0.0, -30.0, .infinity, -.infinity, .nan, .leastNonzeroMagnitude])
    func VideoFrameDuration_InvalidFrameRate_UsesVideoDefault(frameRate: Double) {
        expectClose(GeistCamRecordingVideoFrameDuration(.invalid, frameRate), 1.0 / 30.0)
    }

    @Test(arguments: [CMTime.invalid, CMTime.indefinite, CMTime.positiveInfinity, CMTime.negativeInfinity])
    func VideoFrameDuration_NonnumericDuration_UsesFrameRate(duration: CMTime) {
        expectClose(GeistCamRecordingVideoFrameDuration(duration, 60), 1.0 / 60.0)
    }

    @Test(arguments: [
        CMTime.zero,
        CMTime(value: -1, timescale: 30),
        CMTime(value: 1001, timescale: 1000),
    ])
    func VideoFrameDuration_OutOfRangeDuration_UsesFrameRate(duration: CMTime) {
        expectClose(GeistCamRecordingVideoFrameDuration(duration, 60), 1.0 / 60.0)
    }

    @Test
    func VideoFrameDuration_ValidDuration_PreservesDuration() {
        expectClose(GeistCamRecordingVideoFrameDuration(CMTime(value: 1, timescale: 24), 60), 1.0 / 24.0)
        #expect(GeistCamRecordingVideoFrameDuration(CMTime(value: 1, timescale: 1), 60) == 1)
    }

    @Test(arguments: [
        CMTime(value: 10, timescale: 100),
        CMTime(value: 20, timescale: 100),
        CMTime(value: -10, timescale: 100),
        CMTime(value: 200, timescale: 100),
        CMTime.indefinite,
        CMTime.invalid,
        CMTime.positiveInfinity,
    ])
    func AdvanceElapsed_NonpositiveLargeOrNonfiniteDelta_UsesFallback(currentSourceTime: CMTime) {
        let elapsed = GeistCamRecordingAdvanceElapsed(
            2,
            CMTime(value: 20, timescale: 100),
            currentSourceTime,
            0.04
        )

        expectClose(elapsed, 2.04)
    }

    @Test
    func AdvanceElapsed_NormalDelta_PreservesSourceProgress() {
        let elapsed = GeistCamRecordingAdvanceElapsed(
            2,
            CMTime(value: 20, timescale: 100),
            CMTime(value: 23, timescale: 100),
            0.04
        )

        expectClose(elapsed, 2.03)
        #expect(GeistCamRecordingAdvanceElapsed(
            2,
            CMTime(value: 20, timescale: 100),
            CMTime(value: 120, timescale: 100),
            0.04
        ) == 3)
    }

    @Test
    func AdvanceElapsed_NonfiniteFallback_UsesVideoDefault() {
        let elapsed = GeistCamRecordingAdvanceElapsed(
            2,
            CMTime(value: 20, timescale: 100),
            CMTime(value: 10, timescale: 100),
            .nan
        )

        expectClose(elapsed, 2 + 1.0 / 30.0)
    }

    private func expectClose(_ actual: Double, _ expected: Double) {
        #expect(abs(actual - expected) < 0.000_000_001)
    }
}
