import Foundation
import PackagePlugin

@main
struct BuildScreenCaptureKit: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        guard target.name == "GeistScreenCapture" else { return [] }
        let packageRoot = context.package.directoryURL
        let script = packageRoot.appending(path: "GeistCore/Scripts/build-screen-capture-kit.sh")
        let output = context.pluginWorkDirectoryURL
            .appending(path: "ScreenCaptureKit.framework.zip")
        return [
            .buildCommand(
                displayName: "Build ScreenCaptureKit.framework for iOS Simulator",
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: [script.path(), output.path(), packageRoot.path()],
                inputFiles: [
                    script,
                    packageRoot.appending(path: "GeistCast/Sources/ScreenCaptureKitSimulator/Overlay.swift"),
                    packageRoot.appending(path: "GeistCast/Sources/ScreenCaptureKitSimulator/FrameSocket.h"),
                    packageRoot.appending(path: "GeistCast/Sources/ScreenCaptureKitSimulator/FrameSocket.m"),
                    packageRoot.appending(path: "GeistCast/Sources/ScreenCaptureKitSimulator/Runtime.m"),
                    packageRoot.appending(path: "GeistCast/Sources/GeistScreenCaptureShimCore/include/GeistScreenCaptureWire.h"),
                    packageRoot.appending(path: "GeistCore/Sources/SharedShimCore/include/SocketIO.h"),
                    packageRoot.appending(path: "GeistCore/Sources/SharedShimCore/SocketIO.c"),
                ],
                outputFiles: [output]
            ),
        ]
    }
}
