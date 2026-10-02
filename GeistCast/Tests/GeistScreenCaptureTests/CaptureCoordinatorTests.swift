import AVFoundation
import CoreVideo
import Foundation
@testable import GeistScreenCapture
import Synchronization
import Testing

struct CaptureCoordinatorTests {
    @Test
    func start_ScreenRequested_StartsOnlyScreenSource() async throws {
        let screen = SpyScreenFrameCapture()
        let microphone = SpyMicrophoneCapture()
        let sut = createSUT(screen: screen, microphone: microphone)

        try await sut.start(outputs: [.screen])

        #expect(screen.invocations == [.start])
        #expect(microphone.invocations.isEmpty)
    }

    @Test
    func start_MicrophoneRequested_StartsOnlyMicrophoneSource() async throws {
        let screen = SpyScreenFrameCapture()
        let microphone = SpyMicrophoneCapture()
        let sut = createSUT(screen: screen, microphone: microphone)

        try await sut.start(outputs: [.microphone])

        #expect(screen.invocations.isEmpty)
        #expect(microphone.invocations == [.start])
    }

    @Test
    func start_AlreadyActive_ThrowsBusy() async throws {
        let sut = createSUT()
        try await sut.start(outputs: [.screen])

        await #expect(throws: CaptureCoordinator.Error.busy) {
            try await sut.start(outputs: [.screen])
        }
    }

    @Test
    func stop_ActiveSources_StopsEachStartedSource() async throws {
        let screen = SpyScreenFrameCapture()
        let microphone = SpyMicrophoneCapture()
        let sut = createSUT(screen: screen, microphone: microphone)
        try await sut.start(outputs: [.screen, .microphone])

        await sut.stop()

        #expect(screen.invocations == [.start, .stop])
        #expect(microphone.invocations == [.start, .stop])
    }

    @Test
    func start_MicrophoneFails_RollsBackStartedScreen() async {
        let screen = SpyScreenFrameCapture()
        let sut = createSUT(
            screen: screen,
            microphone: StubFailingMicrophoneCapture()
        )

        await #expect(throws: StubFailingMicrophoneCapture.Failure.expected) {
            try await sut.start(outputs: [.screen, .microphone])
        }

        #expect(screen.invocations == [.start, .stop])
    }

    private func createSUT(
        screen: any ScreenFrameCapturing = DummyScreenFrameCapture(),
        microphone: any MicrophoneCapturing = DummyMicrophoneCapture()
    ) -> CaptureCoordinator {
        CaptureCoordinator(
            screen: screen,
            microphone: microphone,
            writer: DummyFrameWriter()
        )
    }
}

private final class SpyScreenFrameCapture: ScreenFrameCapturing {
    // MARK: Nested Types

    enum Invocation: Equatable { case start, stop }

    // MARK: Properties

    private let recordedInvocations = Mutex<[Invocation]>([])

    // MARK: Computed Properties

    var invocations: [Invocation] {
        recordedInvocations.withLock { $0 }
    }

    // MARK: Functions

    func start(delivering _: @escaping @Sendable (CVPixelBuffer) -> Void) throws {
        recordedInvocations.withLock { $0.append(.start) }
    }

    func stop() {
        recordedInvocations.withLock { $0.append(.stop) }
    }
}

private final class SpyMicrophoneCapture: MicrophoneCapturing {
    // MARK: Nested Types

    enum Invocation: Equatable { case start, stop }

    // MARK: Properties

    private let recordedInvocations = Mutex<[Invocation]>([])

    // MARK: Computed Properties

    var invocations: [Invocation] {
        recordedInvocations.withLock { $0 }
    }

    // MARK: Functions

    func start(delivering _: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        recordedInvocations.withLock { $0.append(.start) }
    }

    func stop() {
        recordedInvocations.withLock { $0.append(.stop) }
    }
}

private struct DummyScreenFrameCapture: ScreenFrameCapturing {
    func start(delivering _: @escaping @Sendable (CVPixelBuffer) -> Void) throws {}
    func stop() {}
}

private struct DummyMicrophoneCapture: MicrophoneCapturing {
    func start(delivering _: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {}
    func stop() {}
}

private struct StubFailingMicrophoneCapture: MicrophoneCapturing {
    // MARK: Nested Types

    enum Failure: Swift.Error { case expected }

    // MARK: Functions

    func start(delivering _: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        throw Failure.expected
    }

    func stop() {}
}

private struct DummyFrameWriter: CaptureFrameWriting {
    func write(_: Data) {}
}
