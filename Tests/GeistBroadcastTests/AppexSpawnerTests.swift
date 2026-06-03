import Foundation
import Synchronization
import Testing
@testable import GeistBroadcast

@Suite("AppexSpawner")
struct AppexSpawnerTests {

    @Test
    func spawn_givenBinaryAndSimulator_buildsXcrunSimctlSpawnInvocation() async throws {
        let process = FakeProcessRunner()
        let sut = createSUT(process: process)

        try await sut.spawn(
            stagedBinary: "/tmp/staged.appex/Some",
            simulatorUDID: "SIM-1",
            simctlSetPath: nil,
            environment: [:]
        )

        let call = try #require(process.calls.first { $0.executable == "/usr/bin/xcrun" })
        #expect(call.arguments == ["simctl", "spawn", "SIM-1", "/tmp/staged.appex/Some"])
    }

    @Test
    func spawn_withSimctlSetPath_passesSetArgument() async throws {
        let process = FakeProcessRunner()
        let sut = createSUT(process: process)

        try await sut.spawn(
            stagedBinary: "/tmp/staged.appex/Some",
            simulatorUDID: "SIM-1",
            simctlSetPath: "/path/to/set",
            environment: [:]
        )

        let call = try #require(process.calls.first { $0.executable == "/usr/bin/xcrun" })
        #expect(call.arguments == [
            "simctl", "--set", "/path/to/set", "spawn", "SIM-1", "/tmp/staged.appex/Some",
        ])
    }

    @Test
    func spawn_environment_isForwardedWithSimctlChildPrefix() async throws {
        let process = FakeProcessRunner()
        let sut = createSUT(process: process)

        try await sut.spawn(
            stagedBinary: "/tmp/staged.appex/Some",
            simulatorUDID: "SIM-1",
            simctlSetPath: nil,
            environment: [
                "DYLD_INSERT_LIBRARIES": "/path/shim.dylib",
                "GEISTCAST_DRIVE_BROADCAST": "1",
            ]
        )

        let call = try #require(process.calls.first { $0.executable == "/usr/bin/xcrun" })
        #expect(call.environment["SIMCTL_CHILD_DYLD_INSERT_LIBRARIES"] == "/path/shim.dylib")
        #expect(call.environment["SIMCTL_CHILD_GEISTCAST_DRIVE_BROADCAST"] == "1")
    }

    @Test
    func spawn_always_reapsStaleProcessesByStagedBinaryFirst() async throws {
        let process = FakeProcessRunner()
        let sut = createSUT(process: process)

        try await sut.spawn(
            stagedBinary: "/tmp/staged.appex/Some",
            simulatorUDID: "SIM-1",
            simctlSetPath: nil,
            environment: [:]
        )

        let first = try #require(process.calls.first)
        #expect(first.executable == "/usr/bin/pkill")
        #expect(first.arguments == ["-9", "-f", "/tmp/staged.appex/Some"])
    }

    @Test
    func killStale_givenStagedBinary_invokesPkillDashF() async throws {
        let process = FakeProcessRunner()
        let sut = createSUT(process: process)

        await sut.killStale(stagedBinary: "/tmp/staged.appex/Some")

        let call = try #require(process.calls.first)
        #expect(call.executable == "/usr/bin/pkill")
        #expect(call.arguments == ["-9", "-f", "/tmp/staged.appex/Some"])
    }

    // MARK: helpers

    private func createSUT(process: FakeProcessRunner = FakeProcessRunner()) -> AppexSpawner {
        AppexSpawner(process: process)
    }
}

private final class FakeProcessRunner: ProcessRunner {
    private let invocations = Mutex<[ProcessInvocation]>([])

    var calls: [ProcessInvocation] {
        invocations.withLock { $0 }
    }

    func run(_ invocation: ProcessInvocation) async throws -> ProcessResult {
        invocations.withLock { $0.append(invocation) }
        return ProcessResult(exitStatus: 0, stdout: Data(), stderr: Data())
    }
}
