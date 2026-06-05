import Foundation
import GeistCamera

enum LogPaths {
    static let logsDir = FileLogSink.logsDir
    static let daemonLog = FileLogSink.filePath
    static let shimLog = (logsDir as NSString).appendingPathComponent("shim.log")

    static func ensureLogsDir() {
        try? FileManager.default.createDirectory(
            atPath: logsDir, withIntermediateDirectories: true
        )
    }

    /// Truncates the daemon + shim logs at startup so each daemon launch
    /// starts with a clean slate. FileLogSink's fd uses `O_APPEND`, so a
    /// subsequent truncate from the same process keeps the descriptor
    /// valid; the shim file is opened by simulator processes that open
    /// their own descriptors lazily on first write.
    static func truncateSessionLogs() {
        if FileManager.default.fileExists(atPath: shimLog) {
            try? Data().write(to: URL(fileURLWithPath: shimLog))
        }
        FileLogSink.truncate()
    }
}
