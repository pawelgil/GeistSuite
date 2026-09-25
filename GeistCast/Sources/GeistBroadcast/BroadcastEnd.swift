import Foundation

public struct BroadcastEnd: Sendable {
    // MARK: Nested Types

    public enum Reason: Sendable, Equatable {
        case cancelled
        case finished
        case stopped
        case failed(ExtensionTerminationError)
        case disconnected
    }

    // MARK: Properties

    public let attemptID: UUID
    public let processID: Int32?
    public let timestamp: Date
    public let reason: Reason
    public let termination: (any ProcessTerminationReceipt)?
    public let sequence: UInt64

    // MARK: Lifecycle

    public init(attemptID: UUID, processID: Int32?, timestamp: Date, reason: Reason, termination: (any ProcessTerminationReceipt)?, sequence: UInt64 = 1) {
        self.attemptID = attemptID
        self.processID = processID
        self.timestamp = timestamp
        self.reason = reason
        self.termination = termination
        self.sequence = sequence
    }
}
