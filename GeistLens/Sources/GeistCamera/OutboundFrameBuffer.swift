struct OutboundFrameBuffer: Sendable {
    static let defaultByteLimit = 32 * 1024 * 1024

    private var frames: [OutboundFrame?] = []
    private var headIndex = 0
    private let byteLimit: Int
    private(set) var pendingBytes = 0

    init(byteLimit: Int = Self.defaultByteLimit) {
        self.byteLimit = byteLimit
    }

    mutating func enqueue(_ frame: OutboundFrame) -> FrameAdmission {
        if frame.isReliable {
            return enqueueReliable(frame)
        }
        return enqueueVideo(frame)
    }

    mutating func popFirst() -> OutboundFrame? {
        guard headIndex < frames.count, let frame = frames[headIndex] else { return nil }
        frames[headIndex] = nil
        headIndex += 1
        pendingBytes -= frame.byteCount
        compactIfNeeded()
        return frame
    }

    mutating func removeAll() {
        frames.removeAll(keepingCapacity: false)
        headIndex = 0
        pendingBytes = 0
    }

    private mutating func enqueueReliable(_ frame: OutboundFrame) -> FrameAdmission {
        guard frame.byteCount <= byteLimit else { return .rejected(.capacity) }
        while pendingBytes + frame.byteCount > byteLimit {
            guard removeOldestVideo() else { return .rejected(.capacity) }
        }
        append(frame)
        return .accepted
    }

    private mutating func enqueueVideo(_ frame: OutboundFrame) -> FrameAdmission {
        if let slot = frame.videoSlot, let index = firstVideoIndex(slot: slot) {
            remove(at: index)
        }
        guard frame.byteCount <= byteLimit,
              pendingBytes + frame.byteCount <= byteLimit else {
            return .droppedVideo
        }
        append(frame)
        return .accepted
    }

    private mutating func append(_ frame: OutboundFrame) {
        frames.append(frame)
        pendingBytes += frame.byteCount
    }

    private mutating func compactIfNeeded() {
        guard headIndex >= 64, headIndex * 2 >= frames.count else { return }
        frames.removeFirst(headIndex)
        headIndex = 0
    }

    private func firstVideoIndex(slot: UInt32) -> Int? {
        frames.indices.dropFirst(headIndex).first { frames[$0]?.videoSlot == slot }
    }

    private mutating func remove(at index: Int) {
        guard let frame = frames.remove(at: index) else { return }
        pendingBytes -= frame.byteCount
    }

    private mutating func removeOldestVideo() -> Bool {
        guard let index = frames.indices.dropFirst(headIndex).first(where: {
            frames[$0]?.videoSlot != nil
        }) else { return false }
        remove(at: index)
        return true
    }
}
