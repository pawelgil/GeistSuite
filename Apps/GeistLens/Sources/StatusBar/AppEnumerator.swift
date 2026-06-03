import AppKit
import Foundation

struct InstalledApp {
    let bundleID: String
    let displayName: String
    let bundlePath: String
    let icon: NSImage?
}

enum AppEnumerator {
    static func cameraCapableApps(udid: String) -> [InstalledApp] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "listapps", udid]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            Log.warn("simctl listapps failed: \(error)")
            return []
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: [String: Any]] else {
            return []
        }
        return plist.compactMap { bundleID, info -> InstalledApp? in
            if bundleID.hasPrefix("com.apple.") { return nil }
            guard let bundlePath = info["Path"] as? String else { return nil }
            let infoPlist = "\(bundlePath)/Info.plist"
            guard let appInfo = NSDictionary(contentsOfFile: infoPlist) as? [String: Any],
                  appInfo["NSCameraUsageDescription"] != nil else { return nil }
            let displayName = (info["CFBundleDisplayName"] as? String)
                ?? (appInfo["CFBundleDisplayName"] as? String)
                ?? (appInfo["CFBundleName"] as? String)
                ?? bundleID
            let icon = loadIcon(bundlePath: bundlePath, infoPlist: appInfo)
            return InstalledApp(bundleID: bundleID, displayName: displayName,
                                bundlePath: bundlePath, icon: icon)
        }.sorted { $0.displayName < $1.displayName }
    }

    private static func loadIcon(bundlePath: String, infoPlist: [String: Any]) -> NSImage? {
        let baseName = primaryIconName(from: infoPlist) ?? "AppIcon"
        let candidates = [
            "\(bundlePath)/\(baseName)@3x.png",
            "\(bundlePath)/\(baseName)@2x.png",
            "\(bundlePath)/\(baseName)60x60@3x.png",
            "\(bundlePath)/\(baseName)60x60@2x.png",
            "\(bundlePath)/\(baseName)40x40@3x.png",
            "\(bundlePath)/\(baseName)40x40@2x.png",
            "\(bundlePath)/\(baseName).png",
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path),
               let image = NSImage(contentsOfFile: path) {
                return image
            }
        }
        return NSWorkspace.shared.icon(forFile: bundlePath)
    }

    private static func primaryIconName(from infoPlist: [String: Any]) -> String? {
        if let icons = infoPlist["CFBundleIcons"] as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let files = primary["CFBundleIconFiles"] as? [String],
           let last = files.last {
            return last
        }
        if let icons = infoPlist["CFBundleIcons~ipad"] as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let files = primary["CFBundleIconFiles"] as? [String],
           let last = files.last {
            return last
        }
        return infoPlist["CFBundleIconFile"] as? String
    }
}
