import Foundation
@testable import GeistCast
import Testing

struct ScreenCaptureKitSupportInstallerTests {
    @Test
    func enable_CompatibilityFramework_StagesAndActivatesFramework() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let paths = makePaths(root: temporary.path)
        let sdk = temporary.appending(path: "Simulator.sdk")
        try FileManager.default.createDirectory(at: sdk, withIntermediateDirectories: true)
        let process = ScreenCaptureKitInstallerProcess(
            sdkPath: sdk.path,
            xcodeConfiguration: "",
            extractsFramework: true
        )
        let sut = ScreenCaptureKitSupportInstaller(process: process, paths: paths)

        let result = try await sut.enable()

        #expect(result == .compatibilityFramework)
        #expect(FileManager.default.fileExists(atPath: paths.frameworkPath))
        #expect(FileManager.default.fileExists(atPath: paths.configurationPath))
        #expect(await process.invocations.last == .init(
            executable: "/bin/launchctl",
            arguments: ["setenv", "XCODE_XCCONFIG_FILE", paths.configurationPath]
        ))
    }

    @Test
    func enable_CodeSigningFails_PreservesInstalledFramework() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let paths = makePaths(root: temporary.path)
        let existing = URL(fileURLWithPath: paths.frameworkPath)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        let marker = existing.appending(path: "existing")
        try Data().write(to: marker)
        let sdk = temporary.appending(path: "Simulator.sdk")
        try FileManager.default.createDirectory(at: sdk, withIntermediateDirectories: true)
        let process = ScreenCaptureKitInstallerProcess(
            sdkPath: sdk.path,
            xcodeConfiguration: "",
            extractsFramework: true,
            failsCodeSigning: true
        )
        let sut = ScreenCaptureKitSupportInstaller(process: process, paths: paths)

        await #expect(throws: ScreenCaptureKitInstallerProcess.Error.codeSigning) {
            try await sut.enable()
        }

        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test
    func enable_ExistingFramework_ReplacesItAfterStagedFrameworkIsReady() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let paths = makePaths(root: temporary.path)
        let existing = URL(fileURLWithPath: paths.frameworkPath)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try Data().write(to: existing.appending(path: "old"))
        let sdk = temporary.appending(path: "Simulator.sdk")
        try FileManager.default.createDirectory(at: sdk, withIntermediateDirectories: true)
        let process = ScreenCaptureKitInstallerProcess(
            sdkPath: sdk.path,
            xcodeConfiguration: "",
            extractsFramework: true
        )
        let sut = ScreenCaptureKitSupportInstaller(process: process, paths: paths)

        _ = try await sut.enable()

        #expect(!FileManager.default.fileExists(atPath: existing.appending(path: "old").path))
        #expect(FileManager.default.fileExists(atPath: existing.appending(path: "new").path))
        #expect(await process.invocations.last == .init(
            executable: "/bin/launchctl",
            arguments: ["setenv", "XCODE_XCCONFIG_FILE", paths.configurationPath]
        ))
    }

    @Test
    func enable_NativeFrameworkAvailable_DisablesCompatibilityOverride() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let paths = makePaths(root: temporary.path)
        let sdk = temporary.appending(path: "Simulator.sdk")
        let nativeFramework = sdk.appending(
            path: "System/Library/Frameworks/ScreenCaptureKit.framework"
        )
        try FileManager.default.createDirectory(
            at: nativeFramework,
            withIntermediateDirectories: true
        )
        let process = ScreenCaptureKitInstallerProcess(
            sdkPath: sdk.path,
            xcodeConfiguration: paths.configurationPath
        )
        let sut = ScreenCaptureKitSupportInstaller(process: process, paths: paths)

        let result = try await sut.enable()

        #expect(result == .nativeSDK)
        #expect(await process.invocations.last == .init(
            executable: "/bin/launchctl",
            arguments: ["unsetenv", "XCODE_XCCONFIG_FILE"]
        ))
    }

    @Test
    func enable_RepeatedInstallations_UseUniqueStagingDirectories() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let paths = makePaths(root: temporary.path)
        let sdk = temporary.appending(path: "Simulator.sdk")
        try FileManager.default.createDirectory(at: sdk, withIntermediateDirectories: true)
        let process = ScreenCaptureKitInstallerProcess(
            sdkPath: sdk.path,
            xcodeConfiguration: "",
            extractsFramework: true
        )
        let sut = ScreenCaptureKitSupportInstaller(process: process, paths: paths)

        _ = try await sut.enable()
        _ = try await sut.enable()

        let destinations = await process.invocations.compactMap { invocation in
            invocation.executable == "/usr/bin/ditto" ? invocation.arguments.last : nil
        }
        #expect(destinations.count == 2)
        #expect(Set(destinations).count == 2)
    }

    @Test
    func configuration_NoExistingConfig_AddsSimulatorOnlyFrameworkSearchPath() {
        let result = ScreenCaptureKitSupportInstaller.configuration(
            existingConfiguration: "",
            frameworkDirectory: "/Library/Application Support/GeistCast"
        )

        #expect(result == """
        FRAMEWORK_SEARCH_PATHS[sdk=iphonesimulator*] = $(inherited) \"/Library/Application Support/GeistCast\"
        LD_RUNPATH_SEARCH_PATHS[sdk=iphonesimulator*] = $(inherited) \"/Library/Application Support/GeistCast\"

        """)
    }

    @Test
    func configuration_ExistingConfig_IncludesItBeforeCompatibilitySetting() {
        let result = ScreenCaptureKitSupportInstaller.configuration(
            existingConfiguration: "/Projects/Base Config.xcconfig",
            frameworkDirectory: "/Frameworks"
        )

        #expect(result == """
        #include? \"/Projects/Base Config.xcconfig\"
        FRAMEWORK_SEARCH_PATHS[sdk=iphonesimulator*] = $(inherited) \"/Frameworks\"
        LD_RUNPATH_SEARCH_PATHS[sdk=iphonesimulator*] = $(inherited) \"/Frameworks\"

        """)
    }

    @Test
    func inheritedConfiguration_OwnConfigActive_PreservesInstalledInclude() {
        let result = ScreenCaptureKitSupportInstaller.inheritedConfiguration(
            active: ScreenCaptureKitSupportInstaller.configurationPath,
            installed: "/Projects/Base.xcconfig"
        )

        #expect(result == "/Projects/Base.xcconfig")
    }

    @Test
    func disable_OwnConfigurationActive_UnsetsXcodeOverride() async throws {
        let process = ScreenCaptureKitInstallerProcess(
            xcodeConfiguration: ScreenCaptureKitSupportInstaller.configurationPath
        )
        let sut = ScreenCaptureKitSupportInstaller(
            process: process,
            installedConfiguration: { nil }
        )

        try await sut.disable()

        #expect(await process.invocations == [
            .init(
                executable: "/bin/launchctl",
                arguments: ["getenv", "XCODE_XCCONFIG_FILE"]
            ),
            .init(
                executable: "/bin/launchctl",
                arguments: ["unsetenv", "XCODE_XCCONFIG_FILE"]
            ),
        ])
    }

    @Test
    func disable_OwnConfigurationWithIncludedConfig_RestoresPreviousOverride() async throws {
        let process = ScreenCaptureKitInstallerProcess(
            xcodeConfiguration: ScreenCaptureKitSupportInstaller.configurationPath
        )
        let sut = ScreenCaptureKitSupportInstaller(
            process: process,
            installedConfiguration: { "/Projects/Other.xcconfig" }
        )

        try await sut.disable()

        #expect(await process.invocations.last == .init(
            executable: "/bin/launchctl",
            arguments: ["setenv", "XCODE_XCCONFIG_FILE", "/Projects/Other.xcconfig"]
        ))
    }

    @Test
    func disable_DifferentConfigurationActive_PreservesIt() async throws {
        let process = ScreenCaptureKitInstallerProcess(
            xcodeConfiguration: "/Projects/Other.xcconfig"
        )
        let sut = ScreenCaptureKitSupportInstaller(process: process)

        try await sut.disable()

        #expect(await process.invocations.count == 1)
    }

    private func makePaths(root: String) -> ScreenCaptureKitSupportInstaller.Paths {
        .init(
            configurationPath: (root as NSString).appendingPathComponent("ScreenCaptureKit.xcconfig"),
            frameworkPath: (root as NSString).appendingPathComponent("ScreenCaptureKit.framework"),
            installRoot: root
        )
    }
}

private struct ScreenCaptureKitInstallerInvocation: Equatable {
    let executable: String
    let arguments: [String]
}

private actor ScreenCaptureKitInstallerProcess: ProcessRunning {
    // MARK: Nested Types

    enum Error: Swift.Error {
        case codeSigning
    }

    // MARK: Properties

    private(set) var invocations: [ScreenCaptureKitInstallerInvocation] = []

    private let extractsFramework: Bool
    private let failsCodeSigning: Bool
    private let sdkPath: String
    private let xcodeConfiguration: String

    // MARK: Lifecycle

    init(
        sdkPath: String = "",
        xcodeConfiguration: String,
        extractsFramework: Bool = false,
        failsCodeSigning: Bool = false
    ) {
        self.sdkPath = sdkPath
        self.xcodeConfiguration = xcodeConfiguration
        self.extractsFramework = extractsFramework
        self.failsCodeSigning = failsCodeSigning
    }

    // MARK: Functions

    func run(executable: String, arguments: [String]) async throws -> Data {
        invocations.append(.init(executable: executable, arguments: arguments))
        if arguments == ["--sdk", "iphonesimulator", "--show-sdk-path"] {
            return Data(sdkPath.utf8)
        }
        if arguments == ["getenv", "XCODE_XCCONFIG_FILE"] {
            return Data(xcodeConfiguration.utf8)
        }
        if executable == "/usr/bin/ditto", extractsFramework, let destination = arguments.last {
            let framework = (destination as NSString)
                .appendingPathComponent("ScreenCaptureKit.framework")
            try FileManager.default.createDirectory(atPath: framework, withIntermediateDirectories: true)
            try Data().write(to: URL(fileURLWithPath: framework).appending(path: "new"))
        }
        if executable == "/usr/bin/codesign", failsCodeSigning {
            throw Error.codeSigning
        }
        return Data()
    }
}
