import Testing
@testable import GeistBroadcast

@Suite("FrameQueueScheduler") struct FrameQueueSchedulerTests {

    @Test
    func runIteration_prefilledAudioAndVideo_writesAudioFIFOThenVideo() {
        let audioQueue = BoundedFrameQueue<Int>(capacity: 16)
        let videoQueue = BoundedFrameQueue<Int>(capacity: 1)
        for frame in 1 ... 16 {
            #expect(audioQueue.enqueueOrDropNewest(frame) == .accepted)
        }
        #expect(videoQueue.enqueueOrDropNewest(100) == .accepted)
        let sut = FrameQueueScheduler<Int>(maximumAudioBurst: 16)
        var written: [Int] = []

        let result = sut.runIteration(audioQueue: audioQueue, videoQueue: videoQueue) {
            written.append($0)
            return true
        }

        #expect(result == .wroteFrames)
        #expect(written == Array(1 ... 16) + [100])
    }

    @Test
    func runIteration_continuouslyReplenishedAudio_offersVideoAfterBoundedBurst() {
        let audioQueue = BoundedFrameQueue<Int>(capacity: 16)
        let videoQueue = BoundedFrameQueue<Int>(capacity: 1)
        for frame in 1 ... 16 {
            #expect(audioQueue.enqueueOrDropNewest(frame) == .accepted)
        }
        #expect(videoQueue.enqueueOrDropNewest(100) == .accepted)
        let sut = FrameQueueScheduler<Int>(maximumAudioBurst: 16)
        var nextAudioFrame = 17
        var written: [Int] = []

        let result = sut.runIteration(audioQueue: audioQueue, videoQueue: videoQueue) { frame in
            written.append(frame)
            if frame != 100 {
                #expect(audioQueue.enqueueOrDropNewest(nextAudioFrame) == .accepted)
                nextAudioFrame += 1
            }
            return true
        }

        #expect(result == .wroteFrames)
        #expect(written == Array(1 ... 16) + [100])
        #expect(audioQueue.dequeue(timeoutSeconds: 0) == .received(17))
    }

    @Test
    func runIteration_openEmptyQueues_returnsIdle() {
        let audioQueue = BoundedFrameQueue<Int>(capacity: 16)
        let videoQueue = BoundedFrameQueue<Int>(capacity: 1)
        let sut = FrameQueueScheduler<Int>(maximumAudioBurst: 16)
        var writeCount = 0

        let result = sut.runIteration(audioQueue: audioQueue, videoQueue: videoQueue) { _ in
            writeCount += 1
            return true
        }

        #expect(result == .idle)
        #expect(writeCount == 0)
    }

    @Test
    func runIteration_oneQueueClosedAndOtherEmpty_returnsIdle() {
        let audioQueue = BoundedFrameQueue<Int>(capacity: 16)
        let videoQueue = BoundedFrameQueue<Int>(capacity: 1)
        audioQueue.close()
        let sut = FrameQueueScheduler<Int>(maximumAudioBurst: 16)

        let result = sut.runIteration(
            audioQueue: audioQueue,
            videoQueue: videoQueue,
            write: { _ in true }
        )

        #expect(result == .idle)
    }

    @Test
    func runIteration_closedAudioAndQueuedVideo_writesVideo() {
        let audioQueue = BoundedFrameQueue<Int>(capacity: 16)
        let videoQueue = BoundedFrameQueue<Int>(capacity: 1)
        audioQueue.close()
        #expect(videoQueue.enqueueOrDropNewest(100) == .accepted)
        let sut = FrameQueueScheduler<Int>(maximumAudioBurst: 16)
        var written: [Int] = []

        let result = sut.runIteration(audioQueue: audioQueue, videoQueue: videoQueue) {
            written.append($0)
            return true
        }

        #expect(result == .wroteFrames)
        #expect(written == [100])
    }

    @Test
    func runIteration_queuedAudioAndClosedVideo_writesAudio() {
        let audioQueue = BoundedFrameQueue<Int>(capacity: 16)
        let videoQueue = BoundedFrameQueue<Int>(capacity: 1)
        #expect(audioQueue.enqueueOrDropNewest(1) == .accepted)
        #expect(audioQueue.enqueueOrDropNewest(2) == .accepted)
        videoQueue.close()
        let sut = FrameQueueScheduler<Int>(maximumAudioBurst: 16)
        var written: [Int] = []

        let result = sut.runIteration(audioQueue: audioQueue, videoQueue: videoQueue) {
            written.append($0)
            return true
        }

        #expect(result == .wroteFrames)
        #expect(written == [1, 2])
    }

    @Test
    func runIteration_bothQueuesClosed_returnsFinished() {
        let audioQueue = BoundedFrameQueue<Int>(capacity: 16)
        let videoQueue = BoundedFrameQueue<Int>(capacity: 1)
        audioQueue.close()
        videoQueue.close()
        let sut = FrameQueueScheduler<Int>(maximumAudioBurst: 16)

        let result = sut.runIteration(
            audioQueue: audioQueue,
            videoQueue: videoQueue,
            write: { _ in true }
        )

        #expect(result == .finished)
    }

    @Test
    func runIteration_writeFailure_stopsBeforeLaterFrames() {
        let audioQueue = BoundedFrameQueue<Int>(capacity: 16)
        let videoQueue = BoundedFrameQueue<Int>(capacity: 1)
        #expect(audioQueue.enqueueOrDropNewest(1) == .accepted)
        #expect(audioQueue.enqueueOrDropNewest(2) == .accepted)
        #expect(videoQueue.enqueueOrDropNewest(100) == .accepted)
        let sut = FrameQueueScheduler<Int>(maximumAudioBurst: 16)

        let result = sut.runIteration(
            audioQueue: audioQueue,
            videoQueue: videoQueue,
            write: { _ in false }
        )

        #expect(result == .finished)
        #expect(audioQueue.dequeue(timeoutSeconds: 0) == .received(2))
        #expect(videoQueue.dequeue(timeoutSeconds: 0) == .received(100))
    }

    @Test
    func runIteration_videoWriteFailureAfterAudioSuccess_returnsFinished() {
        let audioQueue = BoundedFrameQueue<Int>(capacity: 16)
        let videoQueue = BoundedFrameQueue<Int>(capacity: 1)
        #expect(audioQueue.enqueueOrDropNewest(1) == .accepted)
        #expect(videoQueue.enqueueOrDropNewest(100) == .accepted)
        let sut = FrameQueueScheduler<Int>(maximumAudioBurst: 16)
        var shouldSucceed = true

        let result = sut.runIteration(audioQueue: audioQueue, videoQueue: videoQueue) { _ in
            defer { shouldSucceed = false }
            return shouldSucceed
        }

        #expect(result == .finished)
        #expect(audioQueue.dequeue(timeoutSeconds: 0) == .empty)
        #expect(videoQueue.dequeue(timeoutSeconds: 0) == .empty)
    }
}
