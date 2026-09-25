public protocol ProcessTerminationReceipt: Sendable {
    func wait() async throws -> Int32
}
