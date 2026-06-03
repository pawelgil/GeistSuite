// Sent in HELLO. Producer must emit pixel buffers of exactly this w/h/format
// per frame; fps is advertised but not enforced.
public struct VideoSlotFormat: Hashable, Sendable {
    public var width: Int
    public var height: Int
    public var pixelFormat: PixelFormat
    public var fps: Int

    public init(width: Int, height: Int, pixelFormat: PixelFormat = .yuv420FullRange, fps: Int = 30) {
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        self.fps = fps
    }
}

// Wire receive side is locked to 48000 Hz / mono / PCM float32.
public struct AudioSlotFormat: Hashable, Sendable {
    public var sampleRate: Int
    public var channels: Int

    public init(sampleRate: Int = 48000, channels: Int = 1) {
        self.sampleRate = sampleRate
        self.channels = channels
    }
}
