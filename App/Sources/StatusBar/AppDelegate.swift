import AppKit
import AVFoundation
import Darwin

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var streamingDot: CAShapeLayer?
    private var simulatorWatcher: SimulatorWatcher?
    private var socketWatcher: SocketWatcher?
    private let orchestrator = SessionOrchestrator()
    private lazy var menuBuilder = MenuBuilder(orchestrator: orchestrator)
    private var installedShims: DylibInstaller.InstalledShims?
    private var injectedSimulators: Set<String> = []
    private var controlServer: ControlServer?
    private let shimInjector = ShimInjector()

    static func main() {
        // Default SIGPIPE handler kills us; we want EPIPE on dead-shim writes.
        signal(SIGPIPE, SIG_IGN)

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.notice("App: applicationDidFinishLaunching pid=\(getpid())")
        setupStatusItem()
        prepareShimLog()
        requestEagerPermissions()
        MenuStateCache.shared.startPolling(interval: 10)
        do {
            installedShims = try DylibInstaller.installIfNeeded()
            startSimulatorWatcher()
        } catch {
            Log.error("DylibInstaller failed: \(error). Auto-injection disabled.")
        }
        startSocketWatcher()
        startControlServer()
        registerSleepWakeObservers()
    }

    private func registerSleepWakeObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            Log.notice("App: NSWorkspace.willSleep")
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            let booted = SimulatorWatcher.queryBootedSimulators().sorted()
            let injected = self?.injectedSimulators.sorted() ?? []
            Log.notice("App: NSWorkspace.didWake — booted=\(booted) injected=\(injected)")
        }
        nc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { _ in
            Log.notice("App: NSWorkspace.screensDidSleep")
        }
        nc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in
            Log.notice("App: NSWorkspace.screensDidWake")
        }
        Log.notice("App: registered sleep/wake observers")
    }

    private func requestEagerPermissions() {
        Task { [weak self] in
            // No device-availability guards: AVCaptureDevice.DiscoverySession
            // for audio returns an empty list while mic permission is
            // .notDetermined, so a guard locks itself out on first launch.
            // requestAccess is a no-op if no device exists.
            _ = await AVCaptureDevice.requestAccess(for: .video)
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            await MainActor.run { self?.orchestrator.reevaluateAllSessions() }
        }
    }

    private func prepareShimLog() {
        try? FileManager.default.createDirectory(atPath: LogPaths.logsDir,
                                                  withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: LogPaths.shimLog, contents: nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        let injectedList = injectedSimulators.sorted()
        Log.notice("App: applicationWillTerminate injected=\(injectedList)")
        controlServer?.stop()
        // launchd_sim keeps DYLD_INSERT_LIBRARIES across our lifetime; leaving
        // it set breaks every future camera app launch in that sim.
        if let cameraDylib = installedShims?.cameraShimPath {
            for udid in injectedSimulators {
                shimInjector.uninjectDylib(cameraDylib, fromSimulator: udid)
            }
        }
    }

    private func startControlServer() {
        let handler = ControlHandler(orchestrator: orchestrator,
                                     injectedSimulators: { [weak self] in
                                         self?.injectedSimulators ?? []
                                     })
        let server = ControlServer(handler: handler)
        do {
            try server.start()
            controlServer = server
        } catch {
            Log.error("ControlServer failed to start: \(error). CLI control disabled.")
        }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.imageScaling = .scaleNone
            if let image = NSImage(named: "aperture") {
                image.isTemplate = true
                button.image = image
            } else if let image = NSImage(systemSymbolName: "camera.viewfinder",
                                          accessibilityDescription: "GeistLens") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "GL"
            }
            installStreamingDot(on: button)
        }
        orchestrator.streamingDelegate = self
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    private func installStreamingDot(on button: NSStatusBarButton) {
        button.wantsLayer = true
        let dot = CAShapeLayer()
        // Matches the inner-lens diameter of aperture.svg (lens r=5 in a 24
        // viewBox, button image rendered at 18pt). Update if the SVG changes.
        let side: CGFloat = 18.0 * 10.0 / 24.0
        dot.frame = CGRect(x: 0, y: 0, width: side, height: side)
        dot.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: side, height: side), transform: nil)
        dot.fillColor = NSColor.systemRed.cgColor
        dot.isHidden = true
        if let layer = button.layer {
            let mid = CGPoint(x: layer.bounds.midX, y: layer.bounds.midY)
            dot.position = mid
            dot.autoresizingMask = [.layerMinXMargin, .layerMaxXMargin, .layerMinYMargin, .layerMaxYMargin]
            layer.addSublayer(dot)
        }
        streamingDot = dot
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let fresh = menuBuilder.build()
        menu.removeAllItems()
        for item in fresh.items {
            fresh.removeItem(item)
            menu.addItem(item)
        }
    }

    private func startSimulatorWatcher() {
        guard let cameraDylib = installedShims?.cameraShimPath else { return }
        let watcher = SimulatorWatcher { [weak self] added, removed in
            self?.handleSimulatorChange(added: added, removed: removed, dylibPath: cameraDylib)
        }
        watcher.start()
        simulatorWatcher = watcher
    }

    private func handleSimulatorChange(added: Set<String>, removed: Set<String>, dylibPath: String) {
        let addedList = added.sorted()
        let removedList = removed.sorted()
        Log.notice("App.handleSimulatorChange: added=\(addedList) removed=\(removedList)")
        for udid in added {
            shimInjector.injectDylib(dylibPath, intoSimulator: udid)
            injectedSimulators.insert(udid)
        }
        for udid in removed {
            injectedSimulators.remove(udid)
        }
        Task { await MenuStateCache.shared.refresh() }
    }

    private func startSocketWatcher() {
        let watcher = SocketWatcher { [weak self] added, removed in
            guard let self else { return }
            let addedNames = added.map(\.bundleID).sorted()
            let removedNames = removed.map(\.bundleID).sorted()
            Log.notice("App.handleSocketChange: added=\(addedNames) removed=\(removedNames)")
            // Removals first: shim relaunch shows up as same-path/new-inode,
            // so old removed + new added share the orchestrator key. Adding
            // before clearing would no-op.
            for entry in removed { self.orchestrator.handleSocketDisappeared(entry) }
            for entry in added { self.orchestrator.handleSocketAppeared(entry) }
        }
        watcher.start()
        socketWatcher = watcher
    }
}

extension AppDelegate: StreamingStateDelegate {
    func orchestrator(_ orchestrator: SessionOrchestrator, isStreamingChanged isStreaming: Bool) {
        streamingDot?.isHidden = !isStreaming
    }
}
