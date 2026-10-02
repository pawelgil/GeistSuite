import Foundation
import GeistScreenCapture

struct ScreenCaptureKitSupportInstaller {
    // MARK: Nested Types

    enum Result: Equatable {
        case compatibilityFramework
        case nativeSDK
    }

    struct Paths {
        // MARK: Static Properties

        static let live: Self = {
            let root = (NSHomeDirectory() as NSString)
                .appendingPathComponent("Library/Application Support/GeistCast")
            return Self(
                configurationPath: (root as NSString)
                    .appendingPathComponent("ScreenCaptureKit.xcconfig"),
                frameworkPath: (root as NSString)
                    .appendingPathComponent("ScreenCaptureKit.framework"),
                installRoot: root
            )
        }()

        // MARK: Properties

        let configurationPath: String
        let frameworkPath: String
        let installRoot: String
    }

    // MARK: Static Properties

    static let installRoot = Paths.live.installRoot
    static let frameworkPath = Paths.live.frameworkPath
    static let configurationPath = Paths.live.configurationPath

    // MARK: Properties

    private let process: any ProcessRunning
    private let fileManager: SendableFileManager
    private let installedConfiguration: @Sendable () -> String?
    private let paths: Paths

    // MARK: Lifecycle

    init(
        process: any ProcessRunning,
        fileManager: FileManager = .default,
        paths: Paths = .live,
        installedConfiguration: (@Sendable () -> String?)? = nil
    ) {
        self.process = process
        self.fileManager = SendableFileManager(fileManager)
        self.paths = paths
        self.installedConfiguration = installedConfiguration
            ?? { Self.installedConfiguration(at: paths.configurationPath) }
    }

    // MARK: Static Functions

    static func configuration(
        existingConfiguration: String,
        frameworkDirectory: String,
        installedConfigurationPath: String = configurationPath
    ) -> String {
        var lines: [String] = []
        let existing = existingConfiguration.trimmingCharacters(in: .whitespacesAndNewlines)
        if !existing.isEmpty, existing != installedConfigurationPath {
            lines.append("#include? \"\(escaped(existing))\"")
        }
        lines.append(
            "FRAMEWORK_SEARCH_PATHS[sdk=iphonesimulator*] = $(inherited) \"\(escaped(frameworkDirectory))\""
        )
        lines.append(
            "LD_RUNPATH_SEARCH_PATHS[sdk=iphonesimulator*] = $(inherited) \"\(escaped(frameworkDirectory))\""
        )
        return lines.joined(separator: "\n") + "\n"
    }

    static func inheritedConfiguration(
        active: String,
        installed: String?,
        installedConfigurationPath: String = configurationPath
    ) -> String {
        active == installedConfigurationPath ? installed ?? "" : active
    }

    private static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func installedConfiguration(at path: String) -> String? {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8),
              let line = contents.split(separator: "\n").first,
              line.hasPrefix("#include? \""), line.hasSuffix("\"")
        else { return nil }
        return String(line.dropFirst(11).dropLast())
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    // MARK: Functions

    func enable() async throws -> Result {
        let sdkPath = try await simulatorSDKPath()
        let nativeFramework = (sdkPath as NSString)
            .appendingPathComponent("System/Library/Frameworks/ScreenCaptureKit.framework")
        guard !fileManager.value.fileExists(atPath: nativeFramework) else {
            try await disable()
            return .nativeSDK
        }

        try fileManager.value.createDirectory(
            atPath: paths.installRoot,
            withIntermediateDirectories: true
        )
        let stagingRoot = (paths.installRoot as NSString)
            .appendingPathComponent(".ScreenCaptureKit-\(UUID().uuidString)")
        try fileManager.value.createDirectory(atPath: stagingRoot, withIntermediateDirectories: false)
        defer { try? fileManager.value.removeItem(atPath: stagingRoot) }
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
        if fileManager.value.fileExists(atPath: paths.frameworkPath) {
            _ = try fileManager.value.replaceItemAt(
                URL(fileURLWithPath: paths.frameworkPath),
                withItemAt: URL(fileURLWithPath: stagedFramework)
            )
        } else {
            try fileManager.value.moveItem(atPath: stagedFramework, toPath: paths.frameworkPath)
        }

        let existing = try await xcodeConfigurationEnvironment()
        let contents = Self.configuration(
            existingConfiguration: Self.inheritedConfiguration(
                active: existing,
                installed: installedConfiguration(),
                installedConfigurationPath: paths.configurationPath
            ),
            frameworkDirectory: paths.installRoot,
            installedConfigurationPath: paths.configurationPath
        )
        try Data(contents.utf8).write(
            to: URL(fileURLWithPath: paths.configurationPath),
            options: .atomic
        )
        _ = try await process.run(
            executable: "/bin/launchctl",
            arguments: ["setenv", "XCODE_XCCONFIG_FILE", paths.configurationPath]
        )
        return .compatibilityFramework
    }

    func disable() async throws {
        let existing = try await xcodeConfigurationEnvironment()
        guard existing == paths.configurationPath else { return }
        let previous = installedConfiguration()
        let arguments = if let previous, !previous.isEmpty {
            ["setenv", "XCODE_XCCONFIG_FILE", previous]
        } else {
            ["unsetenv", "XCODE_XCCONFIG_FILE"]
        }
        _ = try await process.run(executable: "/bin/launchctl", arguments: arguments)
    }

    private func simulatorSDKPath() async throws -> String {
        let data = try await process.run(
            executable: "/usr/bin/xcrun",
            arguments: ["--sdk", "iphonesimulator", "--show-sdk-path"]
        )
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func xcodeConfigurationEnvironment() async throws -> String {
        let data = try await process.run(
            executable: "/bin/launchctl",
            arguments: ["getenv", "XCODE_XCCONFIG_FILE"]
        )
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Foundation documents FileManager as safe for concurrent use from multiple threads.
private struct SendableFileManager: @unchecked Sendable {
    // MARK: Properties

    let value: FileManager

    // MARK: Lifecycle

    init(_ value: FileManager) {
        self.value = value
    }
}
