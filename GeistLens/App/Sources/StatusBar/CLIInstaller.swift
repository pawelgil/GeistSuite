import CryptoKit
import Foundation

enum CLIInstaller {
    static let candidateDirs: [String] = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
    ]

    private static let bundledTrampolineName = "geistlens-trampoline"
    private static let installedName = "geistlens"

    enum State: Equatable {
        case notInstalled
        case installed(at: String)
        case outdated(at: String)
        case foreign(at: String)
    }

    static func currentState() -> State {
        guard let bundled = bundledTrampolinePath(),
              let bundledHash = try? sha256(of: bundled) else {
            return .notInstalled
        }
        for dir in candidateDirs {
            let path = (dir as NSString).appendingPathComponent(installedName)
            guard FileManager.default.fileExists(atPath: path) else { continue }
            if let installedHash = try? sha256(of: path), installedHash == bundledHash {
                return .installed(at: path)
            }
            if isLikelyOurTrampoline(path: path) {
                return .outdated(at: path)
            }
            return .foreign(at: path)
        }
        return .notInstalled
    }

    @discardableResult
    static func install() throws -> String {
        guard let bundled = bundledTrampolinePath() else {
            throw InstallError.cannotResolveBundledTrampoline
        }
        let dir = chooseDestinationDir() ?? "/usr/local/bin"
        let dest = (dir as NSString).appendingPathComponent(installedName)
        if isWritable(dir) {
            try copyDirect(source: bundled, dest: dest)
        } else {
            try copyWithAdmin(source: bundled, dest: dest)
        }
        log.notice("CLIInstaller: installed \(dest) (from \(bundled))")
        return dest
    }

    static func uninstall() throws {
        switch currentState() {
        case .installed(let path), .outdated(let path):
            try remove(path: path)
            log.notice("CLIInstaller: removed \(path)")
        case .foreign, .notInstalled:
            return
        }
    }

    private static func remove(path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        if isWritable(dir) {
            try FileManager.default.removeItem(atPath: path)
        } else {
            try removeWithAdmin(path: path)
        }
    }

    private static func bundledTrampolinePath() -> String? {
        let appBundle = Bundle.main.bundlePath
        guard appBundle.hasSuffix(".app") else { return nil }
        let candidate = (appBundle as NSString)
            .appendingPathComponent("Contents/SharedSupport/\(bundledTrampolineName)")
        return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
    }

    private static func chooseDestinationDir() -> String? {
        candidateDirs.first(where: directoryExists)
    }

    private static func directoryExists(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func isWritable(_ path: String) -> Bool {
        FileManager.default.isWritableFile(atPath: path)
    }

    private static func sha256(of path: String) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isLikelyOurTrampoline(path: String) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return false }
        return data.range(of: Data("com.geistlens.geistlens".utf8)) != nil
    }

    private static func copyDirect(source: String, dest: String) throws {
        try? FileManager.default.removeItem(atPath: dest)
        try FileManager.default.copyItem(atPath: source, toPath: dest)
    }

    private static func copyWithAdmin(source: String, dest: String) throws {
        let script = """
        do shell script "/bin/cp \(quotedForAppleScript(source)) \(quotedForAppleScript(dest)) && /bin/chmod 0755 \(quotedForAppleScript(dest))" with administrator privileges
        """
        try runOsascript(script)
    }

    private static func removeWithAdmin(path: String) throws {
        let script = """
        do shell script "/bin/rm \(quotedForAppleScript(path))" with administrator privileges
        """
        try runOsascript(script)
    }

    private static func runOsascript(_ script: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let msg = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw InstallError.adminAuthFailed(message: msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func quotedForAppleScript(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    enum InstallError: Error, CustomStringConvertible {
        case cannotResolveBundledTrampoline
        case adminAuthFailed(message: String)

        var description: String {
            switch self {
            case .cannotResolveBundledTrampoline:
                return "Could not find geistlens-trampoline inside GeistLens.app/Contents/SharedSupport"
            case .adminAuthFailed(let msg):
                return msg.isEmpty ? "Administrator authorization failed" : msg
            }
        }
    }
}
