import AppKit
import Foundation

/// @unchecked Sendable: `NSCache` is documented thread-safe but not
/// formally Sendable.
final class AppIconLoader: @unchecked Sendable {
    static let shared = AppIconLoader()

    private let cache = NSCache<NSString, NSImage>()

    func loadIcon(appPath: String) -> NSImage? {
        if let cached = cache.object(forKey: appPath as NSString) { return cached }
        let icon = Self.read(appPath: appPath)
        if let icon { cache.setObject(icon, forKey: appPath as NSString) }
        return icon
    }

    private static func read(appPath: String) -> NSImage? {
        let infoPath = "\(appPath)/Info.plist"
        let infoPlist: [String: Any]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: infoPath)),
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
            infoPlist = plist
        } else {
            infoPlist = [:]
        }
        let baseName = primaryIconName(from: infoPlist) ?? "AppIcon"
        let candidates = [
            "\(appPath)/\(baseName)@3x.png",
            "\(appPath)/\(baseName)@2x.png",
            "\(appPath)/\(baseName)60x60@3x.png",
            "\(appPath)/\(baseName)60x60@2x.png",
            "\(appPath)/\(baseName)40x40@3x.png",
            "\(appPath)/\(baseName)40x40@2x.png",
            "\(appPath)/\(baseName).png",
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path),
               let image = NSImage(contentsOfFile: path) {
                return image
            }
        }
        return NSWorkspace.shared.icon(forFile: appPath)
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

extension NSImage {
    func roundedSquircle(size: NSSize, cornerRadius: CGFloat) -> NSImage {
        let target = NSImage(size: size)
        target.lockFocus()
        let rect = NSRect(origin: .zero, size: size)
        let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        path.addClip()
        self.draw(in: rect)
        target.unlockFocus()
        return target
    }
}
