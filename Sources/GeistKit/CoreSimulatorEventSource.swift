import CoreSimulatorPrivate
import Foundation

public final class CoreSimulatorEventSource: SimulatorEventSource, @unchecked Sendable {
    private static let bootedState: UInt64 = 3

    private let queue = DispatchQueue(label: "com.geist.coresimulator.events")
    private var deviceSet: SimDeviceSet?
    private var token: UInt64 = 0

    public init() {}

    public func startObserving(onPoke: @escaping () -> Void) -> Bool {
        guard NSClassFromString("SimServiceContext") != nil,
              let developerDir = Self.developerDir(),
              let context = try? SimServiceContext(forDeveloperDir: developerDir),
              let set = try? context.defaultDeviceSet() else {
            return false
        }
        deviceSet = set
        let handler: @convention(block) (Any?) -> Void = { _ in onPoke() }
        token = set.registerNotificationHandler(onQueue: queue, handler: handler)
        return true
    }

    public func currentBootedUDIDs() -> Set<String> {
        guard let devices = deviceSet?.devices else { return [] }
        var booted: Set<String> = []
        for device in devices where device.state == Self.bootedState {
            if let udid = device.udid?.uuidString {
                booted.insert(udid.lowercased())
            }
        }
        return booted
    }

    public func stopObserving() {
        queue.sync {
            guard let set = deviceSet, token != 0 else { return }
            _ = set.unregisterNotificationHandler(token, error: nil)
            token = 0
            deviceSet = nil
        }
    }

    private static func developerDir() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}
