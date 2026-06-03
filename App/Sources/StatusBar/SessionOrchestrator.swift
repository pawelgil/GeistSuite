import AppKit
import AVFoundation
import Foundation
import Geist

@MainActor
protocol StreamingStateDelegate: AnyObject {
    func orchestrator(_ orchestrator: SessionOrchestrator, isStreamingChanged isStreaming: Bool)
}

@MainActor
final class SessionOrchestrator {
    struct Key: Hashable {
        let simulatorUDID: String
        let bundleID: String
    }

    private var sessions: [Key: any SessionDriving] = [:]
    private var streamingSessions: Set<ObjectIdentifier> = []
    weak var streamingDelegate: (any StreamingStateDelegate)?
    private let preferences: PreferencesStore
    private let permissions: any PermissionsQuerying
    private let mediaSourceFactory: any MediaSourceConstructing
    private let sessionMaker: any SessionMaking
    private let alertPresenter: any AlertPresenting

    var isAnyStreaming: Bool { !streamingSessions.isEmpty }

    init(preferences: PreferencesStore = .shared,
         permissions: any PermissionsQuerying = DefaultPermissions(),
         mediaSourceFactory: any MediaSourceConstructing = DefaultMediaSourceFactory(),
         sessionMaker: any SessionMaking = DefaultSessionMaker(),
         alertPresenter: (any AlertPresenting)? = nil) {
        let resolvedAlertPresenter: any AlertPresenting = alertPresenter ?? DefaultAlertPresenter()
        self.preferences = preferences
        self.permissions = permissions
        self.mediaSourceFactory = mediaSourceFactory
        self.sessionMaker = sessionMaker
        self.alertPresenter = resolvedAlertPresenter
    }

    var activeSessionCount: Int { sessions.count }

    var activeSessions: [(simulatorUDID: String, bundleID: String)] {
        sessions.keys
            .map { (simulatorUDID: $0.simulatorUDID, bundleID: $0.bundleID) }
            .sorted { $0.bundleID < $1.bundleID }
    }

    func hasActiveSession(simulatorUDID: String, bundleID: String) -> Bool {
        sessions[Key(simulatorUDID: simulatorUDID, bundleID: bundleID)] != nil
    }

    func handleSocketAppeared(_ entry: SocketWatcher.SocketEntry) {
        let key = Key(simulatorUDID: entry.simulatorUDID, bundleID: entry.bundleID)
        if sessions[key] != nil {
            Log.notice("Orchestrator.socketAppeared: \(entry.bundleID) already has session — ignoring")
            return
        }
        Log.notice("Orchestrator.socketAppeared: starting session for \(entry.bundleID) udid=\(entry.simulatorUDID)")

        let backEff = effectiveSource(simulatorUDID: entry.simulatorUDID, bundleID: entry.bundleID, side: .back)
        let frontEff = effectiveSource(simulatorUDID: entry.simulatorUDID, bundleID: entry.bundleID, side: .front)
        let needsCamera = isMacCam(backEff.persistable) || isMacCam(frontEff.persistable)

        let session = sessionMaker.make(simulatorUDID: entry.simulatorUDID,
                                            bundleID: entry.bundleID,
                                            delegate: self)
        sessions[key] = session

        Task { [weak self] in
            // Permission must be granted *before* AVCaptureSession opens — AVF
            // doesn't recover if the session is created while .notDetermined.
            if needsCamera {
                _ = await Self.ensurePermission(.video)
                _ = await Self.ensurePermission(.audio)
            }
            guard let self else { return }
            try? await self.attachSources(simulatorUDID: entry.simulatorUDID,
                                            bundleID: entry.bundleID, on: session)
            do {
                try await session.start(connectTimeout: 5)
            } catch {
                Log.warn("session.start failed for \(entry.bundleID): \(error) — unlinking stale socket")
                try? FileManager.default.removeItem(atPath: entry.path)
                _ = self.sessions.removeValue(forKey: key)
            }
        }
    }

