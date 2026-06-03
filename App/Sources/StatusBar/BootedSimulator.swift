struct BootedSimulator: Sendable, Equatable, Hashable {
    let udid: String
    let name: String

    init(udid: String, name: String) {
        self.udid = udid
        self.name = name
    }
}

protocol BootedSimulatorsListing: Sendable {
    func listBootedSimulators() async throws -> [BootedSimulator]
}
