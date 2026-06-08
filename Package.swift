// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Geist",
    platforms: [.macOS(.v15)],
    products: [
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

        .binaryTarget(
            name: "CoreSimulator",
            path: "GeistCore/Frameworks/CoreSimulator.xcframework"
        ),

        .target(
            name: "GeistKit",
            dependencies: ["CoreSimulatorPrivate", "CoreSimulator"],
            path: "GeistCore/Sources/GeistKit"
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
            dependencies: ["CoreSimulatorPrivate", "GeistKit", "CoreSimulator"],
            path: "GeistCast/Sources/SimulatorScreenCapture"
        ),

        .target(
            name: "SecurityPrivate",
            path: "GeistCast/Sources/SecurityPrivate",
            publicHeadersPath: "include"
        ),

        .target(
            name: "GeistBroadcast",
            dependencies: [
                "GeistKit",
                "GeistBroadcastShimCore",
                "SimulatorScreenCapture",
                "CoreSimulatorPrivate",
                "CoreSimulator",
                "SecurityPrivate",
            ],
            path: "GeistCast/Sources/GeistBroadcast",
            plugins: ["BuildShim"]
        ),

        .testTarget(
            name: "GeistBroadcastTests",
            dependencies: ["GeistBroadcast", "GeistBroadcastShimCore"],
            path: "GeistCast/Tests/GeistBroadcastTests"
        ),

        // MARK: - GeistCast smoke test (the §0 spike from NO_SHELLOUT_RESEARCH.md;
        // kept as a runnable end-to-end smoke test against a booted simulator)

        .executableTarget(
            name: "RecodeSpike",
            dependencies: ["CoreSimulatorPrivate", "CoreSimulator", "SecurityPrivate"],
            path: "GeistCast/Spike/RecodeSpike"
        ),
    ]
)
