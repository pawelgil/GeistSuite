import AppKit
import Foundation
import Geist

@MainActor
final class BroadcastCoordinator {

    struct SimulatorApps: Sendable, Equatable {
        let simulator: BootedSimulator
        let apps: [BroadcastApp]
    }

    private struct SessionKey: Hashable {
        let simulator: String
        let hostBundleID: String
    }

    weak var streamingDelegate: (any StreamingStateDelegate)?

    private var sessions: [SessionKey: GeistBroadcastSession] = [:]
    private var streamingKeys: Set<SessionKey> = []
    private var inFlightKeys: Set<SessionKey> = []
    private var cachedEntries: [SimulatorApps] = []
    private var pollTask: Task<Void, Never>?

    private let preferences: PreferencesStore
    private let globals: GlobalPreferences
    private let listing: any BootedSimulatorsListing

    init(preferences: PreferencesStore = .shared,
         globals: GlobalPreferences = .shared,
         listing: any BootedSimulatorsListing) {
        self.preferences = preferences
        self.globals = globals
        self.listing = listing
    }

    var isAnyStreaming: Bool { !streamingKeys.isEmpty }
    var activeSessionCount: Int { sessions.count }

    func cachedSimulatorApps() -> [SimulatorApps] { cachedEntries }

    func isStreaming(simulatorUDID: String, bundleID: String) -> Bool {
        inFlightKeys.contains(SessionKey(simulator: simulatorUDID, hostBundleID: bundleID))
    }

    func start() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshCatalog()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stop() async {
        pollTask?.cancel()
        let snapshot = Array(sessions.values)
        sessions.removeAll()
        streamingKeys.removeAll()
        inFlightKeys.removeAll()
        for session in snapshot { await session.stop() }
    }

    func removeSessions(for simulatorUDID: String) async {
        let keys = sessions.keys.filter { $0.simulator == simulatorUDID }
        for key in keys {
            if let session = sessions.removeValue(forKey: key) {
                await session.stop()
            }
            streamingKeys.remove(key)
            inFlightKeys.remove(key)
        }
        refreshStreamingState()
    }

    func setMicSource(_ source: PersistableMicSource?,
                      simulatorUDID: String,
                      bundleID: String) {
        preferences.setMicSource(source, simulatorUDID: simulatorUDID, bundleID: bundleID)
        let resolved = resolvedMicSource(simulatorUDID: simulatorUDID, bundleID: bundleID)
        let key = SessionKey(simulator: simulatorUDID, hostBundleID: bundleID)
        if let session = sessions[key] {
            Task { await session.setMicAudio(resolved) }
        }
    }

    func setDefaultMicSource(_ source: PersistableMicSource) {
        globals.defaultMicSource = source
        for (key, session) in sessions {
            let perApp = preferences.micSource(simulatorUDID: key.simulator,
                                                bundleID: key.hostBundleID)
            if perApp == nil {
                Task { await session.setMicAudio(MicSourceFactory.make(source)) }
            }
        }
    }

    func stopBroadcast(simulatorUDID: String, bundleID: String) {
        let key = SessionKey(simulator: simulatorUDID, hostBundleID: bundleID)
        guard let session = sessions[key] else { return }
        Task {
            await session.stopBroadcast()
            await self.recomputeStreamingState()
        }
    }

    private func resolvedMicSource(simulatorUDID: String, bundleID: String) -> MicSource {
        let source = preferences.micSource(simulatorUDID: simulatorUDID, bundleID: bundleID)
            ?? globals.defaultMicSource
        return MicSourceFactory.make(source)
    }

    private func refreshCatalog() async {
        do {
            let booted = try await listing.listBootedSimulators()
            var fresh: [SimulatorApps] = []
            for sim in booted {
                guard let udid = UUID(uuidString: sim.udid) else { continue }
                let apps = (try? await GeistBroadcastSession.broadcastCapableApps(
                    simulator: udid
                )) ?? []
                fresh.append(SimulatorApps(simulator: sim, apps: apps))
            }
            cachedEntries = fresh
            await reconcileSessions(from: fresh)
        } catch {
            Log.warn("BroadcastCoordinator: catalog refresh failed: \(error)")
        }
    }

