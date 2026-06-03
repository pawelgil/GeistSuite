import CoreMedia
import CoreVideo
import Foundation
import Synchronization

// Heap-allocated buffer slot so the Task closure can share a swappable
// CVPixelBuffer reference with reformat(to:). Mutex is ~Copyable and can't be
// captured directly across an @Sendable closure.
final class BufferSlot: Sendable {
    let mutex = Mutex<UncheckedBuffer?>(nil)
}

public final class TestPatternProducer: VideoFrameProducer, Sendable {
    public enum Pattern: Sendable { case colorBars, noSignal }

    public let declaredFormat: VideoSlotFormat

    private let pattern: Pattern
    private let fps: Int
    private let buffer = BufferSlot()
    private let task = Mutex<Task<Void, Never>?>(nil)
    private let activeSink = Mutex<(any VideoFrameSink)?>(nil)

    public init(pattern: Pattern = .colorBars,
                width: Int = 1280, height: Int = 720, fps: Int = 30) {
        self.pattern = pattern
        self.fps = fps
        self.declaredFormat = VideoSlotFormat(width: width, height: height,
                                              pixelFormat: .yuv420FullRange, fps: fps)
        let initial = Self.renderPattern(pattern: pattern, width: width, height: height)
            .map { UncheckedBuffer(value: $0) }
        buffer.mutex.withLock { $0 = initial }
    }

    public func start(into sink: any VideoFrameSink) throws {
        activeSink.withLock { $0 = sink }
        launchTask()
    }

    public func stop() {
        task.withLock { $0?.cancel(); $0 = nil }
        activeSink.withLock { $0 = nil }
    }

    public func reformat(to target: VideoSlotFormat) {
        let new = Self.renderPattern(pattern: pattern,
                                     width: target.width, height: target.height)
            .map { UncheckedBuffer(value: $0) }
        buffer.mutex.withLock { $0 = new }
    }

    private func launchTask() {
        guard let sink = activeSink.withLock({ $0 }) else { return }
        let f = fps
        let interval = Duration.nanoseconds(Int64(1_000_000_000 / max(f, 1)))
        let duration = CMTime(value: 1_000_000_000 / CMTimeValue(f),
                              timescale: 1_000_000_000)
        let slot = self.buffer
        let new = Task.detached(priority: .userInitiated) { [sink, slot] in
            while !Task.isCancelled {
                if let snap = slot.mutex.withLock({ $0 }) {
                    let pts = CMClockGetTime(CMClockGetHostTimeClock())
                    sink.sendVideo(snap.value, pts: pts, duration: duration)
                }
                try? await Task.sleep(for: interval)
            }
        }
        task.withLock { $0 = new }
    }

    static func renderPattern(pattern: Pattern, width: Int, height: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        let rv = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                     kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                     attrs as CFDictionary, &pb)
        guard rv == kCVReturnSuccess, let buffer = pb else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let cbcrBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!
        let cbcrStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)

        // SMPTE colorbar values (BT.601 YCbCr).
        let bars: [(y: UInt8, cb: UInt8, cr: UInt8)] = (pattern == .colorBars)
            ? [(180, 128, 128),  // white
               (162, 44, 142),   // yellow
               (131, 156, 44),   // cyan
               (112, 72, 58),    // green
               (84, 184, 198),   // magenta
               (65, 100, 212),   // red
               (35, 212, 114),   // blue
               (16, 128, 128)]   // black
            : Array(repeating: (96, 128, 128), count: 8)  // mid-grey

        let yRow = UnsafeMutablePointer<UInt8>.allocate(capacity: width)
        defer { yRow.deallocate() }
        for col in 0..<width {
            let bar = bars[(col * 8) / width]
            yRow[col] = bar.y
        }
        for row in 0..<height {
            memcpy(yBase.advanced(by: row * yStride), yRow, width)
        }

        let cbcrRow = UnsafeMutablePointer<UInt8>.allocate(capacity: width)
        defer { cbcrRow.deallocate() }
        for col in 0..<(width / 2) {
            let bar = bars[(col * 16) / width]
            cbcrRow[col * 2] = bar.cb
            cbcrRow[col * 2 + 1] = bar.cr
        }
        for row in 0..<(height / 2) {
            memcpy(cbcrBase.advanced(by: row * cbcrStride), cbcrRow, width)
        }
        return buffer
    }
}
