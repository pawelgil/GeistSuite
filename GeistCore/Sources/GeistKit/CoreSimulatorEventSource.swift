import CoreSimulatorPrivate
import Foundation

public final class CoreSimulatorEventSource: SimulatorEventSource, @unchecked Sendable {
    private static let bootedState: UInt64 = 3

    private let queue = DispatchQueue(label: "com.geist.coresimulator.events")
    private let developerDirResolver: any DeveloperDirResolving
    private var deviceSet: SimDeviceSet?
    private var token: UInt64 = 0

    public init(developerDirResolver: any DeveloperDirResolving = LiveDeveloperDirResolver()) {
        self.developerDirResolver = developerDirResolver
    }

    public func startObserving(onPoke: @escaping () -> Void) -> Bool {
        guard NSClassFromString("SimServiceContext") != nil,
              let developerDir = developerDirResolver.resolve(),
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
}
