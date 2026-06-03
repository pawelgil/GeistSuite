import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import GeistCamera

// Fixture: Tests/GeistCamTests/Fixtures/AVTwoSeconds.mp4 — 2 s, 320×240@30fps
// h264 video + 48 kHz mono AAC audio (440 Hz sine). Generated once via ffmpeg.
// To regenerate:
//   ffmpeg -y -f lavfi -i "testsrc=duration=2:size=320x240:rate=30" \
//          -f lavfi -i "sine=frequency=440:duration=2:sample_rate=48000" \
//          -c:v h264 -pix_fmt yuv420p -c:a aac -ac 1 -ar 48000 \
//          Tests/GeistCamTests/Fixtures/AVTwoSeconds.mp4
@Suite("VideoFileMediaSource")
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
        try await Task.sleep(for: .milliseconds(400))
        source.stop()

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
        try await Task.sleep(for: .milliseconds(400))
        source.stop()

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
        #expect(earliest < Int64(bitPattern: preStart) + 1_000_000_000) // within 1s of start
        #expect(abs(firstVideo - firstAudio) < 100_000_000)  // < 100ms
    }

    @Test func start_emittedPTSAreMonotonicPerTrack() async throws {
        let url = try Self.fixtureURL()
        let source = try VideoFileMediaSource(url: url)
        let sink = RecordingMediaSinkSpy()

        try source.start(into: sink)
        try await Task.sleep(for: .milliseconds(600))
        source.stop()

        #expect(sink.videoPtsAreMonotonic)
        #expect(sink.audioPtsAreMonotonic)
    }

}

private enum FixtureError: Error {
    case missingFixture(String)
}

// MARK: - Test Doubles

private final class RecordingMediaSinkSpy: MediaSink, @unchecked Sendable {
    private let lock = NSLock()
    private var videoPtsNs: [Int64] = []
    private var audioPtsNs: [Int64] = []

    var videoCount: Int {
        lock.lock(); defer { lock.unlock() }
        return videoPtsNs.count
    }

    var audioCount: Int {
        lock.lock(); defer { lock.unlock() }
        return audioPtsNs.count
    }

    var firstVideoPtsNs: Int64? {
        lock.lock(); defer { lock.unlock() }
        return videoPtsNs.first
    }

    var firstAudioPtsNs: Int64? {
        lock.lock(); defer { lock.unlock() }
        return audioPtsNs.first
    }

    var videoPtsAreMonotonic: Bool {
        lock.lock(); defer { lock.unlock() }
        return zip(videoPtsNs, videoPtsNs.dropFirst()).allSatisfy { $0 <= $1 }
    }

    var audioPtsAreMonotonic: Bool {
        lock.lock(); defer { lock.unlock() }
        return zip(audioPtsNs, audioPtsNs.dropFirst()).allSatisfy { $0 <= $1 }
    }

    func sendVideo(_ pixelBuffer: CVPixelBuffer, pts: CMTime, duration: CMTime) {
        let ns = CMTimeConvertScale(pts, timescale: 1_000_000_000, method: .default).value
        lock.lock(); defer { lock.unlock() }
        videoPtsNs.append(ns)
    }

    func sendAudio(_ samples: AVAudioPCMBuffer, pts: CMTime) {
        let ns = CMTimeConvertScale(pts, timescale: 1_000_000_000, method: .default).value
        lock.lock(); defer { lock.unlock() }
        audioPtsNs.append(ns)
    }
}
