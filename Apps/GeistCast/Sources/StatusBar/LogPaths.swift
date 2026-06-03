import Foundation
import GeistBroadcast

enum LogPaths {
    static let logsDir = FileLogSink.logsDir
    static let daemonLog = FileLogSink.filePath
    static let shimHostLog = (logsDir as NSString).appendingPathComponent("shim-host.log")
    static let shimExtensionLog = (logsDir as NSString).appendingPathComponent("shim-extension.log")

    // Kept for the legacy shim log path; an older release wrote to this
    // file via /tmp piping. New code uses shim-host.log / shim-extension.log.
    static let shimLog = (logsDir as NSString).appendingPathComponent("shim.log")

    static func ensureLogsDir() {
        try? FileManager.default.createDirectory(
            atPath: logsDir, withIntermediateDirectories: true
        )
    }

    /// Truncates the three session log files so each daemon launch starts
    /// with a clean slate. The daemon's own FileLogSink fd uses `O_APPEND`,
    /// so a subsequent truncate from the same process keeps the descriptor
    /// valid; the shim files are written by simulator processes that open
    /// their own descriptors lazily on first write, so truncating them
    /// here just shortens the file at startup before any shim has opened
    /// it for the current session.
    static func truncateSessionLogs() {
        for path in [daemonLog, shimHostLog, shimExtensionLog] {
            if FileManager.default.fileExists(atPath: path) {
                try? Data().write(to: URL(fileURLWithPath: path))
            }
        }
        FileLogSink.truncate()
    }
}
