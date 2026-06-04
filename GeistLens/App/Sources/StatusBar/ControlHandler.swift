import AVFoundation
import Foundation

@MainActor
final class ControlHandler {
    private let orchestrator: SessionOrchestrator
    private let preferences: PreferencesStore
    private let injectedSimulators: () -> Set<String>

    init(orchestrator: SessionOrchestrator,
         preferences: PreferencesStore = .shared,
         injectedSimulators: @escaping () -> Set<String>) {
        self.orchestrator = orchestrator
        self.preferences = preferences
        self.injectedSimulators = injectedSimulators
    }

    func handle(_ request: ControlRequest) async -> ControlResponse {
        switch request {
        case .list: return .list(buildList())
        case .sources: return .sources(buildSources())
        case .status: return .status(buildStatus())
        case .set(let args): return await apply(args)
        case .unset(let args): return apply(args)
        }
    }

    private func buildList() -> ControlResponse.ListReply {
        let injected = injectedSimulators()
        let sims = MenuStateCache.shared.bootedDevices.map { sim in
            let apps = MenuStateCache.shared.apps[sim.udid] ?? []
            return ControlResponse.SimulatorReply(
                udid: sim.udid,
                name: sim.name,
                runtime: sim.runtime,
                displayLabel: sim.displayLabel,
                injected: injected.contains(sim.udid),
                apps: apps.map { app in
                    ControlResponse.AppReply(
                        bundleID: app.bundleID,
                        displayName: app.displayName,
                        back: preferences.source(simulatorUDID: sim.udid, bundleID: app.bundleID, side: .back),
                        front: preferences.source(simulatorUDID: sim.udid, bundleID: app.bundleID, side: .front),
                        active: orchestrator.hasActiveSession(simulatorUDID: sim.udid, bundleID: app.bundleID)
                    )
                }
            )
        }
        let cameraNames = Dictionary(uniqueKeysWithValues:
            MacCameraEnumerator.devices().map { ($0.uniqueID, $0.localizedName) })
        return .init(simulators: sims, cameraNames: cameraNames)
    }

    private func buildSources() -> ControlResponse.SourcesReply {
        let cameras = MacCameraEnumerator.devices().map {
            ControlResponse.CameraInfo(uniqueID: $0.uniqueID, localizedName: $0.localizedName)
        }
        return .init(cameras: cameras)
    }

    private func buildStatus() -> ControlResponse.StatusReply {
        let dylibPath = FileManager.default.fileExists(atPath: DylibInstaller.installPath)
            ? DylibInstaller.installPath
            : nil
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        return .init(
            version: version,
            socketPath: ControlSocket.path,
            dylibInstalledAt: dylibPath,
            injectedSimulators: Array(injectedSimulators()).sorted(),
            activeSessionCount: orchestrator.activeSessionCount
        )
    }

    private func apply(_ args: ControlRequest.SetArgs) async -> ControlResponse {
        guard let udid = resolveSimulator(args.simulator) else {
            return .error(.init(message: ambiguousSimulatorMessage(args.simulator)))
        }
        if case .macOSCamera = args.source {
            // Mic prompt must fire too — orchestrator auto-couples mic for
            // macOSCamera. Lazy-prompt-on-session-start fails silently.
            if !(await ensurePermission(.video)) {
                return .error(.init(message: "macOS camera access denied. Enable in System Settings → Privacy & Security → Camera, then retry."))
            }
            if !(await ensurePermission(.audio)) {
                return .error(.init(message: "Microphone access denied. Enable in System Settings → Privacy & Security → Microphone, then retry."))
            }
        }
        orchestrator.setSource(args.source, simulatorUDID: udid, bundleID: args.bundleID, side: args.side)
        return .ok
    }

    private func apply(_ args: ControlRequest.UnsetArgs) -> ControlResponse {
        guard let udid = resolveSimulator(args.simulator) else {
            return .error(.init(message: ambiguousSimulatorMessage(args.simulator)))
        }
        orchestrator.setSource(nil, simulatorUDID: udid, bundleID: args.bundleID, side: args.side)
        return .ok
    }

    private func resolveSimulator(_ token: String) -> String? {
        if token != "booted" { return token }
        let booted = MenuStateCache.shared.bootedDevices.map(\.udid)
        return booted.count == 1 ? booted.first : nil
    }

    private func ambiguousSimulatorMessage(_ token: String) -> String {
        guard token == "booted" else { return "no simulator with UDID \(token)" }
        let count = MenuStateCache.shared.bootedDevices.count
        if count == 0 { return "no booted simulators" }
        return "multiple booted simulators (\(count)); pass an explicit UDID"
    }

    private func ensurePermission(_ mediaType: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { c in
                AVCaptureDevice.requestAccess(for: mediaType) { c.resume(returning: $0) }
            }
        default: return false
        }
    }
}
