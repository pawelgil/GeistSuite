import CryptoKit
import Foundation
import Geist

enum DylibInstaller {

    static let installRoot = (NSHomeDirectory() as NSString)
        .appendingPathComponent("Library/Application Support/GeistLens")

    static let cameraShimInstallPath = (installRoot as NSString)
        .appendingPathComponent("GeistCamShim.dylib")

    static let broadcastAppShimInstallPath = (installRoot as NSString)
        .appendingPathComponent("GeistBroadcastAppShim.dylib")

    struct InstalledShims {
        let cameraShimPath: String
        let broadcastAppShimPath: String?
    }

    @discardableResult
    static func installIfNeeded() throws -> InstalledShims {
        try FileManager.default.createDirectory(atPath: installRoot,
                                                withIntermediateDirectories: true)
        let cameraPath = try install(bundled: GeistShimBundled.cameraShimDylibPath,
                                     to: cameraShimInstallPath)
        let broadcastBundled = try? GeistShimBundled.broadcastAppShimDylibPath()
        let broadcastPath = try broadcastBundled.flatMap { bundled in
            try install(bundled: bundled, to: broadcastAppShimInstallPath)
        }
        return InstalledShims(cameraShimPath: cameraPath,
                              broadcastAppShimPath: broadcastPath)
    }

    private static func install(bundled: String, to installPath: String) throws -> String {
        let bundledHash = try sha256(of: bundled)
        if let installedHash = try? sha256(of: installPath), installedHash == bundledHash {
            return installPath
        }
        try? FileManager.default.removeItem(atPath: installPath)
        try FileManager.default.copyItem(atPath: bundled, toPath: installPath)
        Log.notice("DylibInstaller: installed \(bundledHash.prefix(12))… → \(installPath)")
        return installPath
    }

    private static func sha256(of path: String) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
