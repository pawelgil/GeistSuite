import Testing
@testable import GeistBroadcast

@Suite("MicQueueWeight") struct MicQueueWeightTests {

    @Test
    func cost_557Float32MonoFramesAt48k_matchesEncodedBytes() {
        let cost = MicQueueWeight.cost(
            encodedByteCount: 52 + 557 * 4,
            frameCount: 557,
            sampleRate: 48_000
        )

        #expect(cost == 2_280)
    }

    @Test
    func cost_558Float32MonoFramesAt48k_matchesEncodedBytes() {
        let cost = MicQueueWeight.cost(
            encodedByteCount: 52 + 558 * 4,
            frameCount: 558,
            sampleRate: 48_000
        )

        #expect(cost == 2_284)
    }

    @Test
    func cost_4800Float32MonoFramesAt48k_matchesMaximumCost() {
        let cost = MicQueueWeight.cost(
            encodedByteCount: 52 + 4_800 * 4,
            frameCount: 4_800,
            sampleRate: 48_000
        )

        #expect(cost == MicQueueWeight.maximumCost)
    }

    @Test
    func cost_int16Mono_reservesEquivalent48kDuration() {
        let cost = MicQueueWeight.cost(
            encodedByteCount: 52 + 557 * 2,
            frameCount: 557,
            sampleRate: 48_000
        )

        #expect(cost == 2_280)
    }

    @Test
    func cost_lowSampleRate_reservesEquivalent48kDuration() {
        let cost = MicQueueWeight.cost(
            encodedByteCount: 52 + 557 * 4,
            frameCount: 557,
            sampleRate: 24_000
        )

        #expect(cost == 4_508)
    }

    @Test
    func cost_stereo_usesLargerEncodedByteCount() {
        let cost = MicQueueWeight.cost(
            encodedByteCount: 52 + 557 * 4 * 2,
            frameCount: 557,
            sampleRate: 48_000
        )

        #expect(cost == 4_508)
    }

    @Test
    func cost_highSampleRate_usesLargerEncodedByteCount() {
        let cost = MicQueueWeight.cost(
            encodedByteCount: 52 + 557 * 4,
            frameCount: 557,
            sampleRate: 96_000
        )

        #expect(cost == 2_280)
    }

    @Test
    func cost_twoSecondBuffer_isCapped() {
        let cost = MicQueueWeight.cost(
            encodedByteCount: 52 + 96_000 * 4,
            frameCount: 96_000,
            sampleRate: 48_000
        )

        #expect(cost == MicQueueWeight.maximumCost)
    }

    @Test
    func cost_invalidSampleRate_fallsBackToCappedPositiveEncodedBytes() {
        #expect(MicQueueWeight.cost(encodedByteCount: 0, frameCount: 557, sampleRate: 0) == 1)
        #expect(MicQueueWeight.cost(encodedByteCount: .max, frameCount: 557, sampleRate: .nan) == MicQueueWeight.maximumCost)
    }

    @Test
    func cost_intMaxFramesAtTinyFiniteSampleRate_capsBeforeIntegerConversion() {
        let cost = MicQueueWeight.cost(
            encodedByteCount: 1,
            frameCount: .max,
            sampleRate: .leastNonzeroMagnitude
        )

        #expect(cost == MicQueueWeight.maximumCost)
    }

    @Test
    func weightedQueue_sixteenMaximumCostPacketsFitAndSeventeenthDrops() {
        let sut = BoundedFrameQueue<Int>(maximumWeight: 308_032, maximumCount: 256)
        let weight = MicQueueWeight.cost(
            encodedByteCount: .max,
            frameCount: 96_000,
            sampleRate: 48_000
        )

        for frame in 1 ... 16 {
            #expect(sut.enqueueOrDropNewest(frame, weight: weight) == .accepted)
        }

        #expect(sut.enqueueOrDropNewest(17, weight: weight) == .dropped)
    }

    @Test
    func weightedQueue_smallSpeechPacketsFit135BeforeWeightLimit() {
        let sut = BoundedFrameQueue<Int>(maximumWeight: 308_032, maximumCount: 256)
        let weight = MicQueueWeight.cost(
            encodedByteCount: 52 + 557 * 4,
            frameCount: 557,
            sampleRate: 48_000
        )

        for frame in 1 ... 135 {
            #expect(sut.enqueueOrDropNewest(frame, weight: weight) == .accepted)
        }

        #expect(sut.enqueueOrDropNewest(136, weight: weight) == .dropped)
    }

    @Test
    func weightedQueue_countCeilingDropsPacket257DespiteRemainingWeight() {
        let sut = BoundedFrameQueue<Int>(maximumWeight: 308_032, maximumCount: 256)

        for frame in 1 ... 256 {
            #expect(sut.enqueueOrDropNewest(frame, weight: 1) == .accepted)
        }

        #expect(sut.enqueueOrDropNewest(257, weight: 1) == .dropped)
    }
}
