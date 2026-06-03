import AVFoundation
import CoreMedia
import CoreVideo
import Dispatch
import Foundation
import Synchronization
import GeistKit

public enum VideoFileMediaSourceError: Error {
    case noVideoTrack
}

private final class ResumePositionNs: Sendable {
    let value = Atomic<Int64>(0)
}

/// Single-task A/V source for a local media file. One `AVAssetReader` with
/// both video and audio outputs, paced against one host clock, anchored at the
/// first sample's PTS from either track. Loops automatically; cycle offset =
/// `asset.duration` (shared between tracks → no per-track drift).
public final class VideoFileMediaSource: MediaSource, @unchecked Sendable {
    public let hasVideo: Bool = true
    public let hasAudio: Bool
    public let declaredVideoFormat: VideoSlotFormat?
    public let declaredAudioFormat: AudioSlotFormat?

    private let url: URL
    private let assetDurationNs: Int64
    private let task = Mutex<Task<Void, Never>?>(nil)
    private let activeSink = Mutex<(any MediaSink)?>(nil)
    private let targetVideoFormat: Mutex<VideoSlotFormat>
    private let resume = ResumePositionNs()

    public init(url: URL) throws {
        self.url = url
        let asset = AVURLAsset(url: url)
        let videoTracks = asset.tracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw VideoFileMediaSourceError.noVideoTrack
        }
        let dims = videoTrack.naturalSize
        let fpsRaw = videoTrack.nominalFrameRate
        let declaredVideo = VideoSlotFormat(
            width: Int(dims.width), height: Int(dims.height),
            pixelFormat: .yuv420FullRange,
            fps: fpsRaw > 0 ? Int(fpsRaw.rounded()) : 30
        )
        self.declaredVideoFormat = declaredVideo
        self.targetVideoFormat = Mutex(declaredVideo)
        let audioTracks = asset.tracks(withMediaType: .audio)
        self.hasAudio = !audioTracks.isEmpty
        self.declaredAudioFormat = audioTracks.isEmpty ? nil : AudioSlotFormat(sampleRate: 48000, channels: 1)
        self.assetDurationNs = Self.ptsToNanoseconds(asset.duration)
    }

    public func start(into sink: any MediaSink) throws {
        activeSink.withLock { $0 = sink }
        launchTask()
    }

    public func stop() {
        task.withLock { $0?.cancel(); $0 = nil }
        activeSink.withLock { $0 = nil }
    }

    public func reformat(to target: VideoSlotFormat) {
        let changed = targetVideoFormat.withLock { old -> Bool in
            let same = (old.width == target.width
                        && old.height == target.height
                        && old.pixelFormat == target.pixelFormat)
            if !same { old = target }
            return !same
        }
        guard changed else { return }
        task.withLock { $0?.cancel(); $0 = nil }
        if activeSink.withLock({ $0 != nil }) {
            launchTask()
        }
    }

    private func launchTask() {
        guard let sink = activeSink.withLock({ $0 }) else { return }
        let url = self.url
        let resume = self.resume
        let snapshot = targetVideoFormat.withLock { $0 }
        let startNs = resume.value.load(ordering: .relaxed)
        let assetDurationNs = self.assetDurationNs
        let new = Task.detached(priority: .userInitiated) { [sink, resume] in
            await Self.run(url: url,
                            startAtNs: startNs,
                            assetDurationNs: assetDurationNs,
                            targetVideoFormat: snapshot,
                            sink: sink,
                            resume: resume)
        }
        task.withLock { $0 = new }
    }

    static func ptsToNanoseconds(_ t: CMTime) -> Int64 {
        guard t.isValid else { return 0 }
        let scaled = CMTimeConvertScale(t, timescale: 1_000_000_000, method: .default)
        return scaled.value
    }

    private static func run(url: URL,
                             startAtNs: Int64,
                             assetDurationNs: Int64,
                             targetVideoFormat: VideoSlotFormat,
                             sink: any MediaSink,
                             resume: ResumePositionNs) async {
        let asset = AVURLAsset(url: url)
        // One host-clock anchor per stream so emitted PTS is mach-time-based
        // and stays monotonic across cycle wraps — matching what mac cam/mic
        // emit, so AVAssetWriter's session anchor handles both consistently.
        let streamHostT0 = DispatchTime.now().uptimeNanoseconds
        var firstCycleStart = startAtNs
        var cycleOffsetNs: Int64 = 0
        while !Task.isCancelled {
            let completed = await runOneCycle(asset: asset,
                                               startAtNs: firstCycleStart,
                                               cycleOffsetNs: cycleOffsetNs,
                                               streamHostT0: streamHostT0,
                                               targetVideoFormat: targetVideoFormat,
                                               sink: sink,
                                               resume: resume)
            firstCycleStart = 0
            cycleOffsetNs &+= assetDurationNs
            if !completed { break }
        }
        Log.notice("VideoFileMediaSource ended for \(url.lastPathComponent)")
    }

    private static func runOneCycle(asset: AVURLAsset,
                                     startAtNs: Int64,
                                     cycleOffsetNs: Int64,
                                     streamHostT0: UInt64,
                                     targetVideoFormat: VideoSlotFormat,
                                     sink: any MediaSink,
                                     resume: ResumePositionNs) async -> Bool {
        let videoTracks = asset.tracks(withMediaType: .video)
        let audioTracks = asset.tracks(withMediaType: .audio)
        guard let videoTrack = videoTracks.first else {
            Log.warn("VideoFileMediaSource: asset has no video track")
            return false
        }

        // Decode at the file's native dims (no width/height hints) — AVAssetReader
        // would otherwise stretch portrait/odd-aspect sources into the target.
        // Shim does the orientation-aware center-crop+scale uniformly.
        let videoSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: targetVideoFormat.pixelFormat.osType,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 48000,
        ]

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            Log.warn("VideoFileMediaSource: AVAssetReader init failed: \(error)")
            return false
        }
        if startAtNs > 0 {
            reader.timeRange = CMTimeRange(
                start: CMTime(value: startAtNs, timescale: 1_000_000_000),
                duration: CMTime.positiveInfinity
            )
        }

        let videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: videoSettings)
        videoOut.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOut) else {
            Log.warn("VideoFileMediaSource: cannot add video output")
            return false
        }
        reader.add(videoOut)

        let audioOut: AVAssetReaderTrackOutput?
        if let audioTrack = audioTracks.first {
            let o = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: audioSettings)
            o.alwaysCopiesSampleData = false
            if reader.canAdd(o) {
                reader.add(o)
                audioOut = o
            } else {
                Log.warn("VideoFileMediaSource: cannot add audio output — proceeding video-only")
                audioOut = nil
            }
        } else {
            audioOut = nil
        }

        guard reader.startReading() else {
            Log.warn("VideoFileMediaSource: startReading failed: \(reader.error?.localizedDescription ?? "unknown")")
            return false
        }

        var anchorPTSNs: Int64 = -1
        var pendingVideo: CMSampleBuffer? = nil
        var pendingAudio: CMSampleBuffer? = nil

        while !Task.isCancelled {
            if pendingVideo == nil { pendingVideo = videoOut.copyNextSampleBuffer() }
            if pendingAudio == nil, let a = audioOut { pendingAudio = a.copyNextSampleBuffer() }
            if pendingVideo == nil && pendingAudio == nil {
                let status = reader.status
                reader.cancelReading()
                if status == .failed {
                    Log.warn("VideoFileMediaSource: reader failed: \(reader.error?.localizedDescription ?? "unknown")")
                }
                return status == .completed
            }

            let pickVideo: Bool
            if pendingVideo == nil { pickVideo = false }
            else if pendingAudio == nil { pickVideo = true }
            else {
                let v = CMSampleBufferGetPresentationTimeStamp(pendingVideo!)
                let a = CMSampleBufferGetPresentationTimeStamp(pendingAudio!)
                pickVideo = v <= a
            }
            let sb = pickVideo ? pendingVideo! : pendingAudio!

            let rawPtsNs = ptsToNanoseconds(CMSampleBufferGetPresentationTimeStamp(sb))
            if anchorPTSNs < 0 { anchorPTSNs = rawPtsNs }

            let totalElapsedNs = (rawPtsNs - anchorPTSNs) + cycleOffsetNs
            let targetHost = streamHostT0 &+ UInt64(max(0, totalElapsedNs))
            let now = DispatchTime.now().uptimeNanoseconds
            if targetHost > now {
                try? await Task.sleep(nanoseconds: targetHost - now)
                if Task.isCancelled { break }
            }

            // PTS in mach-time scale — same as mac cam/mic — so AVAssetWriter's
            // session anchor lines up audio and video tracks correctly.
            let adjustedPtsNs = Int64(bitPattern: streamHostT0) &+ totalElapsedNs
            let adjustedPts = CMTime(value: adjustedPtsNs, timescale: 1_000_000_000)
            let dur = CMSampleBufferGetDuration(sb)

            if pickVideo {
                resume.value.store(rawPtsNs, ordering: .relaxed)
                if let pb = CMSampleBufferGetImageBuffer(sb) {
                    sink.sendVideo(pb, pts: adjustedPts, duration: dur)
                }
                pendingVideo = nil
            } else {
                if let pcm = audioPCMBuffer(from: sb) {
                    sink.sendAudio(pcm, pts: adjustedPts)
                }
                pendingAudio = nil
            }
        }

        reader.cancelReading()
        return false
    }

    private static func audioPCMBuffer(from sb: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sb),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return nil
        }
        var asbd = asbdPtr.pointee
        guard let avFormat = AVAudioFormat(streamDescription: &asbd) else { return nil }

        let frames = CMSampleBufferGetNumSamples(sb)
        guard frames > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: AVAudioFrameCount(frames)) else {
            return nil
        }
        pcm.frameLength = AVAudioFrameCount(frames)

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sb) else { return nil }
        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(blockBuffer,
                                                  atOffset: 0,
                                                  lengthAtOffsetOut: &lengthAtOffset,
                                                  totalLengthOut: &totalLength,
                                                  dataPointerOut: &dataPointer)
        guard status == noErr, let dataPointer, let dst = pcm.floatChannelData?[0] else {
            return nil
        }
        memcpy(dst, dataPointer, totalLength)
        return pcm
    }
}
