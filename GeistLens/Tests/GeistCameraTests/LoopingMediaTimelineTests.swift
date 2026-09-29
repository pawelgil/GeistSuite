import CoreMedia
@testable import GeistCamera
import Testing

struct LoopingMediaTimelineTests {
    @Test func presentation_resumedFirstCycle_usesRemainingDuration() {
        var sut = createSUT()
        let resumedFrame = sut.presentationTime(for: CMTime(value: 45, timescale: 30))

        sut.advanceCycle()
        let loopStart = sut.presentationTime(for: .zero)

        #expect(resumedFrame == CMTime(seconds: 100, preferredTimescale: 30))
        #expect(loopStart - resumedFrame == CMTime(value: 15, timescale: 30))
    }

    @Test func presentation_multipleCycles_preservesTrackOffset() {
        var sut = createSUT()
        _ = sut.presentationTime(for: .zero)
        sut.advanceCycle()
        sut.advanceCycle()

        let audio = sut.presentationTime(for: .zero)
        let video = sut.presentationTime(for: CMTime(value: 9, timescale: 30))

        #expect(audio == CMTime(seconds: 104, preferredTimescale: 30))
        #expect(video - audio == CMTime(value: 9, timescale: 30))
    }

    @Test func presentation_fractionalFrameBoundary_retainsExactTime() {
        var sut = createSUT()
        _ = sut.presentationTime(for: CMTime(value: 58, timescale: 30))

        sut.advanceCycle()
        let next = sut.presentationTime(for: .zero)

        #expect(next == CMTime(value: 3002, timescale: 30))
    }

    private func createSUT() -> LoopingMediaTimeline {
        LoopingMediaTimeline(start: CMTime(value: 100, timescale: 1), cycleDuration: CMTime(value: 2, timescale: 1))
    }
}
