import Foundation
import PackagePlugin

@main
struct BuildShim: BuildToolPlugin {
    private static let simulatorTarget = "arm64-apple-ios18.0-simulator"
    private static let trackedExtensions: Set<String> = ["m", "h", "c"]

    func createBuildCommands(context: PluginContext, target _: Target) throws -> [Command] {
        let packageRoot = context.package.directoryURL
        let sourcesRoot = packageRoot.appending(path: "Sources")
        let outputDir = context.pluginWorkDirectoryURL

        let shimCoreDir = sourcesRoot.appending(path: "GeistShimCore")
        let shimCoreCompileSources = try Self.gatherSources(under: shimCoreDir, extensions: ["m", "c"])
        let shimCoreInputs = try Self.gatherSources(under: shimCoreDir, extensions: Self.trackedExtensions)

        return try [
            Self.makeBuildCommand(
                name: "GeistBroadcastAppShim",
                modeDir: sourcesRoot.appending(path: "GeistAppShim"),
                outputDir: outputDir,
                shimCoreDir: shimCoreDir,
                shimCoreCompileSources: shimCoreCompileSources,
                shimCoreInputs: shimCoreInputs
            ),
            Self.makeBuildCommand(
                name: "GeistBroadcastExtensionShim",
                modeDir: sourcesRoot.appending(path: "GeistBroadcastExtensionShim"),
                outputDir: outputDir,
                shimCoreDir: shimCoreDir,
                shimCoreCompileSources: shimCoreCompileSources,
                shimCoreInputs: shimCoreInputs
            ),
            Self.makeBuildCommand(
                name: "GeistCamShim",
                modeDir: sourcesRoot.appending(path: "GeistCamShim"),
                outputDir: outputDir,
                shimCoreDir: shimCoreDir,
                shimCoreCompileSources: shimCoreCompileSources,
                shimCoreInputs: shimCoreInputs
            ),
        ]
    }

    private static func makeBuildCommand(
        name: String,
        modeDir: URL,
        outputDir: URL,
        shimCoreDir: URL,
        shimCoreCompileSources: [URL],
        shimCoreInputs: [URL]
    ) throws -> Command {
        let modeCompileSources = try gatherSources(under: modeDir, extensions: ["m"])
        let modeInputs = try gatherSources(under: modeDir, extensions: trackedExtensions)
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
            "-I", shimCoreDir.path(),
            "-I", shimCoreDir.appending(path: "include").path(),
            "-I", modeDir.path(),
            "-install_name", dylib.path(),
            "-o", dylib.path(),
        ]
        args.append(contentsOf: (shimCoreCompileSources + modeCompileSources).map { $0.path() })

        return .buildCommand(
            displayName: "Compile \(name).dylib for iOS Simulator",
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: args,
            inputFiles: shimCoreInputs + modeInputs,
            outputFiles: [dylib]
        )
    }

    private static func gatherSources(under directory: URL, extensions: Set<String>) throws -> [URL] {
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
