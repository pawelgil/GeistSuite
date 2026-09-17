public enum AudioFrameAdmission: Sendable, Equatable {
    /// The frame entered the bounded outbound queue. This does not confirm a socket write or shim consumption.
    case accepted
    case rejected(AudioFrameRejection)
}
