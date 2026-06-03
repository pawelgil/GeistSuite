import Foundation

protocol BootedSimulatorProviding: Sendable {
    func queryBooted() -> Set<String>
}

struct DefaultBootedSimulatorProvider: BootedSimulatorProviding {
    func queryBooted() -> Set<String> { SimulatorWatcher.queryBootedSimulators() }
}

final class SimulatorWatcher {
    typealias OnChange = (_ added: Set<String>, _ removed: Set<String>) -> Void

    private let pollInterval: TimeInterval
    private let onChange: OnChange
    private let provider: any BootedSimulatorProviding
    private let queue = DispatchQueue(label: "geistlens.sim-watcher")
    private var timer: DispatchSourceTimer?
    private var differ = SetDiffer<String>()
    private var tickCount: UInt64 = 0

    init(pollInterval: TimeInterval = 2.0,
         provider: any BootedSimulatorProviding = DefaultBootedSimulatorProvider(),
         onChange: @escaping OnChange) {
        self.pollInterval = pollInterval
        self.provider = provider
        self.onChange = onChange
    }

    func start() {
        let interval = pollInterval
        Log.notice("SimulatorWatcher: starting (poll=\(interval)s)")
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: pollInterval)
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    func stop() {
        Log.notice("SimulatorWatcher: stopping")
        timer?.cancel()
        timer = nil
    }

    /// Forces a poll outside the timer cadence. Used after wake-from-sleep
    /// where GCD timers can be coalesced and lag the actual sim state.
    func pollNow() {
        Log.notice("SimulatorWatcher: pollNow()")
        queue.async { [weak self] in self?.tick() }
    }

    private func tick() {
        tickCount &+= 1
        let current = provider.queryBooted()
        let (added, removed) = differ.diff(current: current)
        // Heartbeat ~ every 60s confirms the GCD timer is alive (esp. after sleep).
        if tickCount % 30 == 0 {
            let count = tickCount
            let sortedCurrent = current.sorted()
            Log.info("SimulatorWatcher.heartbeat: tick=\(count) booted=\(sortedCurrent)")
        }
        if added.isEmpty && removed.isEmpty { return }
        let after = current.sorted()
        let addedList = added.sorted()
        let removedList = removed.sorted()
        Log.notice("SimulatorWatcher.tick: current=\(after) added=\(addedList) removed=\(removedList)")
        DispatchQueue.main.async { [onChange] in onChange(added, removed) }
    }

    static func queryBootedSimulators() -> Set<String> {
        Set(bootedDevices().map(\.udid))
    }

    static func bootedDevices() -> [BootedDevice] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "list", "devices", "--json", "booted"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            Log.warn("simctl list failed to launch: \(error)")
            return []
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let json = try? JSONDecoder().decode(SimctlListOutput.self, from: data) else {
            Log.warn("simctl list returned unexpected JSON")
            return []
        }
        var devices: [BootedDevice] = []
        for (runtime, deviceList) in json.devices {
            for d in deviceList where d.state == "Booted" {
                devices.append(BootedDevice(udid: d.udid, name: d.name, runtime: runtime))
            }
        }
        return devices.sorted { $0.name < $1.name }
    }
}

struct BootedDevice {
    let udid: String
    let name: String
    let runtime: String

    var displayLabel: String {
        let prefix = "com.apple.CoreSimulator.SimRuntime."
        guard runtime.hasPrefix(prefix) else { return name }
        let parts = runtime.dropFirst(prefix.count).split(separator: "-")
        guard parts.count >= 2 else { return name }
        let os = String(parts[0])
        let version = parts.dropFirst().joined(separator: ".")
        return "\(name) (\(os) \(version))"
    }
}

private struct SimctlListOutput: Decodable {
    let devices: [String: [Device]]
    struct Device: Decodable {
        let udid: String
        let state: String
        let name: String
    }
}
