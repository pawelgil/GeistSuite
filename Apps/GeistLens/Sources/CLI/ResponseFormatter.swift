import Foundation

enum ResponseFormatter {
    static func print(_ response: ControlResponse) -> Int32 {
        switch response {
        case .ok:
            Swift.print("ok")
            return 0
        case .error(let err):
            FileHandle.standardError.write(Data("error: \(err.message)\n".utf8))
            return 1
        case .list(let reply):
            printList(reply)
            return 0
        case .sources(let reply):
            printSources(reply)
            return 0
        case .status(let reply):
            printStatus(reply)
            return 0
        }
    }

    private static func printList(_ reply: ControlResponse.ListReply) {
        if reply.simulators.isEmpty {
            Swift.print("No booted simulators.")
            return
        }
        for sim in reply.simulators {
            let injectedTag = sim.injected ? "" : "  (shim not injected)"
            Swift.print("\(sim.displayLabel)\(injectedTag)")
            Swift.print("  \(sim.udid)")
            if sim.apps.isEmpty {
                Swift.print("  (no camera-capable apps installed)")
                continue
            }
            for app in sim.apps {
                let activeMark = app.active ? "●" : "○"
                Swift.print("")
                Swift.print("  \(activeMark) \(app.displayName)  (\(app.bundleID))")
                Swift.print("      back:  \(label(app.back, cameraNames: reply.cameraNames))")
                Swift.print("      front: \(label(app.front, cameraNames: reply.cameraNames))")
            }
        }
    }

    private static func printSources(_ reply: ControlResponse.SourcesReply) {
        if reply.cameras.isEmpty {
            Swift.print("No macOS cameras available.")
            return
        }
        for cam in reply.cameras {
            Swift.print("\(cam.uniqueID)  \(cam.localizedName)")
        }
    }

    private static func printStatus(_ reply: ControlResponse.StatusReply) {
        Swift.print("version:        \(reply.version)")
        Swift.print("control socket: \(reply.socketPath)")
        Swift.print("dylib:          \(reply.dylibInstalledAt ?? "not installed")")
        Swift.print("active sessions: \(reply.activeSessionCount)")
        Swift.print("injected sims:   \(reply.injectedSimulators.isEmpty ? "(none)" : reply.injectedSimulators.joined(separator: ", "))")
    }

    private static func label(_ source: PersistableSource?, cameraNames: [String: String]) -> String {
        guard let source else { return "(none)" }
        switch source {
        case .macOSCamera(let uid):
            let name = cameraNames[uid] ?? uid
            return "macOS camera (\(name))"
        case .video(let path): return "video (\((path as NSString).lastPathComponent))"
        case .image(let path): return "image (\((path as NSString).lastPathComponent))"
        }
    }
}
