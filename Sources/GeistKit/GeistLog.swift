import Foundation
import os

/// Per-module logger. Each module (library or app) declares one as an
/// internal constant tagged with its own subsystem, e.g.
/// `internal let log = GeistLog(subsystem: "com.geist.camera")`.
/// Writes simultaneously to os_log (subsystem-filterable in Console.app)
/// and to `FileLogSink` (chronological text mirror under the host's
/// `~/Library/Logs/<bundle-name>/daemon.log`).
public struct GeistLog: Sendable {
    private let logger: os.Logger

    public init(subsystem: String, category: String = "default") {
        self.logger = os.Logger(subsystem: subsystem, category: category)
    }

    public func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
        FileLogSink.append(level: "D", message: message)
    }

    public func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        FileLogSink.append(level: "I", message: message)
    }

    /// `notice` is persisted to disk in the unified log (unlike `.info`/`.debug`,
    /// which are memory-only). Use for lifecycle and state-change events that
    /// need to survive long enough for remote diagnostics.
    public func notice(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        FileLogSink.append(level: "N", message: message)
    }

    public func warn(_ message: String) {
        logger.warning("\(message, privacy: .public)")
        FileLogSink.append(level: "W", message: message)
    }

    public func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        FileLogSink.append(level: "E", message: message)
    }
}
