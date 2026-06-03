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
        .target(
            name: "CoreSimulatorPrivate",
            path: "Sources/CoreSimulatorPrivate",
            publicHeadersPath: "include"
        ),

        .target(
            name: "SharedShimCore",
            path: "Sources/SharedShimCore",
            publicHeadersPath: "include"
        ),

        .target(
            name: "GeistCameraShimCore",
            path: "Sources/GeistCameraShimCore",
            publicHeadersPath: "include"
        ),

        .target(
            name: "GeistBroadcastShimCore",
            dependencies: ["SharedShimCore"],
            path: "Sources/GeistBroadcastShimCore",
            publicHeadersPath: "include"
        ),

        .target(
            name: "GeistKit",
            dependencies: ["CoreSimulatorPrivate"],
            path: "Sources/GeistKit",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-F", "-Xlinker", "/Library/Developer/PrivateFrameworks",
                    "-Xlinker", "-weak_framework", "-Xlinker", "CoreSimulator",
                ]),
            ]
        ),

        .target(
            name: "SimulatorScreenCapture",
            dependencies: ["CoreSimulatorPrivate", "GeistKit"],
            path: "Sources/SimulatorScreenCapture",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-F", "-Xlinker", "/Library/Developer/PrivateFrameworks",
                    "-Xlinker", "-weak_framework", "-Xlinker", "CoreSimulator",
                ]),
            ]
        ),

        .target(
            name: "GeistCamera",
            dependencies: ["GeistKit", "GeistCameraShimCore"],
            path: "Sources/GeistCamera",
            plugins: ["BuildShim"]
        ),

        .target(
            name: "GeistBroadcast",
            dependencies: ["GeistKit", "GeistBroadcastShimCore", "SimulatorScreenCapture"],
            path: "Sources/GeistBroadcast",
            plugins: ["BuildShim"]
        ),

        .plugin(
            name: "BuildShim",
            capability: .buildTool(),
            path: "Plugins/BuildShim"
        ),

        .testTarget(
            name: "GeistKitTests",
            dependencies: ["GeistKit"],
            path: "Tests/GeistKitTests"
        ),

        .testTarget(
            name: "GeistCameraTests",
            dependencies: ["GeistCamera", "GeistCameraShimCore"],
            path: "Tests/GeistCameraTests",
            resources: [.process("Fixtures")]
        ),

        .testTarget(
            name: "GeistBroadcastTests",
            dependencies: ["GeistBroadcast", "GeistBroadcastShimCore"],
            path: "Tests/GeistBroadcastTests"
        ),
    ]
)
