import Foundation

struct ProcessBootedSimulatorsListing: BootedSimulatorsListing {
    private let process: any ProcessRunning

    init(process: any ProcessRunning) {
        self.process = process
    }

    func listBootedSimulators() async throws -> [BootedSimulator] {
        let stdout = try await process.run(
            executable: "/usr/bin/xcrun",
            arguments: ["simctl", "list", "devices", "--json", "booted"]
        )
        let response = try JSONDecoder().decode(SimctlDevicesResponse.self, from: stdout)
        var result: [BootedSimulator] = []
        for (_, devices) in response.devices {
            for device in devices where device.state == "Booted" {
                result.append(BootedSimulator(
                    udid: device.udid,
                    name: device.name
                ))
            }
        }
        return result
    }
}

private struct SimctlDevicesResponse: Decodable {
    let devices: [String: [Device]]

    struct Device: Decodable {
        let udid: String
        let name: String
        let state: String
    }
}
