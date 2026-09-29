import AVFoundation
import Foundation
@testable import GeistBroadcast
import Synchronization
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct MediaFileMicTimingTests {
    @Test func playback_multipleLoops_preservesEveryAudioSample() async throws {
        let fixture = try AudioMarkerFixture()
        defer { fixture.remove() }
        let sut = createSUT(fixture)

        let trace = try await record(sut, sampleCount: fixture.samples.count * 3)

        let actual = Array(trace.flatMap(\.samples).prefix(fixture.samples.count * 3))
        #expect(actual == Array(repeating: fixture.samples, count: 3).flatMap { $0 })
        #expect(trace.allSatisfy { $0.sampleRate == AudioMarkerFixture.sampleRate })
    }

    @Test func playback_tenLoops_doesNotAccumulateClockDrift() async throws {
        let fixture = try AudioMarkerFixture()
        defer { fixture.remove() }
        let sut = createSUT(fixture)

        let trace = try await record(sut, sampleCount: fixture.samples.count * 10)

        let first = try #require(trace.first)
        let last = try #require(trace.last)
        let expected = Double(trace.dropLast().reduce(0) { $0 + $1.samples.count }) / AudioMarkerFixture.sampleRate
        let elapsed = last.received - first.received
        #expect(abs(elapsed - expected) < 0.1, "Wall time \(elapsed)s for \(expected)s of audio")
    }

    @Test func playback_loopBoundaries_doNotRunAheadOfSampleClock() async throws {
        let fixture = try AudioMarkerFixture()
        defer { fixture.remove() }
        let sut = createSUT(fixture)

        let trace = try await record(sut, sampleCount: fixture.samples.count * 6)

        let first = try #require(trace.first)
        let boundaries = trace.filter { $0.samples.first == fixture.samples.first }
        #expect(boundaries.count >= 6)
        let lead = boundaries.enumerated().map { Double($0.offset) * fixture.duration - ($0.element.received - first.received) }
        #expect(lead.allSatisfy { $0 < 0.05 }, "Cumulative lead at loop boundaries: \(lead)")
    }

    @Test func restart_newSink_startsAtBeginningOfFile() async throws {
        let fixture = try AudioMarkerFixture()
        defer { fixture.remove() }
        let sut = createSUT(fixture)
        _ = try await record(sut, sampleCount: 8000)

        let restarted = try await record(sut, sampleCount: 8000)

        let samples = Array(restarted.flatMap(\.samples).prefix(8000))
        #expect(samples == Array(fixture.samples.prefix(8000)))
    }

    @Test func stop_duringPacingWait_doesNotDeliverPendingBuffer() async throws {
        let fixture = try AudioMarkerFixture()
        defer { fixture.remove() }

        let delivered = try await stopWhilePacing(fixture)

        #expect(delivered.contains(.buffer))
        #expect(delivered.last == .pacingWait)
    }

    private func createSUT(_ fixture: AudioMarkerFixture) -> MediaFileMicAudioSource {
        MediaFileMicAudioSource(url: fixture.url)
    }

    private func record(_ source: MediaFileMicAudioSource, sampleCount: Int) async throws -> [AudioReceipt] {
        let sink = AudioTimingSinkSpy()
        try source.start(into: sink)
        defer { source.stop() }
        return try await sink.waitForSamples(sampleCount)
    }

    private func stopWhilePacing(_ fixture: AudioMarkerFixture) async throws -> [AudioDeliveryEvent] {
        let entered = AsyncStream<Void>.makeStream()
        let suspended = AsyncStream<Void>.makeStream()
        let deliveries = AsyncStream<AudioDeliveryEvent>.makeStream()
        let source = MediaFileMicAudioSource(url: fixture.url, sleepNanoseconds: { _ in
            deliveries.continuation.yield(.pacingWait)
            entered.continuation.yield()
            for await _ in suspended.stream {}
            try Task.checkCancellation()
        })
        defer {
            source.stop()
            entered.continuation.finish()
            suspended.continuation.finish()
        }
        try source.start(into: AudioDeliverySpy(deliveries.continuation))
        return try await observeStoppedDeliveries(source, entered: entered.stream, deliveries: deliveries.stream)
    }

    private func observeStoppedDeliveries(_ source: MediaFileMicAudioSource, entered: AsyncStream<Void>,
                                          deliveries: AsyncStream<AudioDeliveryEvent>) async throws -> [AudioDeliveryEvent]
    {
        try await withThrowingTaskGroup(of: [AudioDeliveryEvent].self) { group in
            defer { group.cancelAll() }
            group.addTask {
                for await _ in entered {
                    break
                }
                try Task.checkCancellation()
                source.stop()
                return await deliveries.reduce(into: []) { $0.append($1) }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(8))
                throw CancellationError()
            }
            return try #require(await group.next())
        }
    }
}

