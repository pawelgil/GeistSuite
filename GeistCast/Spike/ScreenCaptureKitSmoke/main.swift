import CoreSimulatorPrivate
import Darwin
import Foundation
import GeistKit
import GeistScreenCapture

@main
struct ScreenCaptureKitSmoke {
    // MARK: Nested Types

    enum Failure: Swift.Error {
        case client(String)
        case deviceNotFound
        case install(String)
        case launch(String)
        case timeout
    }

    // MARK: Static Functions

    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data("ScreenCaptureKit smoke failed: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func run() async throws {
        guard (2...3).contains(CommandLine.arguments.count) else {
            print("usage: ScreenCaptureKitSmoke <app-path> [bundle-id]")
            exit(2)
        }
        let appPath = CommandLine.arguments[1]
        let device = try bootedDevice()
        guard let simulator = device.udid else { throw Failure.deviceNotFound }
        let resultPath = "/tmp/geistsck-result-\(UUID().uuidString)"
        unlink(resultPath)

        let session = try GeistScreenCaptureSession(simulator: simulator)
        try await session.start()
        do {
            try await verify(appPath: appPath, device: device, resultPath: resultPath, simulator: simulator)
        } catch {
            await session.stop()
            throw error
        }
        await session.stop()
    }

    private static func verify(appPath: String, device: SimDevice, resultPath: String, simulator: UUID) async throws {
        let bundleID = CommandLine.arguments.count == 3 ? CommandLine.arguments[2]
            : "com.geistcast.tests.screencapturekit-client"
        defer { unlink(resultPath) }
        var installError: NSError?
        guard device.installApplication(
            URL(fileURLWithPath: appPath),
            withOptions: [:],
            error: &installError
        ) else {
            throw Failure.install(installError?.localizedDescription ?? "unknown error")
        }

        defer {
            var cleanupError: NSError?
            _ = device.terminateApplication(withID: bundleID, error: &cleanupError)
            if CommandLine.arguments.count == 3 {
                _ = device.uninstallApplication(bundleID, withOptions: [:], error: &cleanupError)
            }
        }
        var pid: Int32 = 0
        var launchError: NSError?
        guard device.launchApplication(
            withID: bundleID,
            options: ["environment": ["SCK_RESULT_PATH": resultPath]],
            pid: &pid,
            error: &launchError
        ) else {
            throw Failure.launch(launchError?.localizedDescription ?? "unknown error")
        }

        for _ in 0 ..< 100 {
            if FileManager.default.fileExists(atPath: resultPath) {
                let result = try String(contentsOfFile: resultPath, encoding: .utf8)
                guard result == "SCK_FRAME_OK" else { throw Failure.client(result) }
                print("SCREEN_CAPTURE_KIT_SMOKE_OK simulator=\(simulator) pid=\(pid)")
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Failure.timeout
    }

    private static func bootedDevice() throws -> SimDevice {
        guard let developerDirectory = LiveDeveloperDirResolver().resolve() else {
            throw Failure.deviceNotFound
        }
        let context = try SimServiceContext.sharedServiceContext(
            forDeveloperDir: developerDirectory
        )
        let set = try context.defaultDeviceSet()
        guard let device = set.devices?.first(where: {
            $0.state == 3 && ($0.runtimeIdentifier?.contains("iOS-27") ?? false)
        }) else { throw Failure.deviceNotFound }
        return device
    }
}
