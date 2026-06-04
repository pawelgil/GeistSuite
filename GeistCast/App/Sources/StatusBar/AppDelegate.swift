import AppKit
import AVFoundation
import GeistBroadcast
import GeistKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate,
    GeistBroadcastSessionDelegate {

    struct SimulatorApps: Sendable, Equatable {
        let simulator: BootedSimulator
        let apps: [BroadcastApp]
    }

    private var statusItem: NSStatusItem?
    private var streamingDot: CAShapeLayer?
    private let listing: any BootedSimulatorsListing
    private var simulatorWatcher: EventDrivenSimulatorWatcher?
    private let injector: LaunchctlShimInjector
    private let preferences = PreferencesStore()
    private let globals = GlobalPreferences()
    private lazy var menuBuilder = MenuBuilder(
        preferences: preferences,
        globals: globals,
        actions: MenuBuilder.Actions(
            pickMicSource: { [weak self] sim, bundle, source in
                self?.setMicSource(source, simulatorUDID: sim, bundleID: bundle)
            },
            pickDefaultMicSource: { [weak self] source in
                self?.setDefaultMicSource(source)
            },
            chooseMicFile: { [weak self] apply in
                self?.chooseMicFile(apply: apply)
            },
            isStreaming: { [weak self] sim, bundle in
                let key = SessionKey(simulator: sim, hostBundleID: bundle)
                guard let self else { return false }
                return self.inFlightKeys.contains(key)
            },
            stopBroadcast: { [weak self] sim, bundle in
                self?.stopBroadcast(simulatorUDID: sim, bundleID: bundle)
            }
        )
    )
    private let dylibPath: String?
    private var cachedEntries: [SimulatorApps] = []
    private var sessions: [SessionKey: GeistBroadcastSession] = [:]
    private var streamingKeys: Set<SessionKey> = []
    private var inFlightKeys: Set<SessionKey> = []
    private var injectedSimulators: Set<String> = []
    private var pollTask: Task<Void, Never>?

    private struct SessionKey: Hashable {
        let simulator: String
        let hostBundleID: String
    }

    override init() {
        let process = LiveProcess()
        let listing = ProcessBootedSimulatorsListing(process: process)
        self.listing = listing
        self.injector = LaunchctlShimInjector(process: process)
        self.dylibPath = (try? DylibInstaller.installIfNeeded())
        if dylibPath == nil {
            log.warn("DylibInstaller failed; auto-injection disabled.")
        }
        super.init()
    }

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        LogPaths.ensureLogsDir()
        LogPaths.truncateSessionLogs()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        log.notice("GeistCast launched \(version) (\(build)) on \(ProcessInfo.processInfo.operatingSystemVersionString)")

        setupStatusItem()
        requestEagerPermissions()
        startCatalogPolling()
        startSimulatorWatching()
    }

    // Triggers the TCC prompt at launch so the app registers in
    // Privacy & Security → Microphone before a broadcast needs the mic.
    private func requestEagerPermissions() {
        Task {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        let sessionCount = sessions.count
        let injectedCount = injectedSimulators.count
        log.notice("applicationWillTerminate: stopping \(sessionCount) sessions, uninjecting from \(injectedCount) simulators")
        simulatorWatcher?.stop()
        pollTask?.cancel()
        let sessionList = Array(sessions.values)
        let injectedList = Array(injectedSimulators)
        let dylib = dylibPath
        let injector = self.injector
        let done = DispatchSemaphore(value: 0)
        // Detached: a MainActor-isolated Task would deadlock against
        // the semaphore.wait() below.
        Task.detached {
            for session in sessionList { await session.stop() }
            if let dylib {
                for udid in injectedList {
                    do {
                        try await injector.uninjectDylib(at: dylib, fromSimulator: udid)
                    } catch {
                        log.warn("uninjectDylib failed at shutdown: udid=\(udid) error=\(error)")
                    }
                }
            }
            done.signal()
        }
        if done.wait(timeout: .now() + 2) == .timedOut {
            log.warn("applicationWillTerminate: 2s shutdown watchdog fired")
        }
    }

    private enum IconGeometry {
        static let size: CGFloat = 18
        static let bodyWidth: CGFloat = 10
        static let bodyHeight: CGFloat = 15.5
        static let bodyCornerRadius: CGFloat = 2.25
        static let strokeWidth: CGFloat = 1.1
        static let bezelInset: CGFloat = 2.0
        static let innerCornerRadius: CGFloat = 0.85

        static var bodyRect: CGRect {
            CGRect(
                x: (size - bodyWidth) / 2,
                y: (size - bodyHeight) / 2,
                width: bodyWidth,
                height: bodyHeight
            )
        }

        static var innerRect: CGRect {
            bodyRect.insetBy(dx: bezelInset, dy: bezelInset)
        }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.imageScaling = .scaleNone
            let image = makeIPhoneOutlineImage()
            image.isTemplate = true
            button.image = image
            installStreamingFill(on: button)
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    private func makeIPhoneOutlineImage() -> NSImage {
        let size = NSSize(width: IconGeometry.size, height: IconGeometry.size)
        let image = NSImage(size: size, flipped: false) { _ in
            let path = NSBezierPath(
                roundedRect: IconGeometry.bodyRect,
                xRadius: IconGeometry.bodyCornerRadius,
                yRadius: IconGeometry.bodyCornerRadius
            )
            path.lineWidth = IconGeometry.strokeWidth
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        return image
    }

    private func installStreamingFill(on button: NSStatusBarButton) {
        button.wantsLayer = true
        let fill = CAShapeLayer()
        fill.frame = CGRect(origin: .zero, size: CGSize(
            width: IconGeometry.size, height: IconGeometry.size
        ))
        fill.path = CGPath(
            roundedRect: IconGeometry.innerRect,
            cornerWidth: IconGeometry.innerCornerRadius,
            cornerHeight: IconGeometry.innerCornerRadius,
            transform: nil
        )
        fill.fillColor = Self.idleFillColor.cgColor
        if let layer = button.layer {
            fill.position = CGPoint(x: layer.bounds.midX, y: layer.bounds.midY)
            fill.autoresizingMask = [.layerMinXMargin, .layerMaxXMargin,
                                       .layerMinYMargin, .layerMaxYMargin]
            layer.addSublayer(fill)
        }
        streamingDot = fill
    }

    private func startCatalogPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshCatalog()
                try? await Task.sleep(for: .seconds(5))
            }
        }
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
            log.warn("catalog refresh failed: \(error)")
        }
    }

    private func startSimulatorWatching() {
        let watcher = EventDrivenSimulatorWatcher(source: CoreSimulatorEventSource()) { [weak self] added, removed in
            MainActor.assumeIsolated {
                self?.handleSimulatorChange(added: added, removed: removed)
            }
        }
        if watcher.start() {
            simulatorWatcher = watcher
            log.notice("EventDrivenSimulatorWatcher: observing CoreSimulator notifications")
        } else {
            log.error("EventDrivenSimulatorWatcher: CoreSimulator unavailable — auto-injection disabled")
        }
    }

    private func handleSimulatorChange(added: Set<String>, removed: Set<String>) {
        for udid in added {
            log.notice("simulator booted: \(udid)")
            Task { await self.injectIfNeeded(simulator: udid) }
        }
        for udid in removed {
            log.notice("simulator shutdown: \(udid)")
            Task { await self.removeSessions(for: udid) }
        }
    }

    private func injectIfNeeded(simulator: String) async {
        guard let dylibPath, !injectedSimulators.contains(simulator) else { return }
        do {
            try await injector.injectDylib(at: dylibPath, intoSimulator: simulator)
            injectedSimulators.insert(simulator)
        } catch {
            log.warn("dylib injection into \(simulator) failed: \(error)")
        }
    }

    private func reconcileSessions(from entries: [SimulatorApps]) async {
        var desired: [SessionKey: String] = [:]
        for entry in entries {
            for app in entry.apps {
                let key = SessionKey(
                    simulator: entry.simulator.udid,
                    hostBundleID: app.hostBundleID
                )
                desired[key] = app.appexPath
            }
        }
        for (key, session) in sessions {
            let removeReason: String?
            if let desiredAppexPath = desired[key] {
                if session.extensionAppexPath != desiredAppexPath {
                    removeReason = "appexPath changed: \(session.extensionAppexPath) → \(desiredAppexPath)"
                } else {
                    removeReason = nil
                }
            } else {
                removeReason = "no longer in catalog"
            }
            if let reason = removeReason {
                sessions.removeValue(forKey: key)
                log.notice("session removed (\(reason)): \(key)")
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
                    micAudio: resolvedMicAudio(simulatorUDID: key.simulator,
                                                bundleID: key.hostBundleID),
                    delegate: self
                )
                try await session.start()
                sessions[key] = session
                log.notice("session started: \(key)")
            } catch {
                log.warn("session start failed for \(key): \(error)")
            }
        }
        for session in sessions.values {
            await session.refreshStagedAppexIfNeeded()
        }
    }

    private func removeSessions(for simulator: String) async {
        let keys = sessions.keys.filter { $0.simulator == simulator }
        for key in keys {
            if let session = sessions.removeValue(forKey: key) {
                await session.stop()
            }
            streamingKeys.remove(key)
            inFlightKeys.remove(key)
        }
        injectedSimulators.remove(simulator)
        refreshStreamingDot()
    }

    // MARK: - Mic source actions (from menu)

    private func setMicSource(_ source: PersistableMicSource?,
                              simulatorUDID: String,
                              bundleID: String) {
        preferences.setMicSource(source, simulatorUDID: simulatorUDID, bundleID: bundleID)
        let resolved = resolvedMicAudio(simulatorUDID: simulatorUDID, bundleID: bundleID)
        let key = SessionKey(simulator: simulatorUDID, hostBundleID: bundleID)
        if let session = sessions[key] {
            Task { await session.setMicAudio(resolved) }
        }
    }

    private func setDefaultMicSource(_ source: PersistableMicSource) {
        globals.defaultMicSource = source
        for (key, session) in sessions {
            let perApp = preferences.micSource(simulatorUDID: key.simulator,
                                                bundleID: key.hostBundleID)
            if perApp == nil {
                Task { await session.setMicAudio(MicSourceFactory.make(source)) }
            }
        }
    }

    private func chooseMicFile(apply: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Movie, .quickTimeMovie]
        panel.prompt = "Use as mic source"
        if panel.runModal() == .OK, let url = panel.url {
            apply(url)
        }
    }

    private func resolvedMicAudio(simulatorUDID: String, bundleID: String) -> MicAudioConfig {
        let source = preferences.micSource(simulatorUDID: simulatorUDID, bundleID: bundleID)
            ?? globals.defaultMicSource
        return MicSourceFactory.make(source)
    }

    private func stopBroadcast(simulatorUDID: String, bundleID: String) {
        let key = SessionKey(simulator: simulatorUDID, hostBundleID: bundleID)
        guard let session = sessions[key] else { return }
        Task {
            await session.stopBroadcast()
            await self.recomputeStreamingState()
        }
    }

    // MARK: - Session delegate

    nonisolated func session(_: GeistBroadcastSession, broadcastStarted broadcast: Broadcast) {
        log.notice("broadcastStarted: host=\(broadcast.hostAppBundleID) ext=\(broadcast.extensionBundleID) sim=\(broadcast.simulatorUDID)")
        Task { @MainActor in await self.recomputeStreamingState() }
    }

    nonisolated func session(_: GeistBroadcastSession, broadcastEnded broadcast: Broadcast) {
        log.notice("broadcastEnded: host=\(broadcast.hostAppBundleID) ext=\(broadcast.extensionBundleID)")
        Task { @MainActor in await self.recomputeStreamingState() }
    }

    nonisolated func session(_: GeistBroadcastSession,
                              broadcast: Broadcast,
                              terminatedWithError error: Error) {
        log.error("broadcastTerminated: host=\(broadcast.hostAppBundleID) error=\(error)")
        Task { @MainActor in await self.recomputeStreamingState() }
    }

    nonisolated func session(_: GeistBroadcastSession,
                              broadcastFailedToStart broadcast: Broadcast,
                              error: Error) {
        log.error("broadcastFailedToStart: host=\(broadcast.hostAppBundleID) error=\(error)")
        Task { @MainActor in await self.recomputeStreamingState() }
    }

    nonisolated func session(_: GeistBroadcastSession, extensionConnectedFor extensionBundleID: String) {
        log.notice("extensionConnected: \(extensionBundleID)")
    }

    private static let idleFillColor = NSColor.tertiaryLabelColor
    private static let activeFillColor = NSColor.systemRed

    // Single source of truth for streaming state. Recomputing from the
    // session's `activeBroadcasts` avoids stale entries from delegate
    // callbacks that don't cover every termination path.
    private func recomputeStreamingState() async {
        var streaming: Set<SessionKey> = []
        var inFlight: Set<SessionKey> = []
        for (key, session) in sessions {
            if await !session.activeBroadcasts.isEmpty {
                streaming.insert(key)
            }
            if await session.hasInFlightBroadcast {
                inFlight.insert(key)
            }
        }
        streamingKeys = streaming
        inFlightKeys = inFlight
        let color = streaming.isEmpty ? Self.idleFillColor : Self.activeFillColor
        streamingDot?.fillColor = color.cgColor
    }

    private func refreshStreamingDot() {
        let color = streamingKeys.isEmpty ? Self.idleFillColor : Self.activeFillColor
        streamingDot?.fillColor = color.cgColor
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let fresh = menuBuilder.build(entries: cachedEntries)
        let items = fresh.items
        menu.removeAllItems()
        for item in items {
            fresh.removeItem(item)
            menu.addItem(item)
        }
    }
}
