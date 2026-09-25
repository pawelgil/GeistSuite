import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Synchronization
import Testing
@testable import GeistCamera

// Fixture: Tests/GeistCamTests/Fixtures/AVTwoSeconds.mp4 — 2 s, 320×240@30fps
// h264 video + 48 kHz mono AAC audio (440 Hz sine). Generated once via ffmpeg.
// To regenerate:
//   ffmpeg -y -f lavfi -i "testsrc=duration=2:size=320x240:rate=30" \
//          -f lavfi -i "sine=frequency=440:duration=2:sample_rate=48000" \
//          -c:v h264 -pix_fmt yuv420p -c:a aac -ac 1 -ar 48000 \
//          Tests/GeistCamTests/Fixtures/AVTwoSeconds.mp4
// AVFoundation's decode pipeline serializes at the process level — running
// multiple AVAssetReaders concurrently against the same file blocks rather
// than parallelizing. Mark the suite serialized so Swift Testing doesn't
// race instances of VideoFileMediaSource against each other.
@Suite("VideoFileMediaSource", .serialized)
struct VideoFileMediaSourceTests {
    private static let fixtureName = "AVTwoSeconds.mp4"

    private static func fixtureURL() throws -> URL {
        let bundle = Bundle.module
        guard let url = bundle.url(forResource: "AVTwoSeconds", withExtension: "mp4") else {
            throw FixtureError.missingFixture(fixtureName)
        }
        return url
    }

    @Test func init_videoOnlyDeclaredFormat_matchesAssetMetadata() async throws {
        let url = try Self.fixtureURL()

        let source = try VideoFileMediaSource(url: url)

        let video = try #require(source.declaredVideoFormat)
        #expect(video.width == 320)
        #expect(video.height == 240)
        #expect(video.fps == 30)
        #expect(source.hasVideo)
    }

    @Test func init_hasAudioTrack_advertisesHasAudio() async throws {
        let url = try Self.fixtureURL()

        let source = try VideoFileMediaSource(url: url)

        #expect(source.hasAudio)
        let audio = try #require(source.declaredAudioFormat)
        #expect(audio.sampleRate == 48000)
        #expect(audio.channels == 1)
    }

    @Test func start_emitsBothVideoAndAudio_intoSink() async throws {
        let url = try Self.fixtureURL()
        let source = try VideoFileMediaSource(url: url)
        let sink = RecordingMediaSinkSpy()

        try source.start(into: sink)
        defer { source.stop() }
        try await sink.waitForSamples()

        let videoCount = sink.videoCount
        let audioCount = sink.audioCount
        #expect(videoCount > 0)
        #expect(audioCount > 0)
    }

    @Test func start_videoAndAudioPTSAnchorTogether_firstEmittedPtsClose() async throws {
        let url = try Self.fixtureURL()
        let source = try VideoFileMediaSource(url: url)
        let sink = RecordingMediaSinkSpy()

        let preStart = DispatchTime.now().uptimeNanoseconds
        try source.start(into: sink)
        defer { source.stop() }
        try await sink.waitForSamples()

        let firstVideoPts = sink.firstVideoPtsNs
        let firstAudioPts = sink.firstAudioPtsNs
        let firstVideo = try #require(firstVideoPts)
        let firstAudio = try #require(firstAudioPts)
        // PTS is in mach-time scale (matches mac cam/mic) — anchored at the
        // stream-start host time so AVAssetWriter sees video and audio in
        // the same reference frame. The earlier track lands ~at streamHostT0,
        // the later track lands within the asset's per-track offset.
        let earliest = min(firstVideo, firstAudio)
        #expect(earliest >= Int64(bitPattern: preStart))
        let firstReceipt = try #require(sink.firstReceivedAtNs)
        #expect(earliest <= firstReceipt)
        #expect(abs(firstVideo - firstAudio) < 100_000_000)  // < 100ms
    }

    @Test func start_emittedPTSAreMonotonicPerTrack() async throws {
        let url = try Self.fixtureURL()
        let source = try VideoFileMediaSource(url: url)
        let sink = RecordingMediaSinkSpy()

        try source.start(into: sink)
        defer { source.stop() }
        try await sink.waitForSamples(minimumPerTrack: 10)

        #expect(sink.videoPtsAreMonotonic)
        #expect(sink.audioPtsAreMonotonic)
    }

}

private enum FixtureError: Error {
    case missingFixture(String)
}

// MARK: - Test Doubles

private final class RecordingMediaSinkSpy: MediaSink {
    private struct Recording {
        var videoPtsNs: [Int64] = []
        var audioPtsNs: [Int64] = []
        var firstReceivedAtNs: Int64?
    }

    private enum ObservationError: Error {
        case missingSamples(video: Int, audio: Int)
    }

    private let recording = Mutex(Recording())
    private let received: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (received, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    deinit {
        continuation.finish()
    }

    var videoCount: Int {
        recording.withLock { $0.videoPtsNs.count }
    }

    var audioCount: Int {
        recording.withLock { $0.audioPtsNs.count }
    }

    var firstVideoPtsNs: Int64? {
        recording.withLock { $0.videoPtsNs.first }
    }

    var firstAudioPtsNs: Int64? {
        recording.withLock { $0.audioPtsNs.first }
    }

    var firstReceivedAtNs: Int64? {
        recording.withLock { $0.firstReceivedAtNs }
    }

    var videoPtsAreMonotonic: Bool {
        recording.withLock { zip($0.videoPtsNs, $0.videoPtsNs.dropFirst()).allSatisfy { $0 <= $1 } }
    }

    var audioPtsAreMonotonic: Bool {
        recording.withLock { zip($0.audioPtsNs, $0.audioPtsNs.dropFirst()).allSatisfy { $0 <= $1 } }
    }

    func sendVideo(_ pixelBuffer: CVPixelBuffer, pts: CMTime, duration: CMTime) {
        let ns = CMTimeConvertScale(pts, timescale: 1_000_000_000, method: .default).value
        recording.withLock {
            $0.videoPtsNs.append(ns)
            $0.firstReceivedAtNs = $0.firstReceivedAtNs ?? Int64(bitPattern: DispatchTime.now().uptimeNanoseconds)
        }
        continuation.yield()
    }

    func sendAudio(_ samples: AVAudioPCMBuffer, pts: CMTime) {
        let ns = CMTimeConvertScale(pts, timescale: 1_000_000_000, method: .default).value
        recording.withLock {
            $0.audioPtsNs.append(ns)
            $0.firstReceivedAtNs = $0.firstReceivedAtNs ?? Int64(bitPattern: DispatchTime.now().uptimeNanoseconds)
        }
        continuation.yield()
    }

    func waitForSamples(minimumPerTrack: Int = 1) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [received] in
                for await _ in received {
                    if self.videoCount >= minimumPerTrack && self.audioCount >= minimumPerTrack { return }
                }
                try Task.checkCancellation()
                throw ObservationError.missingSamples(video: self.videoCount, audio: self.audioCount)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw ObservationError.missingSamples(video: self.videoCount, audio: self.audioCount)
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }
}
