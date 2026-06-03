import Foundation
import GeistKit

public struct BroadcastApp: Sendable, Equatable {
    public let hostBundleID: String
    public let displayName: String
    public let extensionBundleID: String
    public let appPath: String
    public let appexPath: String
}

enum ExtensionDiscoveryError: Error, Equatable {
    case appNotInstalled(bundleID: String)
    case noBroadcastExtension(hostBundleID: String)
    case ambiguousBroadcastExtensions(hostBundleID: String, candidates: [String])
    case simctlFailed(stderr: String)
}

enum ExtensionDiscovery {
    static let broadcastUploadPointID = "com.apple.broadcast-services-upload"

    // If `extensionBundleID` is nil, expects exactly one broadcast upload
    // extension in the host app's PlugIns directory.
    static func resolve(
        simulator: UUID,
        hostBundleID: String,
        extensionBundleID: String?,
        simctlSetPath: String?,
        runner: any ProcessRunner = LiveProcessRunner()
    ) async throws -> (extensionBundleID: String, appexPath: String) {
        let appPath = try await appContainerPath(
            simulator: simulator, hostBundleID: hostBundleID,
            simctlSetPath: simctlSetPath, runner: runner
        )
        let appexes = try discoverBroadcastAppexes(appPath: appPath)
        if let pinned = extensionBundleID {
            guard let match = appexes.first(where: { $0.bundleID == pinned }) else {
                throw ExtensionDiscoveryError.noBroadcastExtension(hostBundleID: hostBundleID)
            }
            return (match.bundleID, match.appexPath)
        }
        switch appexes.count {
        case 0: throw ExtensionDiscoveryError.noBroadcastExtension(hostBundleID: hostBundleID)
        case 1: return (appexes[0].bundleID, appexes[0].appexPath)
        default: throw ExtensionDiscoveryError.ambiguousBroadcastExtensions(
            hostBundleID: hostBundleID, candidates: appexes.map(\.bundleID)
        )
        }
    }

    static func broadcastCapableApps(
        simulator: UUID,
        simctlSetPath: String?,
        runner: any ProcessRunner = LiveProcessRunner()
    ) async throws -> [BroadcastApp] {
        let raw = try await simctlListApps(
            simulator: simulator, simctlSetPath: simctlSetPath, runner: runner
        )
        var apps: [BroadcastApp] = []
        for (bundleID, info) in raw {
            guard let appPath = info["Path"] as? String else { continue }
            let displayName = (info["CFBundleDisplayName"] as? String)
                ?? (info["CFBundleName"] as? String)
                ?? bundleID
            guard let appex = (try? discoverBroadcastAppexes(appPath: appPath))?.first
            else { continue }
            apps.append(BroadcastApp(
                hostBundleID: bundleID,
                displayName: displayName,
                extensionBundleID: appex.bundleID,
                appPath: appPath,
                appexPath: appex.appexPath
            ))
        }
        return apps.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    // MARK: - Internals

    private static func appContainerPath(
        simulator: UUID,
        hostBundleID: String,
        simctlSetPath: String?,
        runner: any ProcessRunner
    ) async throws -> String {
        var args: [String] = []
        if let simctlSetPath { args += ["--set", simctlSetPath] }
        args += ["get_app_container", simulator.uuidString, hostBundleID, "app"]
        let result = try await runner.run(ProcessInvocation(
            executable: "/usr/bin/xcrun",
            arguments: ["simctl"] + args,
            environment: [:]
        ))
        let stdout = String(data: result.stdout, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
        if result.exitStatus != 0 || stdout.isEmpty {
            if stderr.contains("No such file or directory") || stderr.contains("not found") {
                throw ExtensionDiscoveryError.appNotInstalled(bundleID: hostBundleID)
            }
            throw ExtensionDiscoveryError.simctlFailed(stderr: stderr)
        }
        return stdout
    }

    private static func simctlListApps(
        simulator: UUID,
        simctlSetPath: String?,
        runner: any ProcessRunner
    ) async throws -> [String: [String: Any]] {
        var args: [String] = []
        if let simctlSetPath { args += ["--set", simctlSetPath] }
        args += ["listapps", simulator.uuidString]
        let result = try await runner.run(ProcessInvocation(
            executable: "/usr/bin/xcrun",
            arguments: ["simctl"] + args,
            environment: [:]
        ))
        if result.exitStatus != 0 {
            throw ExtensionDiscoveryError.simctlFailed(
                stderr: String(data: result.stderr, encoding: .utf8) ?? ""
            )
        }
        // simctl listapps emits an OpenStep plist on stdout.
        let parsed = try? PropertyListSerialization.propertyList(
            from: result.stdout, options: [], format: nil
        )
        return (parsed as? [String: [String: Any]]) ?? [:]
    }

    private struct BroadcastAppex {
        let bundleID: String
        let appexPath: String
    }

    private static func discoverBroadcastAppexes(appPath: String) throws -> [BroadcastAppex] {
        let pluginsURL = URL(fileURLWithPath: appPath).appendingPathComponent("PlugIns")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: pluginsURL.path, isDirectory: &isDir),
              isDir.boolValue
        else { return [] }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: pluginsURL.path)) ?? []
        var result: [BroadcastAppex] = []
        for entry in entries where entry.hasSuffix(".appex") {
            let appexPath = pluginsURL.appendingPathComponent(entry).path
            guard let info = readInfoPlist(appexPath: appexPath),
                  let bundleID = info["CFBundleIdentifier"] as? String,
                  let extDict = info["NSExtension"] as? [String: Any],
                  let pointID = extDict["NSExtensionPointIdentifier"] as? String,
                  pointID == broadcastUploadPointID
            else { continue }
            result.append(BroadcastAppex(bundleID: bundleID, appexPath: appexPath))
        }
        return result
    }

    private static func readInfoPlist(appexPath: String) -> [String: Any]? {
        let infoURL = URL(fileURLWithPath: appexPath).appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoURL) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil))
            as? [String: Any]
    }
}
