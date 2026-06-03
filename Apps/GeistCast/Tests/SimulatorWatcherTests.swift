import Foundation
import Testing
import GeistBroadcast
@testable import GeistCast

@Suite struct SimulatorWatcherTests {

    @Test
    func snapshots_alreadyBooted_yieldsCurrentSet() async throws {
        let sim = BootedSimulator(udid: "A", name: "iPhone A")
        let sut = SimulatorWatcher(
            listing: StubListing(snapshot: [sim]),
            pollInterval: .milliseconds(1)
        )

        let snapshot = await firstSnapshot(from: sut.snapshots())

        #expect(snapshot == Set([sim]))
    }

    @Test
    func snapshots_simulatorAppearsThenDisappears_yieldsCorrespondingSets() async throws {
        let sim = BootedSimulator(udid: "A", name: "iPhone A")
        let sut = SimulatorWatcher(
            listing: ScriptedListing(snapshots: [[], [sim], []]),
            pollInterval: .milliseconds(1)
        )

        let snapshots = await collectDistinct(count: 3, from: sut.snapshots())

        #expect(snapshots == [Set(), Set([sim]), Set()])
    }

    private func firstSnapshot(
        from stream: AsyncStream<Set<BootedSimulator>>
    ) async -> Set<BootedSimulator>? {
        for await snap in stream { return snap }
        return nil
    }

    private func collectDistinct(
        count: Int,
        from stream: AsyncStream<Set<BootedSimulator>>
    ) async -> [Set<BootedSimulator>] {
        var result: [Set<BootedSimulator>] = []
        for await snap in stream {
            if result.last != snap { result.append(snap) }
            if result.count == count { return result }
        }
        return result
    }

    private struct StubListing: BootedSimulatorsListing {
        let snapshot: [BootedSimulator]
        func listBootedSimulators() async throws -> [BootedSimulator] { snapshot }
    }

    private actor ScriptedListing: BootedSimulatorsListing {
        private let snapshots: [[BootedSimulator]]
        private var index: Int = 0

        init(snapshots: [[BootedSimulator]]) { self.snapshots = snapshots }

        func listBootedSimulators() async throws -> [BootedSimulator] {
            let snap = snapshots[min(index, snapshots.count - 1)]
            index += 1
            return snap
        }
    }
}
