import Foundation
import Testing
import GeistBroadcast
@testable import GeistCast

@Suite struct ProcessBootedSimulatorsListingTests {

    @Test
    func listBootedSimulators_deviceWithShutdownState_excluded() async throws {
        let json = """
        {
            "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-26-2": [
                    { "udid": "AAA", "name": "Booted Phone", "state": "Booted" },
                    { "udid": "BBB", "name": "Shutdown Phone", "state": "Shutdown" }
                ]
            }
        }
        """
        let sut = makeSUT(stdout: json)

        let result = try await sut.listBootedSimulators()

        #expect(result.map(\.udid) == ["AAA"])
    }

    @Test
    func listBootedSimulators_oneBootedDevice_returnedAsBootedSimulator() async throws {
        let udid = "8DD3E3DD-CD03-4B91-8AD6-EC4073BC626D"
        let name = "iPhone Air"
        let json = """
        {
            "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-26-2": [
                    { "udid": "\(udid)", "name": "\(name)", "state": "Booted" }
                ]
            }
        }
        """
        let sut = makeSUT(stdout: json)

        let result = try await sut.listBootedSimulators()

        #expect(result == [BootedSimulator(udid: udid, name: name)])
    }

    private func makeSUT(stdout: String) -> ProcessBootedSimulatorsListing {
        ProcessBootedSimulatorsListing(process: StubProcess(stdout: Data(stdout.utf8)))
    }

    private struct StubProcess: ProcessRunning {
        let stdout: Data
        func run(executable _: String, arguments _: [String]) async throws -> Data { stdout }
    }
}
