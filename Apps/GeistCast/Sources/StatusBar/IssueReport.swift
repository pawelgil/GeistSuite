import Foundation

enum IssueReport {
    static let bundleDir = (NSTemporaryDirectory() as NSString)
        .appendingPathComponent("geistcast-issue-report")

    static func generate() throws -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let dir = (bundleDir as NSString).appendingPathComponent(stamp)
        try FileManager.default.createDirectory(atPath: dir,
                                                withIntermediateDirectories: true)

        try writeMetadata(into: dir)
        copySessionLogs(into: dir)

        return URL(fileURLWithPath: dir)
    }

    private static func copySessionLogs(into dir: String) {
        for src in [LogPaths.daemonLog, LogPaths.shimHostLog, LogPaths.shimExtensionLog] {
            guard FileManager.default.fileExists(atPath: src) else { continue }
            let dest = (dir as NSString)
                .appendingPathComponent((src as NSString).lastPathComponent)
            try? FileManager.default.copyItem(atPath: src, toPath: dest)
        }
    }

    private static func writeMetadata(into dir: String) throws {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let arch: String = {
            #if arch(arm64)
            return "arm64"
            #elseif arch(x86_64)
            return "x86_64"
            #else
            return "unknown"
            #endif
        }()
        let xcode = (try? runProcess("/usr/bin/xcodebuild", ["-version"])) ?? "(xcodebuild unavailable)"
        let booted = (try? runProcess("/usr/bin/xcrun", ["simctl", "list", "devices", "booted"])) ?? "(simctl unavailable)"

        let lines = """
        GeistCast \(version) (\(build))
        \(os)  \(arch)
        Generated: \(Date())

        --- Xcode ---
        \(xcode)

        --- Booted simulators ---
        \(booted)
        """
        try lines.write(toFile: (dir as NSString).appendingPathComponent("metadata.txt"),
                        atomically: true, encoding: .utf8)
    }

    private static func runProcess(_ executable: String, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
