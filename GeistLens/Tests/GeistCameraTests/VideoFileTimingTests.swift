import AVFoundation
import Foundation
import GeistCamera
import Synchronization
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct VideoFileTimingTests {
    @Test func playback_threeCycles_preservesEveryFrameAndCadence() async throws {
        let sut = try createSUT()

        let trace = try await record(sut, frames: 125)

        #expect(trace.video.map(\.marker) == trace.video.indices.map { $0 % 60 })
        expectVideoTimeline(trace.video)
        expectAudioTimeline(trace.audio)
    }

    @Test func playback_loopBoundary_deliversAtPresentationPace() async throws {
        let sut = try createSUT()

        let trace = try await record(sut, frames: 65)

        expectRealtimeDelivery(trace.video)
        expectRealtimeDelivery(trace.audio)
    }

    @Test func playback_compressedAudio_loopsWithContinuousTimestamps() async throws {
        let sut = try createSUT("AVTwoSeconds", fileExtension: "mp4")

        let trace = try await record(sut, frames: 65)

        expectVideoTimeline(trace.video)
        expectAudioTimeline(trace.audio)
    }

    @Test(arguments: ["TimingMarkers", "OffsetTimingMarkers"])
    func playback_trackOffsets_preservesContentSyncAcrossLoops(fixture: String) async throws {
        let sut = try createSUT(fixture)

        let trace = try await record(sut, frames: 125)

        expectContentSync(trace, videoOffset: fixture == "OffsetTimingMarkers" ? 0.3 : 0)
        #expect(trace.audio.reduce(0) { $0 + $1.duration } >= 4)
        let videoStart = try #require(trace.video.first { $0.marker == 0 }).pts
        let audioStart = try #require(trace.audio.first).pts
        #expect(abs(videoStart - audioStart - (fixture == "OffsetTimingMarkers" ? 0.3 : 0)) < 0.002)
        expectCycleSpacing(trace, period: fixture == "OffsetTimingMarkers" ? 2.3 : 2)
    }

    @Test(arguments: [15, 45, 59])
    func resume_midFile_doesNotInsertTimelineHoleAtEOF(frame: Int) async throws {
        let sut = try createSUT()
        _ = try await record(sut, frames: frame)

        let resumed = try await record(sut, frames: 60 - frame + 6)

        expectVideoTimeline(resumed.video)
        expectAudioTimeline(resumed.audio)
        expectContentSync(resumed)
    }

    @Test func resume_midFile_keepsHostClockAndContentSync() async throws {
        let sut = try createSUT()
        let before = try await record(sut, frames: 31)

        let after = try await record(sut, frames: 10)

        let last = try #require(before.video.last)
        let first = try #require(after.video.first)
        #expect(first.pts > last.pts)
        expectContentSync(after)
    }

    @Test func reformat_midFile_preservesLoopCadenceAndContentSync() async throws {
        let sut = try createSUT()
        let sink = TimingSinkSpy()
        try sut.start(into: sink)
        defer { sut.stop() }
        _ = try await sink.waitForVideoFrames(31)

        sut.reformat(to: VideoSlotFormat(width: 64, height: 48, pixelFormat: .yuv420FullRange))
        let trace = try await sink.waitForVideoFrames(35, format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)

        let reformatted = try trace.withVideoFormat(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        #expect(reformatted.video.count >= 35)
        expectVideoTimeline(reformatted.video)
        expectAudioTimeline(reformatted.audio)
        expectContentSync(reformatted)
    }

    @Test func stop_repeatedResume_preservesHostClockAndContentSync() async throws {
        let sut = try createSUT()
        let first = try await record(sut, frames: 12)
        let second = try await record(sut, frames: 12)
        let third = try await record(sut, frames: 12)

        try expectHostClockAdvances(before: first, after: second)
        try expectHostClockAdvances(before: second, after: third)
        expectContentSync(second)
        expectContentSync(third)
    }

    @Test func resume_afterWallClockPause_doesNotSkipContent() async throws {
        let sut = try createSUT()
        let paused = try await pause(sut, afterFrames: 31)

        let resumed = try await record(sut, frames: 10)

        let last = try #require(paused.video.last)
        let first = try #require(resumed.video.first)
        #expect([last.marker, (last.marker + 1) % 60].contains(first.marker))
        #expect(first.pts - last.pts >= 0.3)
        expectContentSync(resumed)
    }

    @Test func playback_videoOnly_loopsWithoutWaitingForAudio() async throws {
        let sut = try createSUT("VideoOnlyTimingMarkers")

        let trace = try await record(sut, frames: 65)

        #expect(!sut.hasAudio)
        #expect(trace.audio.isEmpty)
        #expect(trace.video.map(\.marker) == trace.video.indices.map { $0 % 60 })
        expectVideoTimeline(trace.video)
    }

    @Test func init_missingFile_reportsNoVideoTrack() {
        #expect(throws: VideoFileMediaSourceError.noVideoTrack) {
            try VideoFileMediaSource(url: URL(fileURLWithPath: "/missing-\(UUID()).mov"))
        }
    }

    private func createSUT(_ fixture: String = "TimingMarkers", fileExtension: String = "mov") throws -> VideoFileMediaSource {
        let url = try #require(Bundle.module.url(forResource: fixture, withExtension: fileExtension))
        let source = try VideoFileMediaSource(url: url)
        source.reformat(to: VideoSlotFormat(width: 64, height: 48, pixelFormat: .yuv420VideoRange))
        return source
    }

    private func record(_ source: VideoFileMediaSource, frames: Int) async throws -> MediaTimingTrace {
        let sink = TimingSinkSpy()
        try source.start(into: sink)
        defer { source.stop() }
        return try await sink.waitForVideoFrames(frames)
    }

    private func pause(_ source: VideoFileMediaSource, afterFrames: Int) async throws -> MediaTimingTrace {
        let sink = TimingSinkSpy()
        try source.start(into: sink)
        defer { source.stop() }
        _ = try await sink.waitForVideoFrames(afterFrames)
        source.stop()
        let stopped = sink.snapshot
        // This interval is the pause being tested, not a readiness delay.
        try await Task.sleep(for: .milliseconds(350))
        let settled = sink.snapshot
        let inFlight = settled.video.count + settled.audio.count - stopped.video.count - stopped.audio.count
        #expect(inFlight <= 1)
        return settled
    }

    private func expectVideoTimeline(_ samples: [TimedMediaSample], sourceLocation: SourceLocation = #_sourceLocation) {
        let gaps = zip(samples, samples.dropFirst()).map { $1.pts - $0.pts }
        #expect(!gaps.isEmpty, sourceLocation: sourceLocation)
        #expect(gaps.allSatisfy { abs($0 - 1.0 / 30) < 0.002 },
                "Video PTS gaps: min=\(gaps.min() ?? 0), max=\(gaps.max() ?? 0)", sourceLocation: sourceLocation)
    }

    private func expectAudioTimeline(_ samples: [TimedMediaSample], sourceLocation: SourceLocation = #_sourceLocation) {
        let gaps = zip(samples, samples.dropFirst()).map { $1.pts - ($0.pts + $0.duration) }
        #expect(!gaps.isEmpty, sourceLocation: sourceLocation)
        #expect(gaps.allSatisfy { abs($0) < 0.002 },
                "Audio discontinuities: min=\(gaps.min() ?? 0), max=\(gaps.max() ?? 0)", sourceLocation: sourceLocation)
    }

    private func expectRealtimeDelivery(_ samples: [TimedMediaSample], sourceLocation: SourceLocation = #_sourceLocation) {
        let lateness = samples.dropFirst(2).map { $0.received - $0.pts }
        #expect(lateness.allSatisfy { $0 >= -0.005 && $0 < 0.5 },
                "Delivery lateness: min=\(lateness.min() ?? 0), max=\(lateness.max() ?? 0)", sourceLocation: sourceLocation)
    }

    private func expectContentSync(_ trace: MediaTimingTrace, videoOffset: Double = 0,
                                   sourceLocation: SourceLocation = #_sourceLocation)
    {
        let errors = trace.video.filter { $0.marker >= 0 }.compactMap { video -> (error: Double, video: Int, audio: Double, distance: Double)? in
            guard let audio = trace.audio.min(by: { abs($0.pts - video.pts) < abs($1.pts - video.pts) }),
                  abs(audio.pts - video.pts) < 0.08 else { return nil }
            let videoOrigin = video.pts - (Double(video.marker) / 30 + videoOffset)
            let audioOrigin = audio.pts - audio.contentTime
            // Across EOF the two closest samples can belong to adjacent cycles.
            let period = 2 + videoOffset
            return ((videoOrigin - audioOrigin).remainder(dividingBy: period), video.marker, audio.contentTime, video.pts - audio.pts)
        }
        #expect(errors.count > trace.video.count / 2, sourceLocation: sourceLocation)
        #expect(errors.allSatisfy { abs($0.error) < 0.002 },
                "Content A/V phase mismatches: \(errors.filter { abs($0.error) >= 0.002 })", sourceLocation: sourceLocation)
    }

    private func expectCycleSpacing(_ trace: MediaTimingTrace, period: Double,
                                    sourceLocation: SourceLocation = #_sourceLocation)
    {
        let videoStarts = trace.video.filter { $0.marker == 0 }.map(\.pts)
        let audioStarts = trace.audio.filter { abs($0.contentTime) < 0.000001 }.map(\.pts)
        #expect(videoStarts.count >= 3 && audioStarts.count >= 3, sourceLocation: sourceLocation)
        let spacings = zip(videoStarts, videoStarts.dropFirst()).map { $1 - $0 }
            + zip(audioStarts, audioStarts.dropFirst()).map { $1 - $0 }
        #expect(spacings.allSatisfy { abs($0 - period) < 0.000001 }, sourceLocation: sourceLocation)
    }

    private func expectHostClockAdvances(before: MediaTimingTrace, after: MediaTimingTrace) throws {
        let last = try #require(before.video.last)
        let first = try #require(after.video.first)
        #expect(first.pts > last.pts)
    }
}

