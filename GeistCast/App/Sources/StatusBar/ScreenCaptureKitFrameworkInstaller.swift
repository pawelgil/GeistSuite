import Foundation
import GeistScreenCapture

protocol ScreenCaptureKitFrameworkInstalling: Sendable {
    func install(at paths: ScreenCaptureKitSupportInstaller.Paths) async throws
}

struct ScreenCaptureKitFrameworkInstaller: ScreenCaptureKitFrameworkInstalling {
    let process: any ProcessRunning

    func install(at paths: ScreenCaptureKitSupportInstaller.Paths) async throws {
        try FileManager.default.createDirectory(atPath: paths.installRoot, withIntermediateDirectories: true)
        let stagingRoot = (paths.installRoot as NSString)
            .appendingPathComponent(".ScreenCaptureKit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: stagingRoot, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: stagingRoot) }
        let stagedFramework = (stagingRoot as NSString)
            .appendingPathComponent("ScreenCaptureKit.framework")
        let archive = try ScreenCaptureKitFrameworkBundled.archiveURL()
        _ = try await process.run(
            executable: "/usr/bin/ditto",
            arguments: ["-x", "-k", archive.path, stagingRoot]
        )
        _ = try await process.run(
            executable: "/usr/bin/codesign",
            arguments: ["--force", "--sign", "-", stagedFramework]
        )
        if FileManager.default.fileExists(atPath: paths.frameworkPath) {
            _ = try FileManager.default.replaceItemAt(
                URL(fileURLWithPath: paths.frameworkPath),
                withItemAt: URL(fileURLWithPath: stagedFramework)
            )
        } else {
            try FileManager.default.moveItem(atPath: stagedFramework, toPath: paths.frameworkPath)
        }
    }
}
