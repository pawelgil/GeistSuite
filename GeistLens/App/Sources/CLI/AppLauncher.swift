import Darwin
import Foundation

enum AppLauncher {
    static func ownAppBundlePath() -> String? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buf = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buf, &size) == 0 else { return nil }
        let exePath = String(cString: buf)
        let resolved = (exePath as NSString).resolvingSymlinksInPath
        var url = URL(fileURLWithPath: resolved)
        while url.pathComponents.count > 1 {
            if url.pathExtension == "app" { return url.path }
            url = url.deletingLastPathComponent()
        }
        return nil
    }

    @discardableResult
    static func launchOwnApp() -> Bool {
        guard let appPath = ownAppBundlePath() else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", appPath]
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    static func waitForDaemon(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: ControlSocket.path),
               canConnect() {
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    private static func canConnect() -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        let path = ControlSocket.path
        guard path.utf8.count < cap else { return false }
        _ = path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dstPtr in
                dstPtr.withMemoryRebound(to: CChar.self, capacity: cap) { dst in
                    strlcpy(dst, src, cap)
                }
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, len)
            }
        }
        return result == 0
    }
}
