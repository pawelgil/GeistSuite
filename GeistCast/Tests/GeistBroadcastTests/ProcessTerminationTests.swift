@testable import GeistBroadcast
import Testing

struct ProcessTerminationTests {
    @Test func termination_LinkedAfterExit_ForwardsRecordedStatus() async throws {
        let source = ProcessTermination()
        let target = ProcessTermination()
        source.record(12)

        source.forward(to: target)

        #expect(try await target.wait() == 12)
    }

    @Test func termination_LinkedBeforeExit_ForwardsFutureStatus() async throws {
        let source = ProcessTermination()
        let target = ProcessTermination()
        source.forward(to: target)

        source.record(15)

        #expect(try await target.wait() == 15)
    }

    @Test func termination_recordedBeforeWait_returnsStatus() async throws {
        let sut = ProcessTermination()
        sut.record(7)

        let status = try await sut.wait()

        #expect(status == 7)
    }

    @Test func termination_recordedAfterWait_resumesEveryObserver() async throws {
        let sut = ProcessTermination()
        async let first = sut.wait()
        async let second = sut.wait()

        sut.record(9)

        #expect(try await first == 9)
        #expect(try await second == 9)
    }

    @Test func termination_cancelledWait_doesNotLoseReceipt() async throws {
        let sut = ProcessTermination()
        let observer = Task { try await sut.wait() }
        observer.cancel()

        await #expect(throws: CancellationError.self) { try await observer.value }
        sut.record(3)

        #expect(try await sut.wait() == 3)
    }
}
