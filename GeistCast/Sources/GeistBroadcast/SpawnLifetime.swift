import Synchronization

final class SpawnLifetime: Sendable {
    // MARK: Properties

    private let stagedAppex: Mutex<StagedAppex?>

    // MARK: Lifecycle

    init(stagedAppex: StagedAppex) {
        self.stagedAppex = Mutex(stagedAppex)
    }

    // MARK: Functions

    func confirmTermination() {
        let released = stagedAppex.withLock { stagedAppex -> StagedAppex? in
            let released = stagedAppex
            stagedAppex = nil
            return released
        }
        withExtendedLifetime(released) {}
    }
}
