import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Synchronization
import GeistKit

/// The lib's frame egress. `SocketClient` is the production conformer; tests
/// substitute a spy to capture what a sink emits.
protocol FrameTransport: Sendable {
    func send(_ frame: Data)
}

private let validationLock = Mutex<Set<UInt32>>([])

private func warnOncePerSlot(_ slot: UInt32, _ message: @autoclosure () -> String) {
    let alreadyWarned = validationLock.withLock { warned -> Bool in
        if warned.contains(slot) { return true }
        warned.insert(slot)
        return false
    }
    if !alreadyWarned {
        let text = message()
        Log.warn("slot \(slot): \(text)")
    }
}

private func fourcc(_ code: UInt32) -> String {
    let bytes: [UInt8] = [
        UInt8(truncatingIfNeeded: (code >> 24) & 0xff),
        UInt8(truncatingIfNeeded: (code >> 16) & 0xff),
        UInt8(truncatingIfNeeded: (code >>  8) & 0xff),
        UInt8(truncatingIfNeeded:  code        & 0xff),
    ]
    let printable = bytes.allSatisfy { $0 >= 0x20 && $0 < 0x7f }
    if printable, let s = String(bytes: bytes, encoding: .ascii) { return "'\(s)'" }
    return String(format: "0x%08x", code)
}

final class VideoSlotBoundSink: VideoFrameSink {
    let wireIndex: UInt32
    private let expected: Mutex<VideoSlotFormat>
    private let client: any FrameTransport
    private let heartbeat: FrameHeartbeat

    init(wireIndex: UInt32, declaredFormat: VideoSlotFormat, client: any FrameTransport, heartbeat: FrameHeartbeat) {
        self.wireIndex = wireIndex
        self.expected = Mutex(declaredFormat)
        self.client = client
        self.heartbeat = heartbeat
    }

    func updateExpectedFormat(_ format: VideoSlotFormat) {
        expected.withLock { $0 = format }
    }

    func sendVideo(_ pixelBuffer: CVPixelBuffer, pts: CMTime, duration: CMTime) {
        let actualW = CVPixelBufferGetWidth(pixelBuffer)
        let actualH = CVPixelBufferGetHeight(pixelBuffer)
        let actualFmt = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let expectedFmt = expected.withLock { $0.pixelFormat.osType }

        // The shim renders frames in exactly the format the app's activeFormat
        // negotiated and drops anything else. Producers emit full range (420f);
        // when the app picked video range (420v) — which AVF does by default for
        // a data output with no videoSettings — range-convert here so the frame
        // survives instead of being dropped end to end. Dimensions still float
        // free: the shim does orientation-aware center-crop+scale to activeFormat.
        let wireFmt: OSType
        let rangeRemap: Yuv420RangeRemap?
        if actualFmt == expectedFmt {
            wireFmt = actualFmt
            rangeRemap = nil
        } else if let remap = Yuv420RangeRemap(from: actualFmt, to: expectedFmt) {
            wireFmt = expectedFmt
            rangeRemap = remap
        } else {
            warnOncePerSlot(wireIndex,
                "frame pixel-format mismatch — expected \(fourcc(expectedFmt)), got \(fourcc(actualFmt)). Dropping.")
            return
        }

        guard var bytes = serializePixelBuffer(pixelBuffer, format: actualFmt, w: actualW, h: actualH) else { return }
        if let rangeRemap {
            bytes = rangeRemap.remapped(planar420: bytes, width: actualW, height: actualH)
        }
        let header = WireVideoFrameHeader(
            slot: wireIndex,
            width: UInt32(actualW), height: UInt32(actualH),
            pixelFormat: wireFmt,
            ptsNs: ptsToNs(pts),
            durationNs: ptsToNs(duration),
            bytesLen: UInt32(bytes.count)
        )
        var payload = header.encoded()
        payload.append(bytes)
        client.send(Data.framed(.videoFrame, payload: payload))
        heartbeat.mark()
    }
}

final class AudioSlotBoundSink: AudioFrameSink {
    let wireIndex: UInt32
    let declaredFormat: AudioSlotFormat
    private let client: any FrameTransport
    private let heartbeat: FrameHeartbeat

