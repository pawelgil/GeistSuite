// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Geist",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Geist", targets: ["Geist"]),
        .library(name: "SimulatorScreenCapture", targets: ["SimulatorScreenCapture"]),
        .executable(name: "e2e-driver", targets: ["E2EDriver"]),
    ],
    targets: [
        .target(
            name: "Geist",
            dependencies: ["GeistShimCore", "SimulatorScreenCapture"],
            path: "Sources/Geist",
            plugins: ["BuildShim"]
        ),
        .executableTarget(
            name: "E2EDriver",
            dependencies: ["Geist"],
            path: "Sources/E2EDriver"
        ),
        .target(
            name: "GeistShimCore",
            path: "Sources/GeistShimCore",
            publicHeadersPath: "include"
        ),
        .target(
            name: "CoreSimulatorPrivate",
            path: "Sources/CoreSimulatorPrivate",
            publicHeadersPath: "include"
        ),
        .target(
            name: "SimulatorScreenCapture",
            dependencies: ["CoreSimulatorPrivate"],
            path: "Sources/SimulatorScreenCapture",
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
            path: "Plugins/BuildShim"
        ),
        .testTarget(
            name: "GeistTests",
            dependencies: ["Geist", "GeistShimCore"],
            path: "Tests/GeistTests"
        ),
    ]
)
