import Foundation
import Geist

struct LaunchctlShimInjector: Sendable {
    private let process: any ProcessRunning

    init(process: any ProcessRunning) {
        self.process = process
    }

    func injectDylib(at path: String, intoSimulator udid: String) async throws {
        Log.notice("LaunchctlShimInjector.inject: udid=\(udid) dylib=\(path)")
        let existing = (try? await getenv(simulator: udid)) ?? ""
        let merged = Self.appending(path, to: existing)
        _ = try await process.run(
            executable: "/usr/bin/xcrun",
            arguments: [
                "simctl", "spawn", udid,
                "launchctl", "setenv",
                "DYLD_INSERT_LIBRARIES", merged,
            ]
        )
        _ = try await process.run(
            executable: "/usr/bin/xcrun",
            arguments: [
                "simctl", "spawn", udid,
                "launchctl", "setenv",
                "GEISTCAST_LOG_DIR", FileLogSink.logsDir,
            ]
        )
    }

    func uninjectDylib(at path: String, fromSimulator udid: String) async throws {
        Log.notice("LaunchctlShimInjector.uninject: udid=\(udid) dylib=\(path)")
        let existing = (try? await getenv(simulator: udid)) ?? ""
        let remaining = Self.removing(path, from: existing)
        if remaining.isEmpty {
            _ = try await process.run(
                executable: "/usr/bin/xcrun",
                arguments: [
                    "simctl", "spawn", udid,
                    "launchctl", "unsetenv",
                    "DYLD_INSERT_LIBRARIES",
                ]
            )
        } else {
            _ = try await process.run(
                executable: "/usr/bin/xcrun",
                arguments: [
                    "simctl", "spawn", udid,
                    "launchctl", "setenv",
                    "DYLD_INSERT_LIBRARIES", remaining,
                ]
            )
        }
        _ = try? await process.run(
            executable: "/usr/bin/xcrun",
            arguments: [
                "simctl", "spawn", udid,
                "launchctl", "unsetenv",
                "GEISTCAST_LOG_DIR",
            ]
        )
    }

    private func getenv(simulator udid: String) async throws -> String {
        let data = try await process.run(
            executable: "/usr/bin/xcrun",
            arguments: [
                "simctl", "spawn", udid,
                "launchctl", "getenv",
                "DYLD_INSERT_LIBRARIES",
            ]
        )
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func appending(_ path: String, to existing: String) -> String {
        let parts = existing.split(separator: ":", omittingEmptySubsequences: true).map(String.init)
        guard !parts.contains(path) else { return existing }
        return (parts + [path]).joined(separator: ":")
    }

    static func removing(_ path: String, from existing: String) -> String {
        existing.split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != path }
            .joined(separator: ":")
    }
}
