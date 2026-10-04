import Foundation
@testable import GeistCast
import Testing

struct ScreenCaptureKitSupportInstallerTests {
    @Test
    func enable_CompatibilityFramework_PreservesIncludeAcrossRepeatedEnableAndDisable() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let environment = FakeBuildEnvironment(sdkPath: fixture.sdk.path, configuration: "/Projects/Base.xcconfig")
        let sut = ScreenCaptureKitSupportInstaller(environment: environment,
            framework: DummyFrameworkInstaller(), paths: fixture.paths)

        #expect(try await sut.enable() == .compatibilityFramework)
        #expect(try await sut.enable() == .compatibilityFramework)

        #expect(await environment.configuration() == fixture.paths.configurationPath)
        let contents = try String(contentsOfFile: fixture.paths.configurationPath, encoding: .utf8)
        #expect(contents.hasPrefix("#include? \"/Projects/Base.xcconfig\"\n"))
        try await sut.disable()
        #expect(await environment.configuration() == "/Projects/Base.xcconfig")
    }

    @Test
    func enable_FrameworkInstallationFails_PreservesEnvironment() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let environment = FakeBuildEnvironment(sdkPath: fixture.sdk.path, configuration: "/Projects/Base.xcconfig")
        let sut = ScreenCaptureKitSupportInstaller(environment: environment,
            framework: StubFailingFrameworkInstaller(), paths: fixture.paths)

        await #expect(throws: InstallerFailure.expected) { try await sut.enable() }

        #expect(await environment.configuration() == "/Projects/Base.xcconfig")
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.configurationPath))
    }

    @Test
    func enable_ActivationFails_RestoresPreviousConfigurationContents() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let expected = Data("original".utf8)
        try expected.write(to: URL(fileURLWithPath: fixture.paths.configurationPath))
        let sut = ScreenCaptureKitSupportInstaller(
            environment: StubFailingBuildEnvironment(sdkPath: fixture.sdk.path),
            framework: DummyFrameworkInstaller(), paths: fixture.paths)

        await #expect(throws: InstallerFailure.expected) { try await sut.enable() }

        #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.paths.configurationPath)) == expected)
    }

    @Test
    func enable_NativeFrameworkAvailable_RemovesCompatibilityOverride() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.sdk.appending(path: "System/Library/Frameworks/ScreenCaptureKit.framework"),
            withIntermediateDirectories: true)
        let environment = FakeBuildEnvironment(sdkPath: fixture.sdk.path, configuration: fixture.paths.configurationPath)
        let sut = ScreenCaptureKitSupportInstaller(environment: environment,
            framework: StubFailingFrameworkInstaller(), paths: fixture.paths)

        #expect(try await sut.enable() == .nativeSDK)

        #expect(await environment.configuration().isEmpty)
    }

    @Test
    func disable_DifferentConfigurationActive_PreservesIt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let environment = FakeBuildEnvironment(sdkPath: fixture.sdk.path, configuration: "/Projects/Other.xcconfig")
        let sut = ScreenCaptureKitSupportInstaller(environment: environment,
            framework: DummyFrameworkInstaller(), paths: fixture.paths)

        try await sut.disable()

        #expect(await environment.configuration() == "/Projects/Other.xcconfig")
    }

    @Test
    func configuration_NoExistingConfig_AddsSimulatorOnlySearchPaths() {
        let result = ScreenCaptureKitSupportInstaller.configuration(
            existingConfiguration: "", frameworkDirectory: "/Library/Application Support/GeistCast")

        #expect(result == """
        FRAMEWORK_SEARCH_PATHS[sdk=iphonesimulator*] = $(inherited) "/Library/Application Support/GeistCast"
        LD_RUNPATH_SEARCH_PATHS[sdk=iphonesimulator*] = $(inherited) "/Library/Application Support/GeistCast"

        """)
    }

    @Test
    func install_ExistingFramework_ReplacesAndSignsWithoutLeavingStagingFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let framework = URL(fileURLWithPath: fixture.paths.frameworkPath)
        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
        try Data().write(to: framework.appending(path: "old"))
        let sut = ScreenCaptureKitFrameworkInstaller(process: LiveProcess())

        try await sut.install(at: fixture.paths)
        try await sut.install(at: fixture.paths)

        #expect(!FileManager.default.fileExists(atPath: framework.appending(path: "old").path))
        #expect(FileManager.default.fileExists(atPath: framework.appending(path: "ScreenCaptureKit").path))
        _ = try await LiveProcess().run(executable: "/usr/bin/codesign", arguments: ["--verify", "--strict", framework.path])
        let files = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
        #expect(!files.contains { $0.hasPrefix(".ScreenCaptureKit-") })
    }

    @Test
    func install_CodeSigningFails_PreservesInstalledFrameworkAndRemovesStagingFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let framework = URL(fileURLWithPath: fixture.paths.frameworkPath)
        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
        let marker = framework.appending(path: "existing")
        try Data().write(to: marker)
        let sut = ScreenCaptureKitFrameworkInstaller(process: StubSigningFailureProcess())

        await #expect(throws: InstallerFailure.expected) { try await sut.install(at: fixture.paths) }

        #expect(FileManager.default.fileExists(atPath: marker.path))
        let files = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
        #expect(!files.contains { $0.hasPrefix(".ScreenCaptureKit-") })
    }
}

private struct Fixture {
    let root: URL
    let sdk: URL
    let paths: ScreenCaptureKitSupportInstaller.Paths

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        sdk = root.appending(path: "Simulator.sdk")
        paths = .init(configurationPath: root.appending(path: "ScreenCaptureKit.xcconfig").path,
                      frameworkPath: root.appending(path: "ScreenCaptureKit.framework").path, installRoot: root.path)
        try FileManager.default.createDirectory(at: sdk, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private actor FakeBuildEnvironment: ScreenCaptureKitBuildEnvironment {
    let sdkPath: String
    private var activeConfiguration: String

    init(sdkPath: String, configuration: String) {
        self.sdkPath = sdkPath
        activeConfiguration = configuration
    }

    func simulatorSDKPath() -> String { sdkPath }
    func configuration() -> String { activeConfiguration }
    func setConfiguration(_ path: String) { activeConfiguration = path }
}

private struct DummyFrameworkInstaller: ScreenCaptureKitFrameworkInstalling {
    func install(at _: ScreenCaptureKitSupportInstaller.Paths) async throws {}
}

private enum InstallerFailure: Error { case expected }

private struct StubFailingFrameworkInstaller: ScreenCaptureKitFrameworkInstalling {
    func install(at _: ScreenCaptureKitSupportInstaller.Paths) async throws { throw InstallerFailure.expected }
}

private struct StubFailingBuildEnvironment: ScreenCaptureKitBuildEnvironment {
    let sdkPath: String
    func simulatorSDKPath() async throws -> String { sdkPath }
    func configuration() async throws -> String { "" }
    func setConfiguration(_: String) async throws { throw InstallerFailure.expected }
}

private struct StubSigningFailureProcess: ProcessRunning {
    func run(executable: String, arguments _: [String]) async throws -> Data {
        if executable == "/usr/bin/codesign" { throw InstallerFailure.expected }
        return Data()
    }
}
