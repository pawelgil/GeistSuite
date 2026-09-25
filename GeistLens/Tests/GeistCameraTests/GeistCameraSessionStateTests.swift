import Foundation
import GeistCameraShimCore
import Testing

struct GeistCameraSessionStateTests {
    @Test func interruption_CompetingPreviews_OnlyOneMutationBegins() {
        let sut = createSUT()
        let firstPreview = sut.previewInterruptionTransition(for: .contention, reason: 3)
        let secondPreview = sut.previewInterruptionTransition(for: .contention, reason: 3)

        let first = sut.setReason(3, for: .contention)
        let second = sut.setReason(3, for: .contention)

        #expect(firstPreview == .began)
        #expect(secondPreview == .began)
        #expect(first == .began)
        #expect(second == .unchanged)
        #expect(sut.deliveryGeneration == 1)
    }

    @Test func interruption_LastCauseRemoved_ReturnsCommittedEnd() {
        let sut = createSUT()
        sut.setReason(1, for: .lifecycle)

        let transition = sut.setReason(nil, for: .lifecycle)

        #expect(transition == .ended)
        #expect(sut.interruptionReason == nil)
    }

    @Test func interruption_StoppedBeforeForeground_ClearsLifecycleCause() {
        let sut = createSUT()
        sut.running = true
        sut.setReason(1, for: .lifecycle)
        sut.running = false

        sut.setReason(nil, for: .lifecycle)
        sut.running = true

        #expect(sut.interruptionReason == nil)
    }

    @Test func interruption_ClearingLifecycle_PreservesManualCause() {
        let sut = createSUT()
        sut.setReason(1, for: .lifecycle)
        sut.setReason(2, for: .manual)

        sut.setReason(nil, for: .lifecycle)

        #expect(sut.interruptionReason == 2)
    }

    @Test func interruption_ClearingManual_RestoresContentionCause() {
        let sut = createSUT()
        sut.setReason(3, for: .contention)
        sut.setReason(2, for: .manual)

        sut.setReason(nil, for: .manual)

        #expect(sut.interruptionReason == 3)
    }

    @Test func interruption_LifecycleAndContention_PrefersLifecycle() {
        let sut = createSUT()
        sut.setReason(3, for: .contention)

        sut.setReason(1, for: .lifecycle)

        #expect(sut.interruptionReason == 1)
    }

    @Test func deliveryGeneration_AdditionalCause_DoesNotInvalidateAgain() {
        let sut = createSUT()
        sut.setReason(3, for: .contention)
        let generation = sut.deliveryGeneration

        sut.setReason(1, for: .lifecycle)

        #expect(sut.deliveryGeneration == generation)
    }

    @Test func deliveryGeneration_NewInterruption_InvalidatesQueuedFrames() {
        let sut = createSUT()
        let generation = sut.deliveryGeneration

        sut.setReason(1, for: .lifecycle)

        #expect(sut.deliveryGeneration == generation + 1)
    }

    @Test func deliveryGeneration_ReasonReplaced_PreservesQueuedFrameGeneration() {
        let sut = createSUT()
        sut.setReason(2, for: .manual)
        let generation = sut.deliveryGeneration

        sut.setReason(4, for: .manual)

        #expect(sut.interruptionReason == 4)
        #expect(sut.deliveryGeneration == generation)
    }

    @Test func deliveryGeneration_InterruptionEnds_PreservesQueuedFrameGeneration() {
        let sut = createSUT()
        sut.setReason(2, for: .manual)
        let generation = sut.deliveryGeneration

        sut.setReason(nil, for: .manual)

        #expect(sut.interruptionReason == nil)
        #expect(sut.deliveryGeneration == generation)
    }

    @Test func interruptionChange_AnotherCauseRemains_DoesNotEnd() {
        let sut = createSUT()
        sut.setReason(1, for: .lifecycle)
        sut.setReason(2, for: .manual)

        let transition = sut.previewInterruptionTransition(for: .manual, reason: nil)

        #expect(transition == .unchanged)
    }

    @Test func interruptionChange_LastCauseRemoved_Ends() {
        let sut = createSUT()
        sut.setReason(1, for: .lifecycle)

        let transition = sut.previewInterruptionTransition(for: .lifecycle, reason: nil)

        #expect(transition == .ended)
    }

    @Test func interruptionChange_FirstCauseAdded_Begins() {
        let sut = createSUT()

        let transition = sut.previewInterruptionTransition(for: .manual, reason: 2)

        #expect(transition == .began)
        #expect(sut.interruptionReason == nil)
    }

    @Test func interruptionChange_ReasonReplaced_LeavesInterruptionUnchanged() {
        let sut = createSUT()
        sut.setReason(2, for: .manual)

        let transition = sut.previewInterruptionTransition(for: .manual, reason: 4)

        #expect(transition == .unchanged)
        #expect(sut.interruptionReason == 2)
        #expect(sut.deliveryGeneration == 1)
    }

    @Test func configuration_Begin_RecordsPendingConfiguration() {
        let sut = createSUT()

        sut.beginConfiguration(hasCamera: true)

        #expect(sut.isConfiguring)
        #expect(sut.deliveryGeneration == 0)
    }

    @Test func configuration_CameraRemoved_InvalidatesQueuedFrames() {
        let sut = createSUT()
        sut.beginConfiguration(hasCamera: true)

        sut.commitConfiguration(hasCamera: false)

        #expect(sut.deliveryGeneration == 1)
        #expect(!sut.isConfiguring)
    }

    @Test(arguments: [(false, false), (false, true), (true, true)])
    func configuration_NoCameraLoss_PreservesQueuedFrames(hadCamera: Bool, hasCamera: Bool) {
        let sut = createSUT()
        sut.beginConfiguration(hasCamera: hadCamera)

        sut.commitConfiguration(hasCamera: hasCamera)

        #expect(sut.deliveryGeneration == 0)
        #expect(!sut.isConfiguring)
    }

    @Test func configuration_RepeatedCommit_DoesNotInvalidateAgain() {
        let sut = createSUT()
        sut.beginConfiguration(hasCamera: true)
        sut.commitConfiguration(hasCamera: false)

        sut.commitConfiguration(hasCamera: false)

        #expect(sut.deliveryGeneration == 1)
    }

    @Test(arguments: [false, true])
    func configuration_CommitWithoutBegin_PreservesQueuedFrames(hasCamera: Bool) {
        let sut = createSUT()

        sut.commitConfiguration(hasCamera: hasCamera)

        #expect(sut.deliveryGeneration == 0)
        #expect(!sut.isConfiguring)
    }

    @Test func cameraInputs_CameraRemoved_InvalidatesQueuedFrames() {
        let sut = createSUT()

        sut.cameraInputsChanged(from: true, to: false)

        #expect(sut.deliveryGeneration == 1)
    }

    @Test(arguments: [(false, false), (false, true), (true, true)])
    func cameraInputs_NoCameraLoss_PreservesQueuedFrames(hadCamera: Bool, hasCamera: Bool) {
        let sut = createSUT()

        sut.cameraInputsChanged(from: hadCamera, to: hasCamera)

        #expect(sut.deliveryGeneration == 0)
    }

    private func createSUT() -> GeistCameraSessionState {
        GeistCameraSessionState()
    }
}
