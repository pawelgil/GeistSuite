import Foundation

enum LogPaths {
    static let logsDir = (NSHomeDirectory() as NSString)
        .appendingPathComponent("Library/Logs/GeistLens")
    static let shimLog = (logsDir as NSString).appendingPathComponent("shim.log")
}
