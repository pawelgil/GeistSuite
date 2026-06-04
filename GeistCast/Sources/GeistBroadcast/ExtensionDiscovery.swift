import CoreSimulatorPrivate
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
    case installedAppsFailed(String)
}

enum ExtensionDiscovery {
    static let broadcastUploadPointID = "com.apple.broadcast-services-upload"

    /// If `extensionBundleID` is nil, expects exactly one broadcast upload
    /// extension in the host app's PlugIns directory.
    static func resolve(
        simulator: UUID,
        hostBundleID: String,
        extensionBundleID: String?,
        simctlSetPath: String?,
        deviceResolver: SimDeviceResolver = SimDeviceResolver()
    ) async throws -> (extensionBundleID: String, appexPath: String) {
        let installedApps = try installedApps(simulator: simulator,
                                              simctlSetPath: simctlSetPath,
                                              deviceResolver: deviceResolver)
        guard let entry = installedApps[hostBundleID],
              let appPath = entry["Path"] as? String else {
            throw ExtensionDiscoveryError.appNotInstalled(bundleID: hostBundleID)
        }
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
        deviceResolver: SimDeviceResolver = SimDeviceResolver()
    ) async throws -> [BroadcastApp] {
        let raw = try installedApps(simulator: simulator,
                                    simctlSetPath: simctlSetPath,
                                    deviceResolver: deviceResolver)
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

    private static func installedApps(
        simulator: UUID,
        simctlSetPath: String?,
        deviceResolver: SimDeviceResolver
    ) throws -> [String: [String: Any]] {
        let device = try deviceResolver.resolve(udid: simulator, simctlSetPath: simctlSetPath)
        let raw: Any
        do {
            raw = try device.installedApps()
        } catch {
            throw ExtensionDiscoveryError.installedAppsFailed(String(describing: error))
        }
        guard let dict = raw as? [String: [String: Any]] else {
            throw ExtensionDiscoveryError.installedAppsFailed(
                "installedAppsWithError returned \(type(of: raw))"
            )
        }
        return dict
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
