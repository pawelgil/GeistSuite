import AVFoundation
import CoreMedia
import Foundation
import Synchronization

final class MediaFileMicAudioSource: BroadcastSource {
    // MARK: Nested Types

    private struct PlaybackClock {
        // MARK: Properties

        private var start: UInt64?
        private var deliveredFrames: Int64 = 0

        // MARK: Functions

        mutating func deadline(for buffer: AVAudioPCMBuffer) -> UInt64 {
            let anchor = start ?? DispatchTime.now().uptimeNanoseconds
            start = anchor
            let elapsed = Double(deliveredFrames) / buffer.format.sampleRate
            deliveredFrames += Int64(buffer.frameLength)
            return anchor + UInt64(elapsed * 1_000_000_000)
        }
    }

    // MARK: Properties

    private let url: URL
    private let sleepNanoseconds: @Sendable (UInt64) async throws -> Void
    private let task = Mutex<Task<Void, Never>?>(nil)

    // MARK: Lifecycle

    init(url: URL, sleepNanoseconds: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) {
        self.url = url
        self.sleepNanoseconds = sleepNanoseconds
    }

    // MARK: Static Functions

    private static func runOneCycle(url: URL, sink: any BroadcastSink, clock: inout PlaybackClock,
                                    sleepNanoseconds: @Sendable (UInt64) async throws -> Void) async -> Bool
    {
        let asset = AVURLAsset(url: url)
        guard let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first else {
            return false
        }
        guard let reader = try? AVAssetReader(asset: asset) else { return false }
        let format = AVAudioFormat(
            standardFormatWithSampleRate: 44100,
            channels: 1
        )!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true,
        ]
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: settings)
        reader.add(output)
        guard reader.startReading() else { return false }
        defer { reader.cancelReading() }

        while !Task.isCancelled, reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
            guard let buffer = Self.pcmBuffer(from: sampleBuffer, format: format) else { continue }
            let targetHost = clock.deadline(for: buffer)
            let now = DispatchTime.now().uptimeNanoseconds
            if targetHost > now {
                try? await sleepNanoseconds(targetHost - now)
            }
            guard !Task.isCancelled else { return false }
            sink.sendMicAudio(buffer)
        }
        return reader.status == .completed
    }

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let dst = buffer.floatChannelData
        else { return nil }
        buffer.frameLength = frameCount
        let byteCount = Int(frameCount) * MemoryLayout<Float>.size
        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            blockBuffer, atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        ) == kCMBlockBufferNoErr, let src = dataPointer else { return nil }
        memcpy(dst[0], src, min(byteCount, totalLength))
        return buffer
    }

    // MARK: Functions

    func start(into sink: any BroadcastSink) throws {
        stop()
        let url = self.url
        let sleepNanoseconds = self.sleepNanoseconds
        // The source owns cancellation; reader and playback clock stay within this task.
        let new = Task.detached(priority: .userInitiated) { [sink] in
            var clock = PlaybackClock()
            while !Task.isCancelled {
                let completed = await Self.runOneCycle(url: url, sink: sink, clock: &clock, sleepNanoseconds: sleepNanoseconds)
                if !completed { return }
            }
        }
        task.withLock { $0 = new }
    }

    func stop() {
        task.withLock { $0?.cancel(); $0 = nil }
    }
}
