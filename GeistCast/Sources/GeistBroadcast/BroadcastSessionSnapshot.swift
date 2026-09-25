import Foundation

public struct BroadcastSessionSnapshot: Sendable, Equatable {
    // MARK: Nested Types

    public enum Lifecycle: Sendable {
        case idle, starting, recording, paused
    }

    // MARK: Properties

    public let lifecycle: Lifecycle
    public let micDelivery: BroadcastMicDeliveryMode
    public let attemptID: UUID?
    public let processID: Int32?
    public let attemptSequence: UInt64

    // MARK: Lifecycle

    public init(lifecycle: Lifecycle, micDelivery: BroadcastMicDeliveryMode, attemptID: UUID?, processID: Int32?, attemptSequence: UInt64 = 1) {
        self.lifecycle = lifecycle
        self.micDelivery = micDelivery
        self.attemptID = attemptID
        self.processID = processID
        self.attemptSequence = attemptSequence
    }
}
