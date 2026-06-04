import Testing
@testable import GeistCamera

@Suite("FrameHeartbeat")
struct FrameHeartbeatTests {
    @Test func read_neverMarked_returnsZero() {
        let beat = FrameHeartbeat()

        let value = beat.read()

        #expect(value == 0)
    }

    @Test func read_afterMark_returnsNonZero() {
        let beat = FrameHeartbeat()

        beat.mark()

        #expect(beat.read() != 0)
    }

    @Test func read_afterSecondMark_returnsAtLeastFirstValue() {
        let beat = FrameHeartbeat()

        beat.mark()
        let first = beat.read()
        beat.mark()
        let second = beat.read()

        #expect(second >= first)
    }
}
