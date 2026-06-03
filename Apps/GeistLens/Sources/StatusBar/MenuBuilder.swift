import AppKit
import AVFoundation
import Foundation

@MainActor
final class MenuBuilder {
    private let orchestrator: SessionOrchestrator
    private let preferences: PreferencesStore

    init(orchestrator: SessionOrchestrator, preferences: PreferencesStore = .shared) {
        self.orchestrator = orchestrator
        self.preferences = preferences
    }

    func build() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(headerItem())
        addPermissionRowsIfNeeded(to: menu)
        menu.addItem(.separator())

        addAppList(to: menu)

        menu.addItem(.separator())
        menu.addItem(cliInstallerItem())
        menu.addItem(preferencesItem())
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit GeistLens",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        return menu
    }

    private func addPermissionRowsIfNeeded(to menu: NSMenu) {
        if !Permissions.cameraAuthorized && Permissions.cameraDeviceAvailable {
            menu.addItem(permissionRow(title: "Camera permission required",
                                       action: Permissions.openCameraSettings))
        }
        if !Permissions.microphoneAuthorized && Permissions.microphoneDeviceAvailable {
            menu.addItem(permissionRow(title: "Microphone permission required",
                                       action: Permissions.openMicrophoneSettings))
        }
    }

    private func permissionRow(title: String, action: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, handler: action)
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.systemOrange]))
        item.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                             accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        return item
    }

    private func headerItem() -> NSMenuItem {
        let item = NSMenuItem(title: "GeistLens", action: nil, keyEquivalent: "")
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let attributed = NSMutableAttributedString(string: "GeistLens", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ])
        if !version.isEmpty {
            attributed.append(NSAttributedString(string: "  \(version)", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
        }
        item.attributedTitle = attributed
        item.isEnabled = false
        return item
    }

    private func preferencesItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Preferences", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false

        let defaultParent = NSMenuItem(title: "Default source", action: nil, keyEquivalent: "")
        defaultParent.submenu = defaultSourcePicker()
        sub.addItem(defaultParent)

        let launchItem = ClosureMenuItem(title: "Launch at login",
                                         state: GlobalPreferences.shared.launchAtLogin ? .on : .off) {
            GlobalPreferences.shared.launchAtLogin.toggle()
        }
        sub.addItem(launchItem)

        sub.addItem(.separator())
        sub.addItem(ClosureMenuItem(title: "Report Issue…") { [weak self] in
            self?.reportIssue()
        })

        item.submenu = sub
        return item
    }

    private func defaultSourcePicker() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let current = GlobalPreferences.shared.defaultSource

        menu.addItem(ClosureMenuItem(title: "Default",
                                     state: current == nil ? .on : .off) {
            GlobalPreferences.shared.defaultSource = nil
        })
        menu.addItem(.separator())

        if Permissions.cameraAuthorized {
            let cameras = MacCameraEnumerator.devices()
            if cameras.count == 1 {
                let cam = cameras[0]
                let isOn = current == .macOSCamera(deviceUID: cam.uniqueID)
                menu.addItem(ClosureMenuItem(title: "macOS Camera (\(cam.localizedName))",
                                             state: isOn ? .on : .off) {
                    GlobalPreferences.shared.defaultSource = .macOSCamera(deviceUID: cam.uniqueID)
                })
            } else if cameras.count > 1 {
                let parent = NSMenuItem(title: "macOS Camera", action: nil, keyEquivalent: "")
                let sub = NSMenu()
                sub.autoenablesItems = false
                for cam in cameras {
                    let isOn = current == .macOSCamera(deviceUID: cam.uniqueID)
                    sub.addItem(ClosureMenuItem(title: cam.localizedName,
                                                state: isOn ? .on : .off) {
                        GlobalPreferences.shared.defaultSource = .macOSCamera(deviceUID: cam.uniqueID)
                    })
                }
                parent.submenu = sub
                menu.addItem(parent)
            }
        }

        menu.addItem(ClosureMenuItem(title: "Video File…",
                                     state: isVideo(current) ? .on : .off) { [weak self] in
            self?.pickFile(allowedExtensions: ["mp4", "mov", "m4v"]) { url in
                GlobalPreferences.shared.defaultSource = .video(path: url.path)
            }
        })

        menu.addItem(ClosureMenuItem(title: "Image File…",
                                     state: isImage(current) ? .on : .off) { [weak self] in
            self?.pickFile(allowedExtensions: ["png", "jpg", "jpeg", "heic"]) { url in
                GlobalPreferences.shared.defaultSource = .image(path: url.path)
            }
        })

        return menu
    }

    private func reportIssue() {
        let url: URL
        do {
            url = try IssueReport.generate()
        } catch {
            Log.warn("IssueReport.generate failed: \(error)")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Diagnostic bundle ready"
        alert.informativeText = "Logs and metadata written to:\n\(url.path)\n\nReveal the folder, then attach the contents to a GitHub issue."
        alert.addButton(withTitle: "Reveal in Finder")
        alert.addButton(withTitle: "Done")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func addAppList(to menu: NSMenu) {
        let sims = MenuStateCache.shared.bootedDevices
        guard !sims.isEmpty else {
            menu.addItem(disabled("No booted simulators"))
            return
        }
        var rows: [(sim: BootedDevice, app: InstalledApp)] = []
        for sim in sims {
            for app in MenuStateCache.shared.apps[sim.udid] ?? [] {
                rows.append((sim, app))
            }
        }
        guard !rows.isEmpty else {
            menu.addItem(disabled("No camera-capable apps installed"))
            return
        }
        rows.sort { ($0.app.displayName, $0.sim.name) < ($1.app.displayName, $1.sim.name) }
        for row in rows {
            menu.addItem(appRow(sim: row.sim, app: row.app))
        }
    }

    private func appRow(sim: BootedDevice, app: InstalledApp) -> NSMenuItem {
        let item = NSMenuItem()
        item.image = app.icon?.roundedSquircle(size: NSSize(width: 16, height: 16),
                                                cornerRadius: 3)
        let isStreaming = orchestrator.hasActiveSession(simulatorUDID: sim.udid, bundleID: app.bundleID)
        let title = NSMutableAttributedString()
        title.append(NSAttributedString(string: app.displayName, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]))
        title.append(NSAttributedString(string: "  \(sim.name)", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        if isStreaming {
            title.append(NSAttributedString(string: "  ●", attributes: [
                .font: NSFont.systemFont(ofSize: 9),
                .foregroundColor: NSColor.systemGreen,
            ]))
        }
        item.attributedTitle = title
        item.submenu = buildAppSubmenu(udid: sim.udid, app: app)
        return item
    }

    private func appEntry(udid: String, bundleID: String) -> InstalledApp? {
        MenuStateCache.shared.apps[udid]?.first { $0.bundleID == bundleID }
    }

    private func simEntry(udid: String) -> BootedDevice? {
        MenuStateCache.shared.bootedDevices.first { $0.udid == udid }
    }

    private func cliInstallerItem() -> NSMenuItem {
        switch CLIInstaller.currentState() {
        case .notInstalled:
            let item = ClosureMenuItem(title: "Install CLI tools") { [weak self] in
                self?.installCLI()
            }
            item.image = dotImage(color: .systemRed)
            return item
        case .installed(let path):
            let item = NSMenuItem(title: "CLI tools installed", action: nil, keyEquivalent: "")
            item.image = dotImage(color: .systemGreen)
            item.submenu = installedSubmenu(path: path)
            return item
        case .outdated:
            let item = ClosureMenuItem(title: "Update CLI tools") { [weak self] in
                self?.installCLI()
            }
            item.image = dotImage(color: .systemYellow)
            return item
        case .foreign(let path):
            let item = NSMenuItem(title: "CLI path conflict at \(path)", action: nil, keyEquivalent: "")
            item.image = dotImage(color: .systemOrange)
            item.toolTip = "A different tool occupies this path. Remove it manually, then install."
            return item
        }
    }

    private func installedSubmenu(path: String) -> NSMenu {
        let sub = NSMenu()
        sub.autoenablesItems = false
        let pathItem = NSMenuItem(title: path, action: nil, keyEquivalent: "")
        pathItem.isEnabled = false
        sub.addItem(pathItem)
        sub.addItem(.separator())
        sub.addItem(ClosureMenuItem(title: "Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        })
        sub.addItem(ClosureMenuItem(title: "Uninstall") {
            do { try CLIInstaller.uninstall() } catch { Log.warn("CLI uninstall failed: \(error)") }
        })
        return sub
    }

    private func installCLI() {
        do {
            _ = try CLIInstaller.install()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not install CLI tools"
            alert.informativeText = "\(error)"
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    private func dotImage(color: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    private func buildAppSubmenu(udid: String, app: InstalledApp) -> NSMenu {
        let sub = NSMenu()
        sub.autoenablesItems = false
        for side in CameraSide.allCases {
            sub.addItem(slotItem(udid: udid, app: app, side: side))
        }
        return sub
    }

    private func slotItem(udid: String, app: InstalledApp, side: CameraSide) -> NSMenuItem {
        let effective = orchestrator.effectiveSource(simulatorUDID: udid, bundleID: app.bundleID, side: side)
        let title = "\(side.displayName) Camera (\(effective.displayLabel))"
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.indentationLevel = 1
        if orchestrator.micIsSilenced(simulatorUDID: udid, bundleID: app.bundleID, side: side) {
            item.image = mutedMicImage()
            item.toolTip = "Audio is taken from the back source — only one mic stream can be sent."
        }
        item.submenu = sourcePicker(udid: udid, bundleID: app.bundleID, side: side, effective: effective)
        return item
    }

    private func mutedMicImage() -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.tertiaryLabelColor]))
        return NSImage(systemSymbolName: "microphone.slash.fill", accessibilityDescription: "Audio routed elsewhere")?
            .withSymbolConfiguration(config)
    }

    private func sourcePicker(udid: String, bundleID: String, side: CameraSide,
                              effective: SessionOrchestrator.EffectiveSource) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let activePersistable = effective.persistable

        if Permissions.cameraAuthorized {
            let cameras = MacCameraEnumerator.devices()
            if cameras.count == 1 {
                let cam = cameras[0]
                let isOn = isPicked(activePersistable, deviceUID: cam.uniqueID)
                menu.addItem(ClosureMenuItem(title: "macOS Camera (\(cam.localizedName))",
                                             state: isOn ? .on : .off) { [weak self] in
                    self?.pickMacCamera(deviceUID: cam.uniqueID, udid: udid, bundleID: bundleID, side: side)
                })
            } else if cameras.count > 1 {
                let parent = NSMenuItem(title: "macOS Camera", action: nil, keyEquivalent: "")
                let sub = NSMenu()
                sub.autoenablesItems = false
                for cam in cameras {
                    let isOn = isPicked(activePersistable, deviceUID: cam.uniqueID)
                    sub.addItem(ClosureMenuItem(title: cam.localizedName,
                                                state: isOn ? .on : .off) { [weak self] in
                        self?.pickMacCamera(deviceUID: cam.uniqueID, udid: udid, bundleID: bundleID, side: side)
                    })
                }
                parent.submenu = sub
                menu.addItem(parent)
            }
        }

        menu.addItem(ClosureMenuItem(title: "Video File…",
                                     state: isVideo(activePersistable) ? .on : .off) { [weak self] in
            self?.pickFile(allowedExtensions: ["mp4", "mov", "m4v"]) { url in
                self?.orchestrator.setSource(.video(path: url.path),
                                             simulatorUDID: udid, bundleID: bundleID, side: side)
            }
        })

        menu.addItem(ClosureMenuItem(title: "Image File…",
                                     state: isImage(activePersistable) ? .on : .off) { [weak self] in
            self?.pickFile(allowedExtensions: ["png", "jpg", "jpeg", "heic"]) { url in
                self?.orchestrator.setSource(.image(path: url.path),
                                             simulatorUDID: udid, bundleID: bundleID, side: side)
            }
        })

        return menu
    }

    private func pickFile(allowedExtensions: [String], handler: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = allowedExtensions
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            handler(url)
        }
    }

    private func pickMacCamera(deviceUID: String, udid: String, bundleID: String, side: CameraSide) {
        // Mic prompt must fire too — orchestrator auto-couples a mic source
        // for macOSCamera. Lazy-prompt-on-AVCaptureSession-start fails silently.
        Task { [weak self] in
            guard await Self.requestPermission(.video) else {
                Log.notice("Camera permission denied")
                return
            }
            guard await Self.requestPermission(.audio) else {
                Log.notice("Microphone permission denied")
                return
            }
            await MainActor.run {
                self?.applyMacCamera(deviceUID: deviceUID, udid: udid, bundleID: bundleID, side: side)
            }
        }
    }

    private static func requestPermission(_ mediaType: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { c in
                AVCaptureDevice.requestAccess(for: mediaType) { c.resume(returning: $0) }
            }
        default: return false
        }
    }

    private func applyMacCamera(deviceUID: String, udid: String, bundleID: String, side: CameraSide) {
        orchestrator.setSource(.macOSCamera(deviceUID: deviceUID),
                               simulatorUDID: udid, bundleID: bundleID, side: side)
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func isPicked(_ current: PersistableSource?, deviceUID: String) -> Bool {
        if case .macOSCamera(let uid) = current { return uid == deviceUID }
        return false
    }
    private func isVideo(_ current: PersistableSource?) -> Bool {
        if case .video = current { return true }; return false
    }
    private func isImage(_ current: PersistableSource?) -> Bool {
        if case .image = current { return true }; return false
    }

}
