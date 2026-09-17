enum FrameAdmission: Equatable, Sendable {
    case accepted
    case droppedVideo
    case rejected(AudioFrameRejection)
}
