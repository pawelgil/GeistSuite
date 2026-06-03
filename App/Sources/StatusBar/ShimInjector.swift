import Foundation

protocol SimctlRunning: Sendable {
    func runSimctl(udid: String, args: [String]) -> Bool
    func captureSimctl(udid: String, args: [String]) -> String?
}

struct DefaultSimctlRunner: SimctlRunning {
    func runSimctl(udid: String, args: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "spawn", udid] + args
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        do {
            try process.run()
        } catch {
            Log.error("ShimInjector: failed to launch simctl: \(error)")
            return false
        }
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
            Log.warn("ShimInjector: simctl exit \(process.terminationStatus) for \(udid): \(err)")
            return false
        }
        return true
    }

    func captureSimctl(udid: String, args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "spawn", udid] + args
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        if process.terminationStatus != 0 { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ShimInjector {
    let runner: any SimctlRunning
    let shimLogPath: String

    init(runner: any SimctlRunning = DefaultSimctlRunner(),
         shimLogPath: String = LogPaths.shimLog) {
        self.runner = runner
        self.shimLogPath = shimLogPath
    }

    @discardableResult
    func injectDylib(_ dylibPath: String, intoSimulator udid: String) -> Bool {
        Log.notice("ShimInjector.inject: udid=\(udid) dylib=\(dylibPath)")
        let existing = runner.captureSimctl(udid: udid,
                                              args: ["launchctl", "getenv", "DYLD_INSERT_LIBRARIES"]) ?? ""
        let merged = Self.appending(dylibPath, to: existing)
        let dylibOk = runner.runSimctl(udid: udid,
                                         args: ["launchctl", "setenv", "DYLD_INSERT_LIBRARIES", merged])
        let logOk = runner.runSimctl(udid: udid,
                                       args: ["launchctl", "setenv", "GEISTCAM_LOG", shimLogPath])
        Log.notice("ShimInjector.inject result: udid=\(udid) dylibOk=\(dylibOk) logOk=\(logOk)")
        return dylibOk
    }

    @discardableResult
    func uninjectDylib(_ dylibPath: String, fromSimulator udid: String) -> Bool {
        Log.notice("ShimInjector.uninject: udid=\(udid) dylib=\(dylibPath)")
        _ = runner.runSimctl(udid: udid, args: ["launchctl", "unsetenv", "GEISTCAM_LOG"])
        let existing = runner.captureSimctl(udid: udid,
                                              args: ["launchctl", "getenv", "DYLD_INSERT_LIBRARIES"]) ?? ""
        let remaining = Self.removing(dylibPath, from: existing)
        let ok: Bool
        if remaining.isEmpty {
            ok = runner.runSimctl(udid: udid, args: ["launchctl", "unsetenv", "DYLD_INSERT_LIBRARIES"])
        } else {
            ok = runner.runSimctl(udid: udid, args: ["launchctl", "setenv", "DYLD_INSERT_LIBRARIES", remaining])
        }
        Log.notice("ShimInjector.uninject result: udid=\(udid) ok=\(ok)")
        return ok
    }

    static func appending(_ path: String, to existing: String) -> String {
        let parts = existing.split(separator: ":", omittingEmptySubsequences: true).map(String.init)
        guard !parts.contains(path) else { return existing }
        return (parts + [path]).joined(separator: ":")
    }

    static func removing(_ path: String, from existing: String) -> String {
        existing.split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != path }
            .joined(separator: ":")
    }
}