    private static func ensurePermission(_ mediaType: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { c in
                AVCaptureDevice.requestAccess(for: mediaType) { c.resume(returning: $0) }
            }
        default: return false
        }
    }

    enum EffectiveSource {
        case configured(PersistableSource)
        case empty

        var displayLabel: String {
            switch self {
            case .configured(let s): return s.displayLabel
            case .empty: return "None"
            }
        }

        var persistable: PersistableSource? {
            if case .configured(let s) = self { return s }
            return nil
        }
    }

    func effectiveSource(simulatorUDID: String, bundleID: String, side: CameraSide) -> EffectiveSource {
        if let pref = preferences.source(simulatorUDID: simulatorUDID, bundleID: bundleID, side: side),
           pref.isUsable {
            return .configured(pref)
        }
        if let global = GlobalPreferences.shared.defaultSource, global.isUsable {
            return .configured(global)
        }
        if Permissions.cameraAuthorized, let device = AVCaptureDevice.default(for: .video) {
            return .configured(.macOSCamera(deviceUID: device.uniqueID))
        }
        return .empty
    }

    func handleSocketDisappeared(_ entry: SocketWatcher.SocketEntry) {
        let key = Key(simulatorUDID: entry.simulatorUDID, bundleID: entry.bundleID)
        guard let session = sessions.removeValue(forKey: key) else {
            Log.notice("Orchestrator.socketDisappeared: \(entry.bundleID) — no live session")
            return
        }
        Log.notice("Orchestrator.socketDisappeared: stopping session for \(entry.bundleID)")
        Task { await session.stop() }
    }

    func reevaluateAllSessions() {
        let snapshot = sessions
        Task {
            for (key, session) in snapshot {
                try? await self.attachSources(simulatorUDID: key.simulatorUDID,
                                                bundleID: key.bundleID, on: session)
            }
        }
    }

    func setSource(_ source: PersistableSource?, simulatorUDID: String, bundleID: String, side: CameraSide) {
        let key = Key(simulatorUDID: simulatorUDID, bundleID: bundleID)
        let oldSource = preferences.source(simulatorUDID: simulatorUDID, bundleID: bundleID, side: side)
        preferences.setSource(source, simulatorUDID: simulatorUDID, bundleID: bundleID, side: side)
        guard let session = sessions[key] else { return }
        Task {
            do {
                try await self.attachSources(simulatorUDID: simulatorUDID,
                                              bundleID: bundleID, on: session)
            } catch SourceSwitchError.recordingInProgress {
                preferences.setSource(oldSource, simulatorUDID: simulatorUDID, bundleID: bundleID, side: side)
                alertPresenter.showRecordingInProgress()
            }
        }
    }

    /// Rebuilds and attaches both sides' media sources, with audio routing
    /// (`.microphone` slot) decided by `AudioRouter`. Both sides are attached
    /// every time because changing one side's source can change which side's
    /// audio wins, requiring the other side to re-attach with a different
    /// audio-slot binding.
    private func attachSources(simulatorUDID: String, bundleID: String,
                                 on session: any SessionDriving) async throws(SourceSwitchError) {
        let backEff = effectiveSource(simulatorUDID: simulatorUDID, bundleID: bundleID, side: .back)
        let frontEff = effectiveSource(simulatorUDID: simulatorUDID, bundleID: bundleID, side: .front)
        let route = AudioRouter.decide(back: backEff.persistable,
                                        front: frontEff.persistable,
                                        cameraAuthorized: permissions.cameraAuthorized,
                                        microphoneAuthorized: permissions.microphoneAuthorized)
        Log.notice("Orchestrator.attachSources: \(bundleID) back=\(backEff.displayLabel) front=\(frontEff.displayLabel) route=\(route)")

        let backWantsMic: Bool
        let frontWantsMic: Bool
        switch route {
        case .detach:
            backWantsMic = false; frontWantsMic = false
        case .backAudio:
            backWantsMic = true; frontWantsMic = false
        case .frontAudio:
            backWantsMic = false; frontWantsMic = true
        case .macMicrophone:
            // Whichever side has the macCam carries the mic. Back wins ties.
            if isMacCam(backEff.persistable) {
                backWantsMic = true; frontWantsMic = false
            } else {
                backWantsMic = false; frontWantsMic = true
            }
        }

        let backSource = await mediaSourceFactory.make(backEff.persistable, wantsAudio: backWantsMic)
        let frontSource = await mediaSourceFactory.make(frontEff.persistable, wantsAudio: frontWantsMic)

        try await session.attachMediaSource(backSource,
                                              video: .backCamera,
                                              audio: backWantsMic ? .microphone : nil)
        try await session.attachMediaSource(frontSource,
                                              video: .frontCamera,
                                              audio: frontWantsMic ? .microphone : nil)
    }

    func micIsSilenced(simulatorUDID: String, bundleID: String, side: CameraSide) -> Bool {
        let back = preferences.source(simulatorUDID: simulatorUDID, bundleID: bundleID, side: .back)
        let front = preferences.source(simulatorUDID: simulatorUDID, bundleID: bundleID, side: .front)
        return AudioRouter.isMicSuppressed(for: side, back: back, front: front,
                                            cameraAuthorized: permissions.cameraAuthorized,
                                            microphoneAuthorized: permissions.microphoneAuthorized)
    }

    private func isMacCam(_ source: PersistableSource?) -> Bool {
        if case .macOSCamera = source { return true }
        return false
    }
}

extension SessionOrchestrator: GeistCameraSessionDelegate {
    nonisolated func sessionDidConnect(_ session: GeistCameraSession) {}

    nonisolated func sessionDidDisconnect(_ session: GeistCameraSession) {
        let ref = ObjectIdentifier(session)
        Task { @MainActor [weak self] in
            self?.handleSessionDisconnect(sessionRef: ref)
        }
    }

    nonisolated func session(_ session: GeistCameraSession, didActivateSlotWithoutSource slot: CameraSlot) {}

    nonisolated func session(_ session: GeistCameraSession, isStreamingChanged isStreaming: Bool) {
        let ref = ObjectIdentifier(session)
        Task { @MainActor [weak self] in
            self?.handleSessionStreamingChanged(ref: ref, isStreaming: isStreaming)
        }
    }
}

extension SessionOrchestrator {
    @MainActor
    private func handleSessionDisconnect(sessionRef: ObjectIdentifier) {
        guard let key = sessions.first(where: { ObjectIdentifier($0.value) == sessionRef })?.key else { return }
        Log.notice("Orchestrator.sessionDidDisconnect: \(key.bundleID) udid=\(key.simulatorUDID)")
        sessions.removeValue(forKey: key)
        let path = "/tmp/geistcam/\(key.simulatorUDID)/\(key.bundleID).sock"
        try? FileManager.default.removeItem(atPath: path)
        // Disconnect can race the lib's own idle-transition emit; drop
        // the session from streaming bookkeeping unconditionally.
        handleSessionStreamingChanged(ref: sessionRef, isStreaming: false)
        Task { await MenuStateCache.shared.refresh() }
    }

    @MainActor
    private func handleSessionStreamingChanged(ref: ObjectIdentifier, isStreaming: Bool) {
        let wasAny = !streamingSessions.isEmpty
        if isStreaming { streamingSessions.insert(ref) }
        else { streamingSessions.remove(ref) }
        let nowAny = !streamingSessions.isEmpty
        if wasAny != nowAny {
            streamingDelegate?.orchestrator(self, isStreamingChanged: nowAny)
        }
    }
}
