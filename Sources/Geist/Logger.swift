import Foundation
import os

public enum Log {
    private static let logger = Logger(subsystem: "com.geistcast.app", category: "default")

    public static func debug(_ message: @autoclosure @escaping () -> String) {
        let msg = message()
        logger.debug("\(msg, privacy: .public)")
        FileLogSink.append(level: "D", message: msg)
    }
    public static func info(_ message: @autoclosure @escaping () -> String) {
        let msg = message()
        logger.info("\(msg, privacy: .public)")
        FileLogSink.append(level: "I", message: msg)
    }
    /// Persisted to disk in the unified log (unlike `.info`/`.debug`, which are
    /// memory-only). Use for lifecycle and state-change events that need to
    /// survive long enough for remote diagnostic via "Report Issue".
    public static func notice(_ message: @autoclosure @escaping () -> String) {
        let msg = message()
        logger.notice("\(msg, privacy: .public)")
        FileLogSink.append(level: "N", message: msg)
    }
    public static func warn(_ message: @autoclosure @escaping () -> String) {
        let msg = message()
        logger.warning("\(msg, privacy: .public)")
        FileLogSink.append(level: "W", message: msg)
    }
    public static func error(_ message: @autoclosure @escaping () -> String) {
        let msg = message()
        logger.error("\(msg, privacy: .public)")
        FileLogSink.append(level: "E", message: msg)
    }
}
