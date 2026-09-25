public struct ExtensionTerminationError: Error, Equatable, Sendable {
    // MARK: Properties

    public let domain: String
    public let code: Int
    public let message: String

    // MARK: Lifecycle

    public init(domain: String, code: Int, message: String) {
        self.domain = domain
        self.code = code
        self.message = message
    }
}
