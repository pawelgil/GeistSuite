import CoreMedia
import CoreVideo
import Foundation
import Synchronization

/// Video-only MediaSource emitting color bars (or a uniform grey "no signal"
/// pattern). PTS is host-clock — there's no source timeline to anchor against.
public final class TestPatternMediaSource: MediaSource, @unchecked Sendable {
    public let hasVideo: Bool = true
    public let hasAudio: Bool = false
    public let declaredVideoFormat: VideoSlotFormat?
    public let declaredAudioFormat: AudioSlotFormat? = nil

    private let pattern: TestPatternProducer.Pattern
    private let fps: Int
    private let buffer = BufferSlot()
    private let task = Mutex<Task<Void, Never>?>(nil)
    private let activeSink = Mutex<(any MediaSink)?>(nil)

    public init(pattern: TestPatternProducer.Pattern = .colorBars,
                width: Int = 1280, height: Int = 720, fps: Int = 30) {
        self.pattern = pattern
        self.fps = fps
        self.declaredVideoFormat = VideoSlotFormat(width: width, height: height,
                                                    pixelFormat: .yuv420FullRange, fps: fps)
        let initial = TestPatternProducer.renderPattern(pattern: pattern, width: width, height: height)
            .map { UncheckedBuffer(value: $0) }
        buffer.mutex.withLock { $0 = initial }
    }

    public func start(into sink: any MediaSink) throws {
        activeSink.withLock { $0 = sink }
        let f = fps
        let interval = Duration.nanoseconds(Int64(1_000_000_000 / max(f, 1)))
        let duration = CMTime(value: 1_000_000_000 / CMTimeValue(f), timescale: 1_000_000_000)
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

    public func stop() {
        task.withLock { $0?.cancel(); $0 = nil }
        activeSink.withLock { $0 = nil }
    }

    public func reformat(to target: VideoSlotFormat) {
        let new = TestPatternProducer.renderPattern(pattern: pattern,
                                                      width: target.width, height: target.height)
            .map { UncheckedBuffer(value: $0) }
        buffer.mutex.withLock { $0 = new }
    }
}
