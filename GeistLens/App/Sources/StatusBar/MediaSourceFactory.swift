import Foundation
import GeistCamera

/// Maps a configured `PersistableSource` (per camera side) plus a "wants audio"
/// hint to a `MediaSource` instance. The hint lets the mac-cam case decide
/// whether to also subscribe the mic input from the shared session.
enum MediaSourceFactory {
    static func make(_ persistable: PersistableSource?,
                       wantsAudio: Bool) async -> any MediaSource {
        switch persistable {
        case .macOSCamera(let uid):
            do {
                return try await MacCamMicMediaSource(camDevice: .uniqueID(uid),
                                                       includeMic: wantsAudio)
            } catch {
                log.warn("MediaSourceFactory: macOSCamera failed (\(error)) — falling back to test pattern")
                return TestPatternMediaSource()
            }
        case .video(let path):
            do {
                return try VideoFileMediaSource(url: URL(fileURLWithPath: path))
            } catch {
                log.warn("MediaSourceFactory: video file failed (\(error)) — falling back to test pattern")
                return TestPatternMediaSource()
            }
        case .image(let path):
            do {
                return try StillImageMediaSource(url: URL(fileURLWithPath: path), fps: 5)
            } catch {
                log.warn("MediaSourceFactory: still image failed (\(error)) — falling back to test pattern")
                return TestPatternMediaSource()
            }
        case nil:
            return TestPatternMediaSource()
        }
    }
}
