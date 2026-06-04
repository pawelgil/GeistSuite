import Foundation
import PackagePlugin

@main
struct BuildShim: BuildToolPlugin {
    private static let simulatorTarget = "arm64-apple-ios18.0-simulator"
    private static let trackedExtensions: Set<String> = ["m", "h", "c"]

    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        let packageRoot = context.package.directoryURL
        let outputDir = context.pluginWorkDirectoryURL

        switch target.name {
        case "GeistCamera":
            let cameraShimCoreDir = packageRoot.appending(path: "GeistLens/Sources/GeistCameraShimCore")
            let cameraShimDir = packageRoot.appending(path: "GeistLens/Sources/GeistCamShim")
            let cameraCompile = try Self.gather(under: cameraShimCoreDir, extensions: ["m", "c"])
            let cameraInputs = try Self.gather(under: cameraShimCoreDir, extensions: Self.trackedExtensions)
            return [
                try Self.buildCommand(
                    name: "GeistCamShim",
                    modeDir: cameraShimDir,
                    outputDir: outputDir,
                    headerSearchDirs: [cameraShimCoreDir],
                    coreCompile: cameraCompile,
                    coreInputs: cameraInputs
                ),
            ]

        case "GeistBroadcast":
            let sharedShimDir = packageRoot.appending(path: "GeistCore/Sources/SharedShimCore")
            let broadcastShimCoreDir = packageRoot.appending(path: "GeistCast/Sources/GeistBroadcastShimCore")
            let broadcastAppShimDir = packageRoot.appending(path: "GeistCast/Sources/GeistBroadcastAppShim")
            let broadcastExtShimDir = packageRoot.appending(path: "GeistCast/Sources/GeistBroadcastExtensionShim")
            let sharedCompile = try Self.gather(under: sharedShimDir, extensions: ["m", "c"])
            let sharedInputs = try Self.gather(under: sharedShimDir, extensions: Self.trackedExtensions)
            let broadcastCompile = try Self.gather(under: broadcastShimCoreDir, extensions: ["m", "c"])
            let broadcastInputs = try Self.gather(under: broadcastShimCoreDir, extensions: Self.trackedExtensions)
            return [
                try Self.buildCommand(
                    name: "GeistBroadcastAppShim",
                    modeDir: broadcastAppShimDir,
                    outputDir: outputDir,
                    headerSearchDirs: [sharedShimDir, broadcastShimCoreDir],
                    coreCompile: sharedCompile + broadcastCompile,
                    coreInputs: sharedInputs + broadcastInputs
                ),
                try Self.buildCommand(
                    name: "GeistBroadcastExtensionShim",
                    modeDir: broadcastExtShimDir,
                    outputDir: outputDir,
                    headerSearchDirs: [sharedShimDir, broadcastShimCoreDir],
                    coreCompile: sharedCompile + broadcastCompile,
                    coreInputs: sharedInputs + broadcastInputs
                ),
            ]

        default:
            return []
        }
    }

    private static func buildCommand(name: String,
                                      modeDir: URL,
                                      outputDir: URL,
                                      headerSearchDirs: [URL],
                                      coreCompile: [URL],
                                      coreInputs: [URL]) throws -> Command {
        let modeCompile = try gather(under: modeDir, extensions: ["m"])
        let modeInputs = try gather(under: modeDir, extensions: trackedExtensions)
        let dylib = outputDir.appending(path: "\(name).dylib")

        var args: [String] = [
            "-sdk", "iphonesimulator", "clang", "-dynamiclib",
            "-arch", "arm64",
            "-target", simulatorTarget,
            "-framework", "Foundation",
            "-framework", "UIKit",
            "-framework", "CoreFoundation",
            "-framework", "CoreMedia",
            "-framework", "CoreVideo",
            "-framework", "AVFoundation",
            "-Wl,-undefined,dynamic_lookup",
            "-fobjc-arc",
            "-O0", "-g",
        ]
        for dir in headerSearchDirs {
            args.append(contentsOf: ["-I", dir.path()])
            args.append(contentsOf: ["-I", dir.appending(path: "include").path()])
        }
        args.append(contentsOf: ["-I", modeDir.path()])
        args.append(contentsOf: ["-install_name", dylib.path()])
        args.append(contentsOf: ["-o", dylib.path()])
        args.append(contentsOf: (coreCompile + modeCompile).map { $0.path() })

        return .buildCommand(
            displayName: "Compile \(name).dylib for iOS Simulator",
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: args,
            inputFiles: coreInputs + modeInputs,
            outputFiles: [dylib]
        )
    }

    private static func gather(under directory: URL, extensions: Set<String>) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator {
            guard extensions.contains(url.pathExtension) else { continue }
            let isRegular = (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile ?? false
            if isRegular { result.append(url) }
        }
        return result
    }
}
