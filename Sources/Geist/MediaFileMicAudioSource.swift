import AVFoundation
import CoreMedia
import Foundation
import Synchronization

// Loops the file so a short clip keeps producing audio for the full
// length of the broadcast.
final class MediaFileMicAudioSource: BroadcastSource {
    private let url: URL
    private let task = Mutex<Task<Void, Never>?>(nil)

    init(url: URL) {
        self.url = url
    }

    func start(into sink: any BroadcastSink) throws {
        stop()
        let url = self.url
        let new = Task.detached(priority: .userInitiated) { [sink] in
            while !Task.isCancelled {
                let completed = await Self.runOneCycle(url: url, sink: sink)
                if !completed { return }
            }
        }
        task.withLock { $0 = new }
    }

    func stop() {
        task.withLock { $0?.cancel(); $0 = nil }
    }

    private static func runOneCycle(url: URL, sink: any BroadcastSink) async -> Bool {
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

        let streamStartHost = DispatchTime.now().uptimeNanoseconds
        var deliveredSampleFrames: Int64 = 0
        while !Task.isCancelled, reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
            guard let buffer = Self.pcmBuffer(from: sampleBuffer, format: format) else { continue }
            // Pace delivery to the audio's native sample rate so the
            // receiver gets buffers at real-time cadence.
            let targetHost = streamStartHost
                + UInt64(Double(deliveredSampleFrames) / format.sampleRate * 1_000_000_000)
            let now = DispatchTime.now().uptimeNanoseconds
            if targetHost > now {
                try? await Task.sleep(nanoseconds: targetHost - now)
            }
            sink.sendMicAudio(buffer)
            deliveredSampleFrames += Int64(buffer.frameLength)
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
}
