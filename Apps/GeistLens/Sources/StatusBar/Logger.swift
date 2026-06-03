import Foundation
import os

enum Log {
    private static let logger = Logger(subsystem: "com.geistlens.geistlens", category: "default")

    static func debug(_ message: @autoclosure @escaping () -> String) {
        logger.debug("\(message(), privacy: .public)")
    }
    static func info(_ message: @autoclosure @escaping () -> String) {
        logger.info("\(message(), privacy: .public)")
    }
    /// Persisted to disk in the unified log (unlike `.info`/`.debug`, which are
    /// memory-only). Use for lifecycle and state-change events that need to
    /// survive long enough for remote diagnostic via "Report Issue".
    static func notice(_ message: @autoclosure @escaping () -> String) {
        logger.notice("\(message(), privacy: .public)")
    }
    static func warn(_ message: @autoclosure @escaping () -> String) {
        logger.warning("\(message(), privacy: .public)")
    }
    static func error(_ message: @autoclosure @escaping () -> String) {
        logger.error("\(message(), privacy: .public)")
    }
}
