import Foundation

/// Resolves the active Xcode developer directory needed by
/// `SimServiceContext(forDeveloperDir:)`. Tests inject a stub; production
/// code uses `LiveDeveloperDirResolver`, which reads `$DEVELOPER_DIR` first
/// and falls back to spawning `/usr/bin/xcode-select -p` once per call.
public protocol DeveloperDirResolving: Sendable {
    func resolve() -> String?
}

public struct LiveDeveloperDirResolver: DeveloperDirResolving {
    public init() {}

    public func resolve() -> String? {
        if let env = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !env.isEmpty {
            return env
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}