    init(wireIndex: UInt32, declaredFormat: AudioSlotFormat, client: any FrameTransport, heartbeat: FrameHeartbeat) {
        self.wireIndex = wireIndex
        self.declaredFormat = declaredFormat
        self.client = client
        self.heartbeat = heartbeat
    }

    func sendAudio(_ samples: AVAudioPCMBuffer, pts: CMTime) {
        let asbd = samples.format.streamDescription.pointee
        let sampleRate = Int(asbd.mSampleRate)
        let channels = Int(asbd.mChannelsPerFrame)
        if sampleRate != declaredFormat.sampleRate || channels != declaredFormat.channels {
            warnOncePerSlot(wireIndex,
                "audio mismatch — declared \(declaredFormat.sampleRate)Hz×\(declaredFormat.channels)ch, got \(sampleRate)Hz×\(channels)ch. Dropping.")
            return
        }

        guard let raw = samples.floatChannelData?[0] else { return }
        let frameCount = Int(samples.frameLength)
        let bytes = Data(bytes: raw, count: frameCount * channels * MemoryLayout<Float>.size)

        let header = WireAudioFrameHeader(
            slot: wireIndex,
            sampleCount: UInt32(frameCount),
            sampleRate: UInt32(sampleRate),
            channels: UInt32(channels),
            format: asbd.mFormatID,
            bitsPerChannel: UInt32(asbd.mBitsPerChannel),
            ptsNs: ptsToNs(pts),
            bytesLen: UInt32(bytes.count)
        )
        var payload = header.encoded()
        payload.append(bytes)
        client.send(Data.framed(.audioFrame, payload: payload))
        heartbeat.mark()
    }
}

final class FrameHeartbeat: Sendable {
    private let lastNs = Atomic<UInt64>(0)

    func mark() {
        lastNs.store(DispatchTime.now().uptimeNanoseconds, ordering: .relaxed)
    }

    func read() -> UInt64 {
        lastNs.load(ordering: .relaxed)
    }
}

private func ptsToNs(_ t: CMTime) -> Int64 {
    guard t.isValid, t.flags.contains(.valid) else { return 0 }
    let scaled = CMTimeConvertScale(t, timescale: 1_000_000_000, method: .default)
    return scaled.value
}

private func serializePixelBuffer(_ pb: CVPixelBuffer, format: OSType, w width: Int, h height: Int) -> Data? {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }

    switch format {
    case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
         kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
        return packBiPlanar420(pb: pb, width: width, height: height)
    case kCVPixelFormatType_32BGRA:
        return packBGRA(pb: pb, width: width, height: height)
    default:
        Log.warn("unsupported pixel format \(fourcc(format)) — dropping frame")
        return nil
    }
}

private func packBiPlanar420(pb: CVPixelBuffer, width: Int, height: Int) -> Data {
    var out = Data(count: width * height * 3 / 2)
    out.withUnsafeMutableBytes { dst in
        guard let dstBase = dst.baseAddress else { return }
        let yBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        for row in 0..<height {
            memcpy(dstBase.advanced(by: row * width),
                   yBase.advanced(by: row * yStride), width)
        }
        let cbcrBase = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!
        let cbcrStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        let cbcrDstOffset = width * height
        for row in 0..<(height / 2) {
            memcpy(dstBase.advanced(by: cbcrDstOffset + row * width),
                   cbcrBase.advanced(by: row * cbcrStride), width)
        }
    }
    return out
}

private func packBGRA(pb: CVPixelBuffer, width: Int, height: Int) -> Data {
    let srcStride = CVPixelBufferGetBytesPerRow(pb)
    let rowBytes = width * 4
    var out = Data(count: rowBytes * height)
    out.withUnsafeMutableBytes { dst in
        guard let dstBase = dst.baseAddress else { return }
        let srcBase = CVPixelBufferGetBaseAddress(pb)!
        for row in 0..<height {
            memcpy(dstBase.advanced(by: row * rowBytes),
                   srcBase.advanced(by: row * srcStride), rowBytes)
        }
    }
    return out
}
