import CryptoKit
import Foundation
import GeistBroadcast

enum DylibInstaller {

    static let installRoot = (NSHomeDirectory() as NSString)
        .appendingPathComponent("Library/Application Support/GeistCast")
    static let installPath = (installRoot as NSString)
        .appendingPathComponent("GeistBroadcastAppShim.dylib")

    @discardableResult
    static func installIfNeeded() throws -> String {
        let bundled = try GeistBroadcastShimBundled.appShimDylibPath()
        try FileManager.default.createDirectory(
            atPath: installRoot,
            withIntermediateDirectories: true
        )
        let bundledHash = try sha256(of: bundled)
        if let installedHash = try? sha256(of: installPath), installedHash == bundledHash {
            return installPath
        }
        try? FileManager.default.removeItem(atPath: installPath)
        try FileManager.default.copyItem(atPath: bundled, toPath: installPath)
        return installPath
    }

    private static func sha256(of path: String) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
