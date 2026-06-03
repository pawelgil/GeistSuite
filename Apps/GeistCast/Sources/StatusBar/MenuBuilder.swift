import AppKit
import GeistBroadcast

@MainActor
struct MenuBuilder {
    struct Actions {
        let pickMicSource: (_ simulatorUDID: String,
                            _ bundleID: String,
                            _ source: PersistableMicSource?) -> Void
        let pickDefaultMicSource: (_ source: PersistableMicSource) -> Void
        let chooseMicFile: (_ apply: @escaping (URL) -> Void) -> Void
        let isStreaming: (_ simulatorUDID: String, _ bundleID: String) -> Bool
        let stopBroadcast: (_ simulatorUDID: String, _ bundleID: String) -> Void
    }

    let preferences: PreferencesStore
    let globals: GlobalPreferences
    let actions: Actions

    func build(entries: [AppDelegate.SimulatorApps]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(headerItem())
        menu.addItem(.separator())

        if !Permissions.microphoneAuthorized {
            menu.addItem(permissionRow())
            menu.addItem(.separator())
        }

        var rows: [(sim: BootedSimulator, app: BroadcastApp)] = []
        for entry in entries {
            for app in entry.apps { rows.append((entry.simulator, app)) }
        }
        rows.sort { ($0.app.displayName, $0.sim.name) < ($1.app.displayName, $1.sim.name) }

        if entries.isEmpty {
            menu.addItem(emptyStateItem(text: "No booted simulators"))
        } else if rows.isEmpty {
            menu.addItem(emptyStateItem(text: "No broadcast-capable apps installed"))
        } else {
            for row in rows {
                menu.addItem(appRow(sim: row.sim, app: row.app))
            }
        }

        menu.addItem(.separator())
        menu.addItem(preferencesItem())
        menu.addItem(supportItem())
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Quit GeistCast",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        return menu
    }

    private func supportItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Support", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        sub.addItem(ClosureMenuItem(title: "Report Issue…") { reportIssue() })
        sub.addItem(ClosureMenuItem(title: "Reveal Logs in Finder") { revealLogs() })
        sub.addItem(ClosureMenuItem(title: "Stream Logs in Console") { openConsole() })
        item.submenu = sub
        return item
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

    private func revealLogs() {
        LogPaths.ensureLogsDir()
        NSWorkspace.shared.activateFileViewerSelecting([
            URL(fileURLWithPath: LogPaths.logsDir),
        ])
    }

    private func openConsole() {
        // Console.app's deep-link URL scheme accepts a process-name filter via
        // an `x-apple-console:` URL, but the safer cross-version path is to
        // launch Console and copy the predicate hint into the alert.
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"))
        let alert = NSAlert()
        alert.messageText = "Streaming GeistCast logs"
        alert.informativeText = "In Console.app, paste this into the search:\n\n  subsystem:com.geistcast"
        alert.addButton(withTitle: "Copy filter")
        alert.addButton(withTitle: "Done")
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("subsystem:com.geistcast", forType: .string)
        }
    }

    private func headerItem() -> NSMenuItem {
        let item = NSMenuItem(title: "GeistCast", action: nil, keyEquivalent: "")
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let title = NSMutableAttributedString(string: "GeistCast", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ])
        if !version.isEmpty {
            title.append(NSAttributedString(string: "  \(version)", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
        }
        item.attributedTitle = title
        item.isEnabled = false
        return item
    }

    private func permissionRow() -> NSMenuItem {
        ClosureMenuItem(title: "⚠ Microphone permission required") {
            Permissions.openMicrophoneSettings()
        }
    }

    private func appRow(sim: BootedSimulator, app: BroadcastApp) -> NSMenuItem {
        let item = NSMenuItem()
        item.image = AppIconLoader.shared.loadIcon(appPath: app.appPath)?
            .roundedSquircle(size: NSSize(width: 16, height: 16), cornerRadius: 3)
        let title = NSMutableAttributedString()
        title.append(NSAttributedString(string: app.displayName, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]))
        title.append(NSAttributedString(string: "  \(sim.name)", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        if actions.isStreaming(sim.udid, app.hostBundleID) {
            title.append(NSAttributedString(string: "  ●", attributes: [
                .font: NSFont.systemFont(ofSize: 9),
                .foregroundColor: NSColor.systemRed,
            ]))
        }
        item.attributedTitle = title
        item.submenu = micSourceSubmenu(simulatorUDID: sim.udid, bundleID: app.hostBundleID)
        return item
    }

    private func micSourceSubmenu(simulatorUDID: String, bundleID: String) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        if actions.isStreaming(simulatorUDID, bundleID) {
            menu.addItem(ClosureMenuItem(title: "Stop recording") {
                actions.stopBroadcast(simulatorUDID, bundleID)
            })
            menu.addItem(.separator())
        }

        let current = preferences.micSource(simulatorUDID: simulatorUDID, bundleID: bundleID)
        let defaultSource = globals.defaultMicSource

        menu.addItem(ClosureMenuItem(
            title: "Use default (\(displayLabel(defaultSource)))",
            state: current == nil ? .on : .off
        ) {
            actions.pickMicSource(simulatorUDID, bundleID, nil)
        })
        menu.addItem(.separator())

        for item in micSourceRows(current: current, onPick: { source in
            actions.pickMicSource(simulatorUDID, bundleID, source)
        }) {
            menu.addItem(item)
        }
        return menu
    }

    private func preferencesItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Preferences", action: nil, keyEquivalent: "")
        item.submenu = defaultMicSourceSubmenu()
        return item
    }

    private func defaultMicSourceSubmenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let header = NSMenuItem(title: "Default microphone source", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        for item in micSourceRows(current: globals.defaultMicSource,
                                  onPick: { actions.pickDefaultMicSource($0) }) {
            menu.addItem(item)
        }
        return menu
    }

    private func micSourceRows(
        current: PersistableMicSource?,
        onPick: @escaping (PersistableMicSource) -> Void
    ) -> [NSMenuItem] {
        let mediaFileTitle: String
        let mediaFileChecked: Bool
        if case let .mediaFile(path) = current {
            mediaFileTitle = "Audio file… (\((path as NSString).lastPathComponent))"
            mediaFileChecked = true
        } else {
            mediaFileTitle = "Audio file…"
            mediaFileChecked = false
        }
        let chooseMicFile = actions.chooseMicFile
        return [
            ClosureMenuItem(
                title: "System microphone",
                state: current == .systemMicrophone ? .on : .off
            ) { onPick(.systemMicrophone) },
            ClosureMenuItem(
                title: mediaFileTitle,
                state: mediaFileChecked ? .on : .off
            ) {
                chooseMicFile { url in onPick(.mediaFile(path: url.path)) }
            },
            ClosureMenuItem(
                title: "Disabled",
                state: current == .disabled ? .on : .off
            ) { onPick(.disabled) },
        ]
    }

    private func emptyStateItem(text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func displayLabel(_ source: PersistableMicSource) -> String {
        switch source {
        case .systemMicrophone: return "System microphone"
        case .mediaFile(let path): return (path as NSString).lastPathComponent
        case .disabled: return "Disabled"
        }
    }

}
