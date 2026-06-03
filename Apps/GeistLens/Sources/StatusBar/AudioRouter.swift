import Foundation

/// Where the wire microphone slot's audio should come from for a given pair
/// of side sources.
enum MicRoute: Equatable {
    /// No mic source.
    case detach
    /// Use the mac mic — chosen whenever any side has the mac camera attached.
    case macMicrophone
    /// Use the back side's audio (e.g. an mp4 file's audio track).
    case backAudio
    /// Use the front side's audio.
    case frontAudio
}

/// Static rule for which audio source feeds the wire's `.microphone` slot.
///
/// Rule:
///   1. If either side is the mac camera AND camera + mic permissions are
///      granted, the mac microphone wins regardless of what the other side has.
///   2. Otherwise, the back side's audio source wins if it has audio.
///   3. Otherwise, the front side's audio source wins if it has audio.
///   4. Otherwise, no mic.
///
/// Mac-cam-but-mic-permission-denied: fall through to (2)–(4) — graceful
/// degradation rather than silent no-mic.
enum AudioRouter {
    static func decide(back: PersistableSource?,
                       front: PersistableSource?,
                       cameraAuthorized: Bool,
                       microphoneAuthorized: Bool) -> MicRoute {
        let anyMacCam = isMacCam(back) || isMacCam(front)
        if anyMacCam && cameraAuthorized && microphoneAuthorized {
            return .macMicrophone
        }
        // Fall-through when the macCam rule can't fire: skip macCam-side audio
        // entirely (it would also need mic permission, which we just failed).
        if hasNonMacCamAudio(back) { return .backAudio }
        if hasNonMacCamAudio(front) { return .frontAudio }
        return .detach
    }

    /// True if `side`'s configured source has audio that is being overridden
    /// by the routing rule (mac-mic wins, or the other side wins). Used for
    /// the "(mic muted)" hint in the menu.
    static func isMicSuppressed(for side: CameraSide,
                                  back: PersistableSource?,
                                  front: PersistableSource?,
                                  cameraAuthorized: Bool,
                                  microphoneAuthorized: Bool) -> Bool {
        let thisSide = (side == .back) ? back : front
        guard hasAudio(thisSide) else { return false }
        let route = decide(back: back, front: front,
                            cameraAuthorized: cameraAuthorized,
                            microphoneAuthorized: microphoneAuthorized)
        switch route {
        case .detach:
            return false
        case .macMicrophone:
            return !isMacCam(thisSide)
        case .backAudio:
            return side == .front
        case .frontAudio:
            return side == .back
        }
    }

    private static func isMacCam(_ source: PersistableSource?) -> Bool {
        if case .macOSCamera = source { return true }
        return false
    }

    /// A source "has audio" iff its underlying medium can supply a mic stream:
    /// .macOSCamera → mac mic (covered by the macCam rule); .video → the
    /// file's audio track. `.image` and `nil` have none.
    private static func hasAudio(_ source: PersistableSource?) -> Bool {
        switch source {
        case .macOSCamera, .video: return true
        case .image, nil: return false
        }
    }

    /// Excludes .macOSCamera from the audio-source check. Used in the
    /// permission-denied fall-through so we don't try to route through a
    /// side that would have the same failure mode as the original macCam rule.
    private static func hasNonMacCamAudio(_ source: PersistableSource?) -> Bool {
        switch source {
        case .video: return true
        case .macOSCamera, .image, nil: return false
        }
    }
}
