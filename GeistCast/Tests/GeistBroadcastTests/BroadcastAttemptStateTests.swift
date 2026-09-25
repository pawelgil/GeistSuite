import Foundation
@testable import GeistBroadcast
import Testing

struct BroadcastAttemptStateTests {
    @Test func Attempt_EndThenDiscard_SequenceKeepsIncreasing() throws {
        var state = BroadcastAttemptState()
        let first = state.begin()
        let result = state.end(reason: .finished, processID: 12)
        let end = try #require(result)
        let second = state.begin()
        state.discard()
        let third = state.begin()

        #expect(end.attemptID == first.id)
        #expect(end.sequence == 1)
        #expect(second.id != first.id)
        #expect(third.id != second.id)
        #expect(state.id == third.id)
        #expect(state.sequence == 3)
    }

    @Test func Attempt_RepeatedEnd_ProducesOneEnd() throws {
        var state = BroadcastAttemptState()
        let attempt = state.begin()
        let timestamp = Date(timeIntervalSince1970: 123)
        let result = state.end(reason: .stopped, processID: 12, timestamp: timestamp)
        let end = try #require(result)

        #expect(end.attemptID == attempt.id)
        #expect(end.processID == 12)
        #expect(end.timestamp == timestamp)
        #expect(end.reason == .stopped)
        #expect(state.end(reason: .finished, processID: 12) == nil)
        #expect(state.id == nil)
    }

    @Test func Attempt_Discard_DoesNotProduceEndOrAnnouncement() {
        var state = BroadcastAttemptState()
        _ = state.begin()

        state.discard()

        #expect(state.id == nil)
        #expect(state.end(reason: .cancelled, processID: nil) == nil)
        #expect(state.announce(processID: 12) == nil)
        #expect(state.processStarted(processID: 12) == nil)
        #expect(state.sequence == 1)
    }

    @Test func Attempt_RepeatedProcess_AnnouncesOncePerAttempt() throws {
        var state = BroadcastAttemptState()
        let first = state.begin()
        try expectStarted(state.announce(processID: 12), attemptID: first.id, processID: 12, sequence: 1)
        #expect(state.announce(processID: 12) == nil)
        try expectStarted(state.processStarted(processID: 12), attemptID: first.id, processID: 12, sequence: 1)
        try expectStarted(state.announce(processID: 13), attemptID: first.id, processID: 13, sequence: 1)
        _ = state.end(reason: .finished, processID: 13)
        let second = state.begin()

        try expectStarted(state.announce(processID: 12), attemptID: second.id, processID: 12, sequence: 2)
    }

    @Test(.timeLimit(.minutes(1))) func Attempt_TerminationBeforeEnd_ReceiptContainsExit() async throws {
        var state = BroadcastAttemptState()
        let process = ProcessTermination()
        process.record(42)
        _ = state.begin(processTermination: process)

        let result = state.end(reason: .disconnected, processID: 12)
        let receipt = try #require(result?.termination)

        #expect(try await receipt.wait() == 42)
    }

    @Test(.timeLimit(.minutes(1))) func Attempt_TerminationAfterEndAndRearm_CompletesOnlyOriginalReceipt() async throws {
        var state = BroadcastAttemptState()
        let old = state.begin()
        let oldResult = state.end(reason: .cancelled, processID: nil)
        let oldReceipt = try #require(oldResult?.termination)
        let latestProcess = ProcessTermination()
        _ = state.begin(processTermination: latestProcess)
        let process = ProcessTermination()

        old.forwardTermination(from: process)
        process.record(42)
        latestProcess.record(13)
        let latestResult = state.end(reason: .stopped, processID: 13)
        let latestEnd = try #require(latestResult)
        let latestReceipt = try #require(latestEnd.termination)

        #expect(try await oldReceipt.wait() == 42)
        #expect(try await latestReceipt.wait() == 13)
        #expect(latestEnd.sequence == 2)
    }

    private func expectStarted(
        _ event: BroadcastLifecycleEvent?, attemptID: UUID, processID: Int32, sequence: UInt64
    ) throws {
        let event = try #require(event)
        guard case let .processStarted(actualID, actualPID, actualSequence) = event else {
            Issue.record("Expected processStarted")
            return
        }
        #expect(actualID == attemptID)
        #expect(actualPID == processID)
        #expect(actualSequence == sequence)
    }
}
