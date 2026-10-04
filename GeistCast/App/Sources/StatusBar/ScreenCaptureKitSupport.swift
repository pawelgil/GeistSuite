import AppKit
import GeistScreenCapture

@MainActor
final class ScreenCaptureKitSupport {
    private let installer: ScreenCaptureKitSupportInstaller
    private let globals = GlobalPreferences()
    private var compatibilityEnabled = false
    private var simulators: Set<String> = []
    private var sessions: [String: GeistScreenCaptureSession] = [:]
    private var transition: Task<Void, Never>?
    private var terminating = false

    init(installer: ScreenCaptureKitSupportInstaller) {
        self.installer = installer
    }

    func restore() {
        guard globals.screenCaptureKitSupportEnabled else { return }
        enqueue { await self.enable(showConfirmation: false) }
    }

    func updateSimulators(added: Set<String>, removed: Set<String>) {
        simulators.formUnion(added)
        simulators.subtract(removed)
        enqueue {
            for simulator in removed { await self.removeSession(for: simulator) }
            for simulator in added { await self.startSessionIfNeeded(simulator: simulator) }
        }
    }

    func prepareForTermination() -> [GeistScreenCaptureSession] {
        terminating = true
        transition?.cancel()
        let activeSessions = Array(sessions.values)
        sessions.removeAll()
        return activeSessions
    }

    private func stopSessions() async {
        let activeSessions = Array(sessions.values)
        sessions.removeAll()
        for session in activeSessions { await session.stop() }
    }

    func toggle() {
        enqueue {
            if self.globals.screenCaptureKitSupportEnabled {
                await self.disable()
            } else {
                await self.enable(showConfirmation: true)
            }
        }
    }

    private func enqueue(
        _ operation: @escaping @MainActor @Sendable () async -> Void
    ) {
        let previous = transition
        transition = Task {
            await previous?.value
            guard !Task.isCancelled, !self.terminating else { return }
            await operation()
        }
    }

    private func enable(showConfirmation: Bool) async {
        do {
            switch try await installer.enable() {
            case .compatibilityFramework:
                globals.screenCaptureKitSupportEnabled = true
                compatibilityEnabled = true
                for simulator in simulators {
                    await startSessionIfNeeded(simulator: simulator)
                }
                if showConfirmation, !terminating { showXcodeRestartAlert() }
            case .nativeSDK:
                globals.screenCaptureKitSupportEnabled = true
                compatibilityEnabled = false
                await stopSessions()
                if showConfirmation, !terminating { showNativeScreenCaptureKitAlert() }
            }
        } catch {
            compatibilityEnabled = false
            await stopSessions()
            log.error("ScreenCaptureKit support failed: \(error)")
            do {
                try await installer.disable()
                globals.screenCaptureKitSupportEnabled = false
            } catch {
                globals.screenCaptureKitSupportEnabled = true
                log.warn("ScreenCaptureKit support rollback failed: \(error)")
            }
        }
    }

    private func disable() async {
        do {
            try await installer.disable()
            globals.screenCaptureKitSupportEnabled = false
            compatibilityEnabled = false
            await stopSessions()
        } catch {
            globals.screenCaptureKitSupportEnabled = true
            log.warn("ScreenCaptureKit support disable failed: \(error)")
        }
    }

    private func startSessionIfNeeded(simulator: String) async {
        guard compatibilityEnabled, !terminating, simulators.contains(simulator),
              sessions[simulator] == nil,
              let simulatorID = UUID(uuidString: simulator)
        else { return }
        do {
            let session = try GeistScreenCaptureSession(simulator: simulatorID)
            try await session.start()
            guard !terminating, simulators.contains(simulator) else {
                await session.stop()
                return
            }
            sessions[simulator] = session
            log.notice("ScreenCaptureKit session started: \(simulator)")
        } catch {
            log.warn("ScreenCaptureKit session failed for \(simulator): \(error)")
        }
    }

    private func removeSession(for simulator: String) async {
        guard let session = sessions.removeValue(forKey: simulator) else { return }
        await session.stop()
    }

    private func showXcodeRestartAlert() {
        let alert = NSAlert()
        alert.messageText = "ScreenCaptureKit Simulator Support Enabled"
        alert.informativeText = "Restart Xcode once. Existing projects can then import ScreenCaptureKit for simulator builds without project changes."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showNativeScreenCaptureKitAlert() {
        let alert = NSAlert()
        alert.messageText = "Native ScreenCaptureKit Simulator Support Available"
        alert.informativeText = "GeistCast removed its compatibility override. Restart Xcode once to use the framework included with the selected SDK."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
