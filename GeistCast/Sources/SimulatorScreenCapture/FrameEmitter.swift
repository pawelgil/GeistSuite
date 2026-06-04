import CoreVideo
import Foundation
import IOSurface
import Synchronization
import GeistKit

/// `stop()` synchronously drains in-flight callbacks before returning, so no
/// frame can arrive on a stopped emitter. A second `start(receiver:)` before
/// `stop()` replaces the previous receiver.
///
/// @unchecked Sendable: `startTime` and `clock` are immutable; all mutable
/// state is protected by `Mutex`. Lock acquisition order (outermost →
/// innermost): delivery → surfaceState → seed → receiver. `Mutex` is
/// non-reentrant; nested same-lock acquisition deadlocks silently. `stats` is
/// a leaf counter and may be taken under `delivery`.
final class FrameEmitter: @unchecked Sendable {

    typealias Clock = @Sendable () -> UInt64

    private struct SurfaceState: @unchecked Sendable {
        var surface: IOSurface?
        var pool: CVPixelBufferPool?
    }

    private struct Delivery {
        var pending: Bool = false
        var running: Bool = false
        var force: Bool = false
        var pendingTimestamp: Int64 = 0
    }

    struct Stats {
        var delivered: Int = 0
        var coalesced: Int = 0
    }

    typealias FrameReceiver = @Sendable (ScreenFrame) -> Void

    /// Storing the receiver closure directly in `Mutex<FrameReceiver?>` and
    /// pulling it out for an out-of-lock invocation crosses a generic→direct
    /// ABI boundary that trips a Swift compiler bug: emitted reabstraction
    /// thunks call each other in a cycle, blowing the stack after a few
    /// thousand frames (only visible under WebRTC). Routing the closure
    /// through a class reference keeps storage and invocation on a single
    /// ABI path.
    private final class ReceiverBox: Sendable {
        let invoke: FrameReceiver
        init(_ invoke: @escaping FrameReceiver) { self.invoke = invoke }
    }

    private let clock: Clock
    private let startTime: UInt64
    private let surfaceState: Mutex<SurfaceState>
    private let seed = Mutex<UInt32>(0)
    private let receiver = Mutex<ReceiverBox?>(nil)
    private let delivery = Mutex(Delivery())
    private let stats = Mutex(Stats())
    private let deliveryQueue = DispatchQueue(label: "com.simulatorkit.frame-delivery", qos: .userInteractive)

    init(surface: IOSurface, clock: @escaping Clock = { mach_absolute_time() }) {
        self.clock = clock
        startTime = clock()
        let pool = Self.createPool(width: surface.width, height: surface.height)
        surfaceState = Mutex(SurfaceState(surface: surface, pool: pool))
        if pool == nil {
            log.warn("FrameEmitter: failed to create pixel buffer pool for \(surface.width)x\(surface.height), falling back to direct IOSurface wrap")
        }
    }

