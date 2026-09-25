import Foundation

public enum BroadcastLifecycleEvent: Sendable {
    case processStarted(attemptID: UUID, processID: Int32, sequence: UInt64 = 1)
    case ended(BroadcastEnd)
}