private enum AudioDeliveryEvent {
    case buffer
    case pacingWait
}

private final class AudioDeliverySpy: BroadcastSink {
    // MARK: Properties

    private let deliveries: AsyncStream<AudioDeliveryEvent>.Continuation
    private let lifetime: AudioDeliveryLifetime

    // MARK: Lifecycle

    init(_ deliveries: AsyncStream<AudioDeliveryEvent>.Continuation) {
        self.deliveries = deliveries
        lifetime = AudioDeliveryLifetime(deliveries)
    }

    // MARK: Functions

    func sendVideo(_: CVPixelBuffer) {}

    func sendMicAudio(_: AVAudioPCMBuffer) {
        deliveries.yield(.buffer)
    }
}

private final class AudioDeliveryLifetime: Sendable {
    // MARK: Properties

    private let deliveries: AsyncStream<AudioDeliveryEvent>.Continuation

    // MARK: Lifecycle

    init(_ deliveries: AsyncStream<AudioDeliveryEvent>.Continuation) {
        self.deliveries = deliveries
    }

    deinit { deliveries.finish() }
}

private struct AudioMarkerFixture {
    // MARK: Static Properties

    static let sampleRate = 44100.0

    // MARK: Properties

    let url: URL
    let samples: [Float]

    // MARK: Computed Properties

    var duration: Double {
        Double(samples.count) / Self.sampleRate
    }

    // MARK: Lifecycle

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("geist-audio-timing-\(UUID()).caf")
        samples = (0 ..< 17640).map { Float($0) / 44100 * 0.1 + 0.1 }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = buffer.frameCapacity
        let channel = try #require(buffer.floatChannelData?[0])
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: $0.count) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    // MARK: Functions

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

private struct AudioReceipt {
    let received: Double
    let samples: [Float]
    let sampleRate: Double
}

private final class AudioTimingSinkSpy: BroadcastSink {
    // MARK: Nested Types

    private struct State {
        var receipts: [AudioReceipt] = []
        var sampleCount = 0
    }

    private enum ObservationError: Error { case timeout(samples: Int) }

    // MARK: Properties

    private let state = Mutex(State())
    private let events = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))

    // MARK: Lifecycle

    deinit { events.continuation.finish() }

    // MARK: Functions

    func sendVideo(_: CVPixelBuffer) {}

    func sendMicAudio(_ samples: AVAudioPCMBuffer) {
        let received = ProcessInfo.processInfo.systemUptime
        let values = samples.floatChannelData.map { Array(UnsafeBufferPointer(start: $0[0], count: Int(samples.frameLength))) } ?? []
        state.withLock {
            $0.receipts.append(AudioReceipt(received: received, samples: values, sampleRate: samples.format.sampleRate))
            $0.sampleCount += values.count
        }
        events.continuation.yield()
    }

    func waitForSamples(_ count: Int) async throws -> [AudioReceipt] {
        try await withThrowingTaskGroup(of: [AudioReceipt].self) { group in
            defer { group.cancelAll() }
            group.addTask {
                for await _ in self.events.stream {
                    if let result = self.state.withLock({ $0.sampleCount >= count ? $0.receipts : nil }) {
                        return result
                    }
                }
                throw CancellationError()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(8))
                throw ObservationError.timeout(samples: self.state.withLock { $0.sampleCount })
            }
            return try #require(await group.next())
        }
    }
}
