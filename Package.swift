// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Geist",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "GeistKit", targets: ["GeistKit"]),
        .library(name: "GeistCamera", targets: ["GeistCamera"]),
        .library(name: "GeistBroadcast", targets: ["GeistBroadcast"]),
    ],
    targets: [
        // MARK: - GeistCore

        .target(
            name: "CoreSimulatorPrivate",
            path: "GeistCore/Sources/CoreSimulatorPrivate",
            publicHeadersPath: "include"
        ),

        .target(
            name: "SharedShimCore",
            path: "GeistCore/Sources/SharedShimCore",
            publicHeadersPath: "include"
        ),

        .target(
            name: "GeistKit",
            dependencies: ["CoreSimulatorPrivate"],
            path: "GeistCore/Sources/GeistKit",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-F", "-Xlinker", "/Library/Developer/PrivateFrameworks",
                    "-Xlinker", "-weak_framework", "-Xlinker", "CoreSimulator",
                ]),
            ]
        ),

        .plugin(
            name: "BuildShim",
            capability: .buildTool(),
            path: "GeistCore/Plugins/BuildShim"
        ),

        .testTarget(
            name: "GeistKitTests",
            dependencies: ["GeistKit"],
            path: "GeistCore/Tests/GeistKitTests"
        ),

        // MARK: - GeistLens (camera)

        .target(
            name: "GeistCameraShimCore",
            path: "GeistLens/Sources/GeistCameraShimCore",
            publicHeadersPath: "include"
        ),

        .target(
            name: "GeistCamera",
            dependencies: ["GeistKit", "GeistCameraShimCore"],
            path: "GeistLens/Sources/GeistCamera",
            plugins: ["BuildShim"]
        ),

        .testTarget(
            name: "GeistCameraTests",
            dependencies: ["GeistCamera", "GeistCameraShimCore"],
            path: "GeistLens/Tests/GeistCameraTests",
            resources: [.process("Fixtures")]
        ),

        // MARK: - GeistCast (broadcast)

        .target(
            name: "GeistBroadcastShimCore",
            dependencies: ["SharedShimCore"],
            path: "GeistCast/Sources/GeistBroadcastShimCore",
            publicHeadersPath: "include"
        ),

        .target(
            name: "SimulatorScreenCapture",
            dependencies: ["CoreSimulatorPrivate", "GeistKit"],
            path: "GeistCast/Sources/SimulatorScreenCapture",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-F", "-Xlinker", "/Library/Developer/PrivateFrameworks",
                    "-Xlinker", "-weak_framework", "-Xlinker", "CoreSimulator",
                ]),
            ]
        ),

        .target(
            name: "GeistBroadcast",
            dependencies: ["GeistKit", "GeistBroadcastShimCore", "SimulatorScreenCapture"],
            path: "GeistCast/Sources/GeistBroadcast",
            plugins: ["BuildShim"]
        ),

        .testTarget(
            name: "GeistBroadcastTests",
            dependencies: ["GeistBroadcast", "GeistBroadcastShimCore"],
            path: "GeistCast/Tests/GeistBroadcastTests"
        ),
    ]
)
