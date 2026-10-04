import Foundation
import GeistScreenCapture

struct ScreenCaptureKitSupportInstaller {
    enum Result: Equatable {
        case compatibilityFramework
        case nativeSDK
    }

    struct Paths {
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

            let configurationPath: String
        let frameworkPath: String
        let installRoot: String
    }

    static let installRoot = Paths.live.installRoot
    static let frameworkPath = Paths.live.frameworkPath
    static let configurationPath = Paths.live.configurationPath

    private let environment: any ScreenCaptureKitBuildEnvironment
    private let framework: any ScreenCaptureKitFrameworkInstalling
    private let paths: Paths

    init(process: any ProcessRunning, paths: Paths = .live) {
        self.init(environment: LiveScreenCaptureKitBuildEnvironment(process: process),
                  framework: ScreenCaptureKitFrameworkInstaller(process: process), paths: paths)
    }

    init(environment: any ScreenCaptureKitBuildEnvironment,
         framework: any ScreenCaptureKitFrameworkInstalling, paths: Paths) {
        self.environment = environment
        self.framework = framework
        self.paths = paths
    }

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

    func enable() async throws -> Result {
        let sdkPath = try await environment.simulatorSDKPath()
        let nativeFramework = (sdkPath as NSString)
            .appendingPathComponent("System/Library/Frameworks/ScreenCaptureKit.framework")
        guard !FileManager.default.fileExists(atPath: nativeFramework) else {
            try await disable()
            return .nativeSDK
        }
        try await framework.install(at: paths)
        try Task.checkCancellation()
        let existing = try await environment.configuration()
        let url = URL(fileURLWithPath: paths.configurationPath)
        let previousContents = try? Data(contentsOf: url)
        let contents = Self.configuration(
            existingConfiguration: Self.inheritedConfiguration(
                active: existing,
                installed: Self.installedConfiguration(at: paths.configurationPath),
                installedConfigurationPath: paths.configurationPath
            ),
            frameworkDirectory: paths.installRoot,
            installedConfigurationPath: paths.configurationPath
        )
        try Data(contents.utf8).write(to: url, options: .atomic)
        do {
            try Task.checkCancellation()
            try await environment.setConfiguration(paths.configurationPath)
        } catch {
            if let previousContents {
                try previousContents.write(to: url, options: .atomic)
            } else {
                try FileManager.default.removeItem(at: url)
            }
            throw error
        }
        return .compatibilityFramework
    }

    func disable() async throws {
        let existing = try await environment.configuration()
        guard existing == paths.configurationPath else { return }
        try await environment.setConfiguration(Self.installedConfiguration(at: paths.configurationPath) ?? "")
    }
}
