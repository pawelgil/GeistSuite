import Foundation
import Darwin

/// Module-local mirror of Lib's FileLogSink. SimulatorScreenCapture sits
/// below GeistBroadcast in the dependency graph, so it can't pull in Lib's
/// type — both open `daemon.log` with `O_APPEND` and rely on kernel-level
/// atomicity for small writes to interleave cleanly.
enum FileLogSink {
    static let logsDir: String = {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Logs/GeistCast")
    }()
    static let filePath: String = (logsDir as NSString)
        .appendingPathComponent("daemon.log")

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let fd: Int32 = {
        try? FileManager.default.createDirectory(
            atPath: logsDir, withIntermediateDirectories: true
        )
        return Darwin.open(filePath, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    }()

    static func append(level: String, message: String) {
        guard fd >= 0 else { return }
        let timestamp = timestampFormatter.string(from: Date())
        let line = "[\(timestamp)] [\(level)] \(message)\n"
        line.withCString { cstr in
            let len = strlen(cstr)
            _ = Darwin.write(fd, cstr, len)
        }
    }
}
