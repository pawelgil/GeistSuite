import Foundation
import os

enum Log {
    private static let logger = Logger(subsystem: "com.geistcast.app", category: "capture")

    static func debug(_ message: @autoclosure @escaping () -> String) {
        let msg = message()
        logger.debug("\(msg, privacy: .public)")
        FileLogSink.append(level: "D", message: "[capture] \(msg)")
    }
    static func info(_ message: @autoclosure @escaping () -> String) {
        let msg = message()
        logger.info("\(msg, privacy: .public)")
        FileLogSink.append(level: "I", message: "[capture] \(msg)")
    }
    static func notice(_ message: @autoclosure @escaping () -> String) {
        let msg = message()
        logger.notice("\(msg, privacy: .public)")
        FileLogSink.append(level: "N", message: "[capture] \(msg)")
    }
    static func warn(_ message: @autoclosure @escaping () -> String) {
        let msg = message()
        logger.warning("\(msg, privacy: .public)")
        FileLogSink.append(level: "W", message: "[capture] \(msg)")
    }
    static func error(_ message: @autoclosure @escaping () -> String) {
        let msg = message()
        logger.error("\(msg, privacy: .public)")
        FileLogSink.append(level: "E", message: "[capture] \(msg)")
    }
}
