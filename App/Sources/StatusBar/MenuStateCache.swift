import Foundation

// Stale reads on menu open; background poll keeps cache within ~30s. Avoids
// blocking the UI on slow simctl subprocesses.
@MainActor
final class MenuStateCache {
    static let shared = MenuStateCache()

    var bootedDevices: [BootedDevice] = []
    var apps: [String: [InstalledApp]] = [:]

    private var pollTask: Task<Void, Never>?

    func startPolling(interval: TimeInterval = 30) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func refresh() async {
        let fresh = await Task.detached(priority: .background) {
            SimulatorWatcher.bootedDevices()
        }.value
        self.bootedDevices = fresh

        var newApps: [String: [InstalledApp]] = [:]
        for device in fresh {
            let udid = device.udid
            newApps[udid] = await Task.detached(priority: .background) {
                AppEnumerator.cameraCapableApps(udid: udid)
            }.value
        }
        self.apps = newApps
    }
}
