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

    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            print("usage: ScreenCaptureKitSmoke <app-path>")
            exit(2)
        }
        let appPath = CommandLine.arguments[1]
        let device = try bootedDevice()
        guard let simulator = device.udid else { throw Failure.deviceNotFound }
        let resultPath = "/tmp/geistsck-result-\(UUID().uuidString)"
        unlink(resultPath)

        let session = try GeistScreenCaptureSession(simulator: simulator)
        try await session.start()
        defer { Task { await session.stop() } }

        var installError: NSError?
        guard device.installApplication(
            URL(fileURLWithPath: appPath),
            withOptions: [:],
            error: &installError
        ) else {
            throw Failure.install(installError?.localizedDescription ?? "unknown error")
        }

        let bundleID = "com.geistcast.tests.screencapturekit-client"
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
                var terminationError: NSError?
                _ = device.terminateApplication(withID: bundleID, error: &terminationError)
                unlink(resultPath)
                await session.stop()
                guard result == "SCK_FRAME_OK" else { throw Failure.client(result) }
                print("SCREEN_CAPTURE_KIT_SMOKE_OK simulator=\(simulator) pid=\(pid)")
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        var terminationError: NSError?
        _ = device.terminateApplication(withID: bundleID, error: &terminationError)
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
