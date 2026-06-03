import Foundation

struct SimulatorWatcher: Sendable {
    private let listing: any BootedSimulatorsListing
    private let pollInterval: Duration

    init(listing: any BootedSimulatorsListing, pollInterval: Duration = .seconds(2)) {
        self.listing = listing
        self.pollInterval = pollInterval
    }

    func snapshots() -> AsyncStream<Set<BootedSimulator>> {
        let listing = self.listing
        let pollInterval = self.pollInterval
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task.detached {
                while !Task.isCancelled {
                    if let current = try? await listing.listBootedSimulators() {
                        continuation.yield(Set(current))
                    }
                    try? await Task.sleep(for: pollInterval)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
