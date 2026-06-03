import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import Synchronization

private final class StillBufferSlot: Sendable {
    let mutex = Mutex<UncheckedBuffer?>(nil)
}

public final class StillImageProducer: VideoFrameProducer, Sendable {
    public enum FitMode: Sendable {
        case fit
        case fill
    }

    public enum StillImageError: Error {
        case cannotLoadImage(URL)
        case bufferAllocationFailed
        case contextCreationFailed
    }

    public let declaredFormat: VideoSlotFormat

    private let url: URL
    private let fitMode: FitMode
    private let buffer = StillBufferSlot()
    private let fps: Int
    private let task = Mutex<Task<Void, Never>?>(nil)
    private let activeSink = Mutex<(any VideoFrameSink)?>(nil)

    public init(url: URL,
                targetDim: CGSize = CGSize(width: 1080, height: 1920),
                fitMode: FitMode = .fit,
                fps: Int = 5) throws {
        self.url = url
        self.fitMode = fitMode
        self.fps = fps
        let w = Int(targetDim.width)
        let h = Int(targetDim.height)
        self.declaredFormat = VideoSlotFormat(
            width: w, height: h,
            pixelFormat: .yuv420FullRange,
            fps: fps
        )
        let pb = try Self.renderImage(url: url, targetW: w, targetH: h, fitMode: fitMode)
        buffer.mutex.withLock { $0 = UncheckedBuffer(value: pb) }
    }

    public func start(into sink: any VideoFrameSink) throws {
        activeSink.withLock { $0 = sink }
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

    public func stop() {
        task.withLock { $0?.cancel(); $0 = nil }
        activeSink.withLock { $0 = nil }
    }

    public func reformat(to target: VideoSlotFormat) {
        guard let pb = try? Self.renderImage(url: url, targetW: target.width,
                                              targetH: target.height, fitMode: fitMode) else {
            Log.warn("StillImageProducer: re-render failed for \(target.width)x\(target.height)")
            return
        }
        buffer.mutex.withLock { $0 = UncheckedBuffer(value: pb) }
    }

    private static func renderImage(url: URL,
                                    targetW: Int, targetH: Int,
                                    fitMode: FitMode) throws -> CVPixelBuffer {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw StillImageError.cannotLoadImage(url)
        }
        let srcW = CGFloat(cgImage.width)
        let srcH = CGFloat(cgImage.height)
        let tW = CGFloat(targetW)
        let tH = CGFloat(targetH)

        let scale: CGFloat
        switch fitMode {
        case .fit:  scale = min(tW / srcW, tH / srcH)
        case .fill: scale = max(tW / srcW, tH / srcH)
        }
        let drawW = srcW * scale
        let drawH = srcH * scale
        let drawX = (tW - drawW) / 2
        let drawY = (tH - drawH) / 2

        var scratch: CVPixelBuffer?
        let scratchAttrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        let rv1 = CVPixelBufferCreate(kCFAllocatorDefault, targetW, targetH,
                                      kCVPixelFormatType_32BGRA,
                                      scratchAttrs as CFDictionary, &scratch)
        guard rv1 == kCVReturnSuccess, let bgraBuffer = scratch else {
            throw StillImageError.bufferAllocationFailed
        }
        CVPixelBufferLockBaseAddress(bgraBuffer, [])
        let base = CVPixelBufferGetBaseAddress(bgraBuffer)
        let stride = CVPixelBufferGetBytesPerRow(bgraBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(data: base,
                                       width: targetW, height: targetH,
                                       bitsPerComponent: 8,
                                       bytesPerRow: stride,
                                       space: colorSpace,
                                       bitmapInfo: bitmapInfo) else {
            CVPixelBufferUnlockBaseAddress(bgraBuffer, [])
            throw StillImageError.contextCreationFailed
        }
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: tW, height: tH))
        context.draw(cgImage, in: CGRect(x: drawX, y: drawY, width: drawW, height: drawH))
        CVPixelBufferUnlockBaseAddress(bgraBuffer, [])

        var yuv: CVPixelBuffer?
        let yuvAttrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        let rv2 = CVPixelBufferCreate(kCFAllocatorDefault, targetW, targetH,
                                      kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                      yuvAttrs as CFDictionary, &yuv)
        guard rv2 == kCVReturnSuccess, let yuvBuffer = yuv else {
            throw StillImageError.bufferAllocationFailed
        }
        let ciImage = CIImage(cvPixelBuffer: bgraBuffer)
        let ciContext = CIContext(options: nil)
        ciContext.render(ciImage, to: yuvBuffer)
        return yuvBuffer
    }
}
