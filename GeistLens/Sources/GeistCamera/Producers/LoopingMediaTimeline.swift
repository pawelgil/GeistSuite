import CoreMedia

struct LoopingMediaTimeline {
    // MARK: Properties

    private let start: CMTime
    private let cycleDuration: CMTime
    private var sourceAnchor: CMTime?
    private var cycleOffset = CMTime.zero

    // MARK: Lifecycle

    init(start: CMTime, cycleDuration: CMTime) {
        self.start = start
        self.cycleDuration = cycleDuration
    }

    // MARK: Functions

    mutating func presentationTime(for sourceTime: CMTime) -> CMTime {
        let anchor = sourceAnchor ?? sourceTime
        sourceAnchor = anchor
        return start + (cycleOffset + sourceTime - anchor)
    }

    mutating func advanceCycle() {
        cycleOffset = cycleOffset + cycleDuration
    }
}