    private static func createPool(width: Int, height: Int) -> CVPixelBufferPool? {
        let attrs: [String: Any] = [
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        if status != kCVReturnSuccess {
            return nil
        }
        return pool
    }

    /// Precondition: receiver must not synchronously call `stop()` or
    /// anything that invokes `deliveryQueue.sync` — deadlocks the queue.
    func start(receiver: @escaping FrameReceiver) {
        self.receiver.withLock { $0 = ReceiverBox(receiver) }
        notifyFrame(force: true)
    }

    /// Rapid calls coalesce into the running drain loop; only the latest
    /// `pendingTimestamp` and `force` survive. `force=true` delivers even
    /// when the IOSurface seed hasn't changed.
    func notifyFrame(force: Bool = false) {
        let timestamp = machToNanoseconds(clock() - startTime)
        let shouldEnqueue = delivery.withLock { state -> Bool in
            state.pending = true
            state.pendingTimestamp = timestamp
            if force { state.force = true }
            if state.running {
                stats.withLock { $0.coalesced += 1 }
                return false
            }
            state.running = true
            return true
        }
        if shouldEnqueue {
            deliveryQueue.async { [weak self] in self?.drainPending() }
        }
    }

    func replaceSurface(_ newSurface: IOSurface) {
        let entryClock = clock()
        let timestamp = machToNanoseconds(entryClock - startTime)
        var poolRecreated = false
        let (shouldEnqueue, oldSize) = delivery.withLock { state -> (Bool, (Int, Int)) in
            let size = surfaceState.withLock { ss -> (Int, Int) in
                let w = ss.surface.map { IOSurfaceGetWidth(unsafeBitCast($0, to: IOSurfaceRef.self)) } ?? 0
                let h = ss.surface.map { IOSurfaceGetHeight(unsafeBitCast($0, to: IOSurfaceRef.self)) } ?? 0
                ss.surface = newSurface
                let newW = newSurface.width
                let newH = newSurface.height
                if w != newW || h != newH {
                    ss.pool = Self.createPool(width: newW, height: newH)
                    poolRecreated = true
                }
                return (w, h)
            }
            state.pending = true
            state.force = true
            state.pendingTimestamp = timestamp
            if state.running { return (false, size) }
            state.running = true
            return (true, size)
        }
        if shouldEnqueue {
            deliveryQueue.async { [weak self] in self?.drainPending() }
        }
        let elapsedMs = Double(machToNanoseconds(clock() - entryClock)) / 1_000_000
        log.notice("FrameEmitter: IOSurface replaced (\(oldSize.0)x\(oldSize.1) → \(newSurface.width)x\(newSurface.height)) elapsed=\(String(format: "%.1f", elapsedMs))ms poolRecreated=\(poolRecreated)")
    }

    func stop() {
        receiver.withLock { $0 = nil }
        deliveryQueue.sync {}
        let snapshot = stats.withLock { current -> Stats in
            let previous = current
            current = Stats()
            return previous
        }
        if snapshot.delivered > 0 || snapshot.coalesced > 0 {
            log.info("FrameEmitter stats: delivered=\(snapshot.delivered) coalesced=\(snapshot.coalesced)")
        }
    }

    private func drainPending() {
        while true {
            // GCD worker's outer autorelease pool doesn't drain until this
            // block returns. Under a burst the loop iterates many times,
            // each iteration leaving CVPixelBuffer/IOSurface wraps behind —
            // drain per iteration to keep resident memory bounded.
            let done = autoreleasepool { () -> Bool in
                let (consumed, timestamp, force) = delivery.withLock { state -> (Bool, Int64, Bool) in
                    guard state.pending else {
                        state.running = false
                        return (false, 0, false)
                    }
                    let ts = state.pendingTimestamp
                    let f = state.force
                    state.pending = false
                    state.force = false
                    return (true, ts, f)
                }
                guard consumed else { return true }

                let currentReceiver = receiver.withLock { $0 }
                guard let currentReceiver else {
                    delivery.withLock { $0.running = false }
                    return true
                }

                guard hasChange(force: force) else { return false }
                guard let frame = capture(at: timestamp) else { return false }
                currentReceiver.invoke(frame)
                stats.withLock { $0.delivered += 1 }
                return false
            }
            if done { return }
        }
    }

    private func hasChange(force: Bool) -> Bool {
        guard let currentSurface = surfaceState.withLock({ $0.surface }) else { return false }
        let currentSeed = IOSurfaceGetSeed(unsafeBitCast(currentSurface, to: IOSurfaceRef.self))
        return seed.withLock { stored -> Bool in
            guard force || currentSeed != stored else { return false }
            stored = currentSeed
            return true
        }
    }

    private func capture(at timestamp: Int64) -> ScreenFrame? {
        let snapshot = surfaceState.withLock { ($0.surface, $0.pool) }
        guard let currentSurface = snapshot.0 else { return nil }
        let surfaceRef = unsafeBitCast(currentSurface, to: IOSurfaceRef.self)
        guard let buffer = captureFrame(surfaceRef, pool: snapshot.1) else { return nil }
        return ScreenFrame(pixelBuffer: buffer, timestampNs: timestamp)
    }

    private func captureFrame(_ surfaceRef: IOSurfaceRef, pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        let lockResult = IOSurfaceLock(surfaceRef, .readOnly, nil)
        defer {
            if lockResult == kIOReturnSuccess {
                IOSurfaceUnlock(surfaceRef, .readOnly, nil)
            }
        }
        return copyToPoolBuffer(from: surfaceRef, pool: pool) ?? wrapSurface(surfaceRef)
    }

    private func copyToPoolBuffer(from surfaceRef: IOSurfaceRef, pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        guard let pool else { return nil }
        guard let destination = allocatePoolBuffer(pool) else { return nil }
        return copyPixels(from: surfaceRef, to: destination) ? destination : nil
    }

    private func allocatePoolBuffer(_ pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess else {
            return nil
        }
        return buffer
    }

    private func copyPixels(from surfaceRef: IOSurfaceRef, to destination: CVPixelBuffer) -> Bool {
        CVPixelBufferLockBaseAddress(destination, [])
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }

        let src = IOSurfaceGetBaseAddress(surfaceRef)
        let srcBPR = IOSurfaceGetBytesPerRow(surfaceRef)
        let height = IOSurfaceGetHeight(surfaceRef)
        guard let dst = CVPixelBufferGetBaseAddress(destination) else {
            log.warn("FrameEmitter: null destination base address during frame copy")
            return false
        }
        let dstBPR = CVPixelBufferGetBytesPerRow(destination)
        if dstBPR == srcBPR {
            memcpy(dst, src, srcBPR * height)
        } else {
            let copy = min(srcBPR, dstBPR)
            for row in 0..<height {
                memcpy(dst.advanced(by: row * dstBPR),
                       src.advanced(by: row * srcBPR),
                       copy)
            }
        }
        return true
    }

    private func wrapSurface(_ surfaceRef: IOSurfaceRef) -> CVPixelBuffer? {
        var pixelBuffer: Unmanaged<CVPixelBuffer>?
        let status = CVPixelBufferCreateWithIOSurface(nil, surfaceRef, nil, &pixelBuffer)
        guard status == kCVReturnSuccess else { return nil }
        return pixelBuffer?.takeRetainedValue()
    }
}

private let timebaseInfo: mach_timebase_info_data_t = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return info
}()

private func machToNanoseconds(_ mach: UInt64) -> Int64 {
    Int64(mach * UInt64(timebaseInfo.numer) / UInt64(timebaseInfo.denom))
}
