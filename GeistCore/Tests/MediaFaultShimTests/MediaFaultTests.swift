import Foundation
import MediaFaultShim
import Testing

struct MediaFaultTests {
    @Test func Fault_Status_EncodesBoolean() throws {
        let sut = createSUT()
        let status = sut.handle(["kind": "writer", "action": "arm"])
        let data = try JSONSerialization.data(withJSONObject: status)

        let decoded = try JSONDecoder().decode(Status.self, from: data)

        #expect(decoded.armed)
    }

    private struct Status: Decodable { let armed: Bool }

    @Test func Writer_NextWriter_BindsByStartOrder() {
        let sut = createSUT()
        _ = sut.handle(["kind": "writer", "action": "arm", "trigger": "nextWriter"])
        let first = NSObject()
        let later = NSObject()
        sut.writerStarted(first)
        sut.writerStarted(later)

        #expect(sut.failure(forWriter: later, mediaType: "video") == nil)
        #expect(sut.failure(forWriter: first, mediaType: "video") != nil)
    }

    @Test(arguments: ["writer", "export"])
    func Fault_ClearBeforeFiring_Disarms(kind: String) {
        let sut = createSUT()
        _ = sut.handle(["kind": kind, "action": "arm", "count": 2])

        let cleared = sut.handle(["kind": kind, "action": "clear"])

        #expect(cleared["armed"] as? Bool == false)
        #expect(cleared["remainingCount"] as? Int == 0)
        #expect(sut.failure(forWriter: NSObject(), mediaType: "video") == nil)
        #expect(sut.failure(forExport: NSObject()) == nil)
    }

    @Test func Writer_TwoFailures_ExhaustsAcrossDistinctWriters() {
        let sut = createSUT()
        _ = sut.handle(["kind": "writer", "action": "arm", "count": 2])
        let first = NSObject()
        let second = NSObject()

        #expect(sut.failure(forWriter: first, mediaType: "video") != nil)
        #expect(sut.failure(forWriter: second, mediaType: "video") != nil)
        #expect(sut.failure(forWriter: NSObject(), mediaType: "video") == nil)
        #expect(sut.handle(["kind": "writer", "action": "status"])["firedCount"] as? Int == 2)
    }

    @Test func Writer_Unarmed_PassesThrough() {
        let sut = createSUT()
        #expect(sut.failure(forWriter: NSObject(), mediaType: "video") == nil)
    }

    @Test func Writer_NextWriter_ExcludesExistingWriters() {
        let sut = createSUT()
        let existing = NSObject()
        sut.writerStarted(existing)
        _ = sut.handle(["kind": "writer", "action": "arm", "trigger": "nextWriter"])
        let next = NSObject()
        sut.writerStarted(next)

        #expect(sut.failure(forWriter: existing, mediaType: "video") == nil)
        #expect((sut.failure(forWriter: next, mediaType: "video") as NSError?)?.code == -11800)
    }

    @Test func Writer_Failed_RemainsFailedAfterClear() {
        let sut = createSUT()
        let writer = NSObject()
        _ = sut.handle(["kind": "writer", "action": "arm"])
        let error = sut.failure(forWriter: writer, mediaType: "video") as NSError?

        _ = sut.handle(["kind": "writer", "action": "clear"])

        #expect((sut.failure(forWriter: writer, mediaType: "audio") as NSError?) == error)
        #expect((error?.userInfo[NSUnderlyingErrorKey] as? NSError)?.code == -19649)
        #expect(sut.failure(forWriter: NSObject(), mediaType: "video") == nil)
    }

    @Test func Writer_MediaFilter_DoesNotSpendCount() {
        let sut = createSUT()
        let writer = NSObject()
        _ = sut.handle(["kind": "writer", "action": "arm", "mediaType": "audio", "count": 2])

        #expect(sut.failure(forWriter: writer, mediaType: "video") == nil)
        #expect(sut.failure(forWriter: writer, mediaType: "audio") != nil)
        #expect(sut.failure(forWriter: writer, mediaType: "audio") != nil)
        #expect(sut.handle(["kind": "writer", "action": "status"])["remainingCount"] as? Int == 1)
        #expect(sut.handle(["kind": "writer", "action": "status"])["firedCount"] as? Int == 1)
    }

    @Test func Export_Armed_FailsExactlyOnce() {
        let sut = createSUT()
        _ = sut.handle(["kind": "export", "action": "arm"])

        #expect((sut.failure(forExport: NSObject()) as NSError?)?.code == -11847)
        #expect(sut.failure(forExport: NSObject()) == nil)
    }

    private func createSUT() -> GMFaultController {
        GMFaultController(writerErrorCode: -11800, underlyingCode: -19649, logger: { _ in })
    }
}