    private func reconcileSessions(from entries: [SimulatorApps]) async {
        var desired: [SessionKey: String] = [:]
        for entry in entries {
            for app in entry.apps {
                let key = SessionKey(simulator: entry.simulator.udid,
                                     hostBundleID: app.hostBundleID)
                desired[key] = app.appexPath
            }
        }
        for (key, session) in sessions {
            let removeReason: String?
            if let desiredAppexPath = desired[key] {
                if session.extensionAppexPath != desiredAppexPath {
                    removeReason = "appexPath changed"
                } else {
                    removeReason = nil
                }
            } else {
                removeReason = "no longer in catalog"
            }
            if let reason = removeReason {
                sessions.removeValue(forKey: key)
                Log.notice("BroadcastCoordinator: session removed (\(reason)): \(key)")
                await session.stop()
                streamingKeys.remove(key)
                inFlightKeys.remove(key)
            }
        }
        for key in desired.keys where sessions[key] == nil {
            guard let udid = UUID(uuidString: key.simulator) else { continue }
            do {
                let session = try await GeistBroadcastSession(
                    simulator: udid,
                    hostBundleID: key.hostBundleID,
                    micAudio: resolvedMicSource(simulatorUDID: key.simulator,
                                                 bundleID: key.hostBundleID),
                    delegate: self
                )
                try await session.start()
                sessions[key] = session
                Log.notice("BroadcastCoordinator: session started: \(key)")
            } catch {
                Log.warn("BroadcastCoordinator: session start failed for \(key): \(error)")
            }
        }
        for session in sessions.values {
            await session.refreshStagedAppexIfNeeded()
        }
    }

    private func recomputeStreamingState() async {
        var streaming: Set<SessionKey> = []
        var inFlight: Set<SessionKey> = []
        for (key, session) in sessions {
            if await !session.activeBroadcasts.isEmpty { streaming.insert(key) }
            if await session.hasInFlightBroadcast { inFlight.insert(key) }
        }
        let wasAny = !streamingKeys.isEmpty
        streamingKeys = streaming
        inFlightKeys = inFlight
        let nowAny = !streamingKeys.isEmpty
        if wasAny != nowAny {
            streamingDelegate?.broadcastCoordinator(self, isStreamingChanged: nowAny)
        }
    }

    private func refreshStreamingState() {
        streamingDelegate?.broadcastCoordinator(self, isStreamingChanged: !streamingKeys.isEmpty)
    }
}

extension BroadcastCoordinator: GeistBroadcastSessionDelegate {
    nonisolated func session(_: GeistBroadcastSession, broadcastStarted broadcast: Broadcast) {
        Log.notice("broadcastStarted: host=\(broadcast.hostAppBundleID) sim=\(broadcast.simulatorUDID)")
        Task { @MainActor in await self.recomputeStreamingState() }
    }

    nonisolated func session(_: GeistBroadcastSession, broadcastEnded broadcast: Broadcast) {
        Log.notice("broadcastEnded: host=\(broadcast.hostAppBundleID)")
        Task { @MainActor in await self.recomputeStreamingState() }
    }

    nonisolated func session(_: GeistBroadcastSession,
                              broadcast: Broadcast,
                              terminatedWithError error: Error) {
        Log.error("broadcastTerminated: host=\(broadcast.hostAppBundleID) error=\(error)")
        Task { @MainActor in await self.recomputeStreamingState() }
    }

    nonisolated func session(_: GeistBroadcastSession,
                              broadcastFailedToStart broadcast: Broadcast,
                              error: Error) {
        Log.error("broadcastFailedToStart: host=\(broadcast.hostAppBundleID) error=\(error)")
        Task { @MainActor in await self.recomputeStreamingState() }
    }

    nonisolated func session(_: GeistBroadcastSession, extensionConnectedFor extensionBundleID: String) {
        Log.notice("extensionConnected: \(extensionBundleID)")
    }
}
