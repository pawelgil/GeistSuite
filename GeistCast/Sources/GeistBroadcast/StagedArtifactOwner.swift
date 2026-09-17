final class StagedArtifactOwner: Sendable {
    // MARK: Nested Types

    typealias CleanupFailureReporter = @Sendable (_ path: String, _ error: Error) -> Void

    // MARK: Properties

    private let cleanupFailureReporter: CleanupFailureReporter
    private let fileSystem: any FileSystem
    private let receipt: OwnedDirectoryReceipt

    // MARK: Lifecycle

    init(
        fileSystem: any FileSystem,
        receipt: OwnedDirectoryReceipt,
        cleanupFailureReporter: @escaping CleanupFailureReporter
    ) {
        self.fileSystem = fileSystem
        self.receipt = receipt
        self.cleanupFailureReporter = cleanupFailureReporter
    }

    deinit {
        do {
            try fileSystem.removeOwnedDirectory(receipt)
        } catch {
            cleanupFailureReporter(receipt.canonicalPath, error)
        }
    }
}
