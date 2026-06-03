import Foundation
import Darwin

/// Appends log lines to `~/Library/Logs/GeistCast/daemon.log`. Mirrors the
/// `os_log` writes so a single `tail -f` of the file gives the daemon's
/// chronological story without round-tripping through `log show`.
///
/// Uses `O_APPEND` so concurrent writers from any thread or process
/// interleave atomically at the kernel level (Darwin guarantees this for
/// writes <= PIPE_BUF, which our log lines comfortably are).
public enum FileLogSink {
    public static let logsDir: String = {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Logs/GeistCast")
    }()
    public static let filePath: String = (logsDir as NSString)
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

    public static func append(level: String, message: String) {
        guard fd >= 0 else { return }
        let timestamp = timestampFormatter.string(from: Date())
        let line = "[\(timestamp)] [\(level)] \(message)\n"
        line.withCString { cstr in
            let len = strlen(cstr)
            _ = Darwin.write(fd, cstr, len)
        }
    }

    public static func truncate() {
        guard fd >= 0 else { return }
        _ = Darwin.ftruncate(fd, 0)
    }
}
