import Foundation

protocol AppexSpawning: Sendable {
    func spawn(stagedBinary: String,
               simulatorUDID: String,
               simctlSetPath: String?,
               environment: [String: String]) async throws
    func killStale(stagedBinary: String) async
}

struct AppexSpawner: AppexSpawning, Sendable {

    private let process: any ProcessRunner

    init(process: any ProcessRunner = LiveProcessRunner()) {
        self.process = process
    }

    func killStale(stagedBinary: String) async {
        _ = try? await process.run(ProcessInvocation(
            executable: "/usr/bin/pkill",
            arguments: ["-9", "-f", stagedBinary],
            environment: [:]
        ))
    }

    func spawn(
        stagedBinary: String,
        simulatorUDID: String,
        simctlSetPath: String?,
        environment: [String: String]
    ) async throws {
        await killStale(stagedBinary: stagedBinary)
        var arguments = ["simctl"]
        if let setPath = simctlSetPath {
            arguments.append(contentsOf: ["--set", setPath])
        }
        arguments.append(contentsOf: ["spawn", simulatorUDID, stagedBinary])

        // `simctl spawn` forwards env vars whose names start with
        // `SIMCTL_CHILD_` to the spawned process with that prefix stripped.
        let childEnv: [String: String] = environment.reduce(into: [:]) { dict, kv in
            dict["SIMCTL_CHILD_\(kv.key)"] = kv.value
        }

        let result = try await process.run(ProcessInvocation(
            executable: "/usr/bin/xcrun",
            arguments: arguments,
            environment: childEnv
        ))
        if result.exitStatus != 0 {
            let stderr = String(decoding: result.stderr, as: UTF8.self)
            Log.warn("AppexSpawner: simctl spawn exited \(result.exitStatus): \(stderr)")
        }
    }
}
