struct FrameQueueScheduler<Element: Sendable> {
    // MARK: Nested Types

    enum IterationResult: Equatable {
        case finished
        case idle
        case wroteFrames
    }

    // MARK: Properties

    private let maximumAudioBurst: Int

    // MARK: Lifecycle

    init(maximumAudioBurst: Int) {
        precondition(maximumAudioBurst > 0)
        self.maximumAudioBurst = maximumAudioBurst
    }

    // MARK: Functions

    func runIteration(
        audioQueue: BoundedFrameQueue<Element>,
        videoQueue: BoundedFrameQueue<Element>,
        write: (Element) -> Bool
    ) -> IterationResult {
        var audioOpen = false
        var videoOpen = false
        var wroteFrames = false

        audioBurst: for _ in 0 ..< maximumAudioBurst {
            switch audioQueue.dequeue(timeoutSeconds: 0) {
            case let .received(frame):
                audioOpen = true
                guard write(frame) else { return .finished }
                wroteFrames = true
            case .empty:
                audioOpen = true
                break audioBurst
            case .closed:
                break audioBurst
            }
        }

        switch videoQueue.dequeue(timeoutSeconds: 0) {
        case let .received(frame):
            videoOpen = true
            guard write(frame) else { return .finished }
            wroteFrames = true
        case .empty:
            videoOpen = true
        case .closed:
            break
        }

        guard audioOpen || videoOpen else { return .finished }
        return wroteFrames ? .wroteFrames : .idle
    }
}