private struct TimedMediaSample {
    let pts: Double
    let received: Double
    let duration: Double
    let marker: Int
    let contentTime: Double
    var pixelFormat: OSType?
}

private struct MediaTimingTrace {
    // MARK: Properties

    var video: [TimedMediaSample] = []
    var audio: [TimedMediaSample] = []

    // MARK: Functions

    func withVideoFormat(_ format: OSType) throws -> Self {
        let matching = video.filter { $0.pixelFormat == format }
        let start = try #require(matching.first).pts
        return Self(video: matching, audio: audio.filter { $0.pts >= start })
    }
}

private final class TimingSinkSpy: MediaSink {
    // MARK: Nested Types

    private struct State {
        var trace = MediaTimingTrace()
        var listener: AsyncStream<Void>.Continuation?
    }

    private enum ObservationError: Error { case timeout(videoFrames: Int) }

    // MARK: Properties

    private let state = Mutex(State())

    // MARK: Computed Properties

    var snapshot: MediaTimingTrace {
        state.withLock { $0.trace }
    }

    // MARK: Functions

    func sendVideo(_ pixelBuffer: CVPixelBuffer, pts: CMTime, duration: CMTime) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let luma = base.map { Double($0.load(as: UInt8.self)) } ?? -.infinity
        let limitedLuma = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ? (luma * 219 / 255 + 16).rounded() : luma
        let marker = limitedLuma.isFinite ? Int(limitedLuma) - 32 : -1
        append(TimedMediaSample(pts: pts.seconds, received: ProcessInfo.processInfo.systemUptime,
                                duration: duration.seconds, marker: marker, contentTime: Double(marker) / 30,
                                pixelFormat: format), video: true)
    }

    func sendAudio(_ samples: AVAudioPCMBuffer, pts: CMTime) {
        let amplitude = samples.floatChannelData.map { Double($0[0][0]) } ?? -.infinity
        append(TimedMediaSample(pts: pts.seconds, received: ProcessInfo.processInfo.systemUptime,
                                duration: Double(samples.frameLength) / samples.format.sampleRate,
                                marker: 0, contentTime: (amplitude - 0.1) / 0.1), video: false)
    }

    func waitForVideoFrames(_ count: Int, format: OSType? = nil) async throws -> MediaTimingTrace {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        state.withLock { $0.listener = continuation }
        continuation.yield()
        defer {
            state.withLock { $0.listener = nil }
            continuation.finish()
        }
        return try await withThrowingTaskGroup(of: MediaTimingTrace.self) { group in
            defer { group.cancelAll() }
            group.addTask {
                for await _ in stream {
                    let trace = self.state.withLock { $0.trace }
                    if trace.video.filter({ format == nil || $0.pixelFormat == format }).count >= count { return trace }
                }
                throw CancellationError()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw ObservationError.timeout(videoFrames: self.state.withLock { $0.trace.video.count })
            }
            return try #require(await group.next())
        }
    }

    private func append(_ sample: TimedMediaSample, video: Bool) {
        state.withLock {
            if video { $0.trace.video.append(sample) }
            else { $0.trace.audio.append(sample) }
            $0.listener?.yield()
        }
    }
}
