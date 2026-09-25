import AVFoundation
import CoreVideo
import Foundation
import Synchronization

final class SessionBroadcastSink: BroadcastSink {
    // MARK: Static Properties

    private static let loggedUnsupportedAudioFormat = Mutex(false)

    // MARK: Properties

    private let videoQueue: BoundedFrameQueue<Data>
    private let micQueue: BoundedFrameQueue<Data>

    // MARK: Lifecycle

    init(videoQueue: BoundedFrameQueue<Data>,
         micQueue: BoundedFrameQueue<Data>)
    {
        self.videoQueue = videoQueue
        self.micQueue = micQueue
    }

    // MARK: Static Functions

    private static func encodeVideo(_ pixelBuffer: CVPixelBuffer) -> Data? {
        let lockResult = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        guard lockResult == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = UInt32(CVPixelBufferGetWidth(pixelBuffer))
        let height = UInt32(CVPixelBufferGetHeight(pixelBuffer))
        let fourCC = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)

        var payload = Data()
        let bytesPerRowPlane0: UInt32
        let bytesPerRowPlane1: UInt32

        if planeCount == 0 {
            guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
            let bpr: Int = CVPixelBufferGetBytesPerRow(pixelBuffer)
            bytesPerRowPlane0 = UInt32(bpr)
            bytesPerRowPlane1 = 0
            payload.append(UnsafeBufferPointer(
                start: base.assumingMemoryBound(to: UInt8.self),
                count: bpr * Int(height),
            ))
        } else {
            let bpr0: Int = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let h0: Int = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
            guard let p0 = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }
            bytesPerRowPlane0 = UInt32(bpr0)
            payload.append(UnsafeBufferPointer(
                start: p0.assumingMemoryBound(to: UInt8.self), count: bpr0 * h0,
            ))
            if planeCount >= 2 {
                let bpr1: Int = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
                let h1: Int = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
                guard let p1 = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else { return nil }
                bytesPerRowPlane1 = UInt32(bpr1)
                payload.append(UnsafeBufferPointer(
                    start: p1.assumingMemoryBound(to: UInt8.self), count: bpr1 * h1,
                ))
            } else {
                bytesPerRowPlane1 = 0
            }
        }

        let header = FrameHeader.video(
            pixelFormatFourCC: UInt32(fourCC),
            width: width,
            height: height,
            bytesPerRowPlane0: bytesPerRowPlane0,
            bytesPerRowPlane1: bytesPerRowPlane1,
            payloadSize: UInt32(payload.count),
        )
        var out = header.encoded()
        out.append(payload)
        return out
    }

    private static func encodeAudio(_ buffer: AVAudioPCMBuffer, stream: StreamType) -> Data? {
        let format = buffer.format
        let sampleCount = UInt32(buffer.frameLength)
        guard sampleCount > 0 else { return nil }

        let wireFormat: AudioWireSampleFormat
        let bytesPerSample: Int
        var payload = Data()

        switch format.commonFormat {
        case .pcmFormatInt16:
            wireFormat = .pcmInt16
            bytesPerSample = 2
            guard let int16 = buffer.int16ChannelData else { return nil }
            for channelIdx in 0 ..< Int(format.channelCount) {
                let channel = int16[channelIdx]
                let bytes = Int(sampleCount) * bytesPerSample
                payload.append(UnsafeBufferPointer(
                    start: UnsafeRawPointer(channel).assumingMemoryBound(to: UInt8.self),
                    count: bytes,
                ))
            }
        case .pcmFormatFloat32:
            wireFormat = .pcmFloat32
            bytesPerSample = 4
            guard let floatData = buffer.floatChannelData else { return nil }
            for channelIdx in 0 ..< Int(format.channelCount) {
                let channel = floatData[channelIdx]
                let bytes = Int(sampleCount) * bytesPerSample
                payload.append(UnsafeBufferPointer(
                    start: UnsafeRawPointer(channel).assumingMemoryBound(to: UInt8.self),
                    count: bytes,
                ))
            }
        default:
            logUnsupportedAudioFormatOnce(format)
            return nil
        }

        // AVAudioPCMBuffer exposes per-channel pointers (planar), so what we
        // emit on the wire is non-interleaved unless we interleave ourselves.
        // The extension reassembles per-channel data with isInterleaved=false.
        let header = FrameHeader.audio(
            stream: stream,
            sampleRate: UInt32(format.sampleRate),
            channelCount: UInt32(format.channelCount),
            sampleFormat: wireFormat,
            isInterleaved: false,
            sampleCount: sampleCount,
            payloadSize: UInt32(payload.count),
        )
        var out = header.encoded()
        out.append(payload)
        return out
    }

    private static func logUnsupportedAudioFormatOnce(_ format: AVAudioFormat) {
        let alreadyLogged = loggedUnsupportedAudioFormat.withLock { logged in
            let previous = logged
            logged = true
            return previous
        }
        guard !alreadyLogged else { return }
        log.warn("encodeAudio dropping buffers: unsupported common format \(format.commonFormat.rawValue) (sr=\(format.sampleRate) ch=\(format.channelCount))")
    }

    // MARK: Functions

    func sendVideo(_ pixelBuffer: CVPixelBuffer) {
        guard let payload = Self.encodeVideo(pixelBuffer) else { return }
        _ = videoQueue.enqueueOrDropNewest(payload)
    }

    func sendMicAudio(_ samples: AVAudioPCMBuffer) {
        guard let payload = Self.encodeAudio(samples, stream: .audioMic) else { return }
        _ = micQueue.enqueueOrDropNewest(payload)
    }
}
