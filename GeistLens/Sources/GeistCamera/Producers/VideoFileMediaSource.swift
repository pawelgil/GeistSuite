import AVFoundation
import CoreMedia
import CoreVideo
import Dispatch
import Foundation
import GeistKit
import Synchronization

public enum VideoFileMediaSourceError: Error {
    case noVideoTrack
}

public final class VideoFileMediaSource: MediaSource {
    // MARK: Nested Types

    private final class ResumePosition: Sendable {
        let time = Mutex<CMTime>(.zero)
    }

    // MARK: Properties

    public let hasVideo: Bool = true
    public let hasAudio: Bool
    public let declaredVideoFormat: VideoSlotFormat?
    public let declaredAudioFormat: AudioSlotFormat?

    private let url: URL
    private let assetDuration: CMTime
    private let task = Mutex<Task<Void, Never>?>(nil)
    private let activeSink = Mutex<(any MediaSink)?>(nil)
    private let targetVideoFormat: Mutex<VideoSlotFormat>
    private let resume = ResumePosition()

    // MARK: Lifecycle

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
        declaredVideoFormat = declaredVideo
        targetVideoFormat = Mutex(declaredVideo)
        let audioTracks = asset.tracks(withMediaType: .audio)
        hasAudio = !audioTracks.isEmpty
        declaredAudioFormat = audioTracks.isEmpty ? nil : AudioSlotFormat(sampleRate: 48000, channels: 1)
        assetDuration = asset.duration
    }

    // MARK: Static Functions

    private static func ptsToNanoseconds(_ t: CMTime) -> Int64 {
        guard t.isValid else { return 0 }
        let scaled = CMTimeConvertScale(t, timescale: 1_000_000_000, method: .default)
        return scaled.value
    }

    private static func run(url: URL,
                            startAt: CMTime,
                            assetDuration: CMTime,
                            targetVideoFormat: VideoSlotFormat,
                            sink: any MediaSink,
                            resume: ResumePosition) async
    {
        let asset = AVURLAsset(url: url)
        let hostStart = CMClockGetTime(CMClockGetHostTimeClock())
        var timeline = LoopingMediaTimeline(start: hostStart, cycleDuration: assetDuration)
        var cycleStart = startAt
        while !Task.isCancelled {
            let completed = await runOneCycle(asset: asset,
                                              startAt: cycleStart,
                                              timeline: &timeline,
                                              targetVideoFormat: targetVideoFormat,
                                              sink: sink,
                                              resume: resume)
            if !completed { break }
            cycleStart = .zero
            timeline.advanceCycle()
        }
        log.notice("VideoFileMediaSource ended for \(url.lastPathComponent)")
    }

    private static func runOneCycle(asset: AVURLAsset,
                                    startAt: CMTime,
                                    timeline: inout LoopingMediaTimeline,
                                    targetVideoFormat: VideoSlotFormat,
                                    sink: any MediaSink,
                                    resume: ResumePosition) async -> Bool
    {
        let videoTracks = asset.tracks(withMediaType: .video)
        let audioTracks = asset.tracks(withMediaType: .audio)
        guard let videoTrack = videoTracks.first else {
            log.warn("VideoFileMediaSource: asset has no video track")
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
            log.warn("VideoFileMediaSource: AVAssetReader init failed: \(error)")
            return false
        }
        if startAt > .zero {
            reader.timeRange = CMTimeRange(
                start: startAt,
                duration: CMTime.positiveInfinity
            )
        }

        let videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: videoSettings)
        videoOut.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOut) else {
            log.warn("VideoFileMediaSource: cannot add video output")
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
                log.warn("VideoFileMediaSource: cannot add audio output — proceeding video-only")
                audioOut = nil
            }
        } else {
            audioOut = nil
        }

        guard reader.startReading() else {
            log.warn("VideoFileMediaSource: startReading failed: \(reader.error?.localizedDescription ?? "unknown")")
            return false
        }

        var pendingVideo: CMSampleBuffer? = nil
        var pendingAudio: CMSampleBuffer? = nil

        while !Task.isCancelled {
            if pendingVideo == nil { pendingVideo = videoOut.copyNextSampleBuffer() }
            if pendingAudio == nil, let a = audioOut { pendingAudio = a.copyNextSampleBuffer() }
            if pendingVideo == nil && pendingAudio == nil {
                let status = reader.status
                reader.cancelReading()
                if status == .failed {
                    log.warn("VideoFileMediaSource: reader failed: \(reader.error?.localizedDescription ?? "unknown")")
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

            let sourceTime = CMSampleBufferGetPresentationTimeStamp(sb)
            let adjustedPts = timeline.presentationTime(for: sourceTime)
            let targetHost = UInt64(max(0, ptsToNanoseconds(adjustedPts)))
            let now = DispatchTime.now().uptimeNanoseconds
            if targetHost > now {
                try? await Task.sleep(nanoseconds: targetHost - now)
            }
            if Task.isCancelled { break }
            let dur = CMSampleBufferGetDuration(sb)

            if pickVideo {
                resume.time.withLock { $0 = sourceTime }
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
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        else {
            return nil
        }
        var asbd = asbdPtr.pointee
        guard let avFormat = AVAudioFormat(streamDescription: &asbd) else { return nil }

        let frames = CMSampleBufferGetNumSamples(sb)
        guard frames > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: AVAudioFrameCount(frames))
        else {
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

    // MARK: Functions

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
        let startTime = resume.time.withLock { $0 }
        let assetDuration = self.assetDuration
        // The source owns cancellation; decoding state is task-local and resume is mutex-protected.
        let new = Task.detached(priority: .userInitiated) { [sink, resume] in
            await Self.run(url: url,
                           startAt: startTime,
                           assetDuration: assetDuration,
                           targetVideoFormat: snapshot,
                           sink: sink,
                           resume: resume)
        }
        task.withLock { $0 = new }
    }
}
