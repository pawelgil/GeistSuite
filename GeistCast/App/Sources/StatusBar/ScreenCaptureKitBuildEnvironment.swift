import Foundation

protocol ScreenCaptureKitBuildEnvironment: Sendable {
    func simulatorSDKPath() async throws -> String
    func configuration() async throws -> String
    func setConfiguration(_ path: String) async throws
}

struct LiveScreenCaptureKitBuildEnvironment: ScreenCaptureKitBuildEnvironment {
    let process: any ProcessRunning

    func simulatorSDKPath() async throws -> String {
        let data = try await process.run(executable: "/usr/bin/xcrun",
                                        arguments: ["--sdk", "iphonesimulator", "--show-sdk-path"])
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func configuration() async throws -> String {
        let data = try await process.run(executable: "/bin/launchctl",
                                        arguments: ["getenv", "XCODE_XCCONFIG_FILE"])
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func setConfiguration(_ path: String) async throws {
        let arguments = path.isEmpty ? ["unsetenv", "XCODE_XCCONFIG_FILE"]
            : ["setenv", "XCODE_XCCONFIG_FILE", path]
        _ = try await process.run(executable: "/bin/launchctl", arguments: arguments)
    }
}
