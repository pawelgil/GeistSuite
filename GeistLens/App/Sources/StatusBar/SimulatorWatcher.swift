import Foundation

enum SimulatorWatcher {
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
            log.warn("simctl list failed to launch: \(error)")
            return []
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let json = try? JSONDecoder().decode(SimctlListOutput.self, from: data) else {
            log.warn("simctl list returned unexpected JSON")
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
