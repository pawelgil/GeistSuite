import AVFoundation
import Foundation
import MediaFaultShim
import Synchronization
import Testing

@Suite(.serialized)
struct MediaFaultRuntimeTests {
    @Test func Writer_NextWriter_RemainsReadyUntilAppend() async throws {
        let controller = try createSUT()
        _ = controller.handle(["kind": "writer", "action": "arm", "trigger": "nextWriter", "mediaType": "video"])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try createWriter(url: url)
        controller.writerStarted(writer)
        let input = try #require(writer.inputs.first)
        #expect(writer.status == .writing)
        #expect(writer.error == nil)
        #expect(controller.handle(["kind": "writer", "action": "status"])["firedCount"] as? Int == 0)

        let beforeAppend = await withCheckedContinuation { continuation in
            input.requestMediaDataWhenReady(on: DispatchQueue(label: "test.writer.ready")) {
                let before = (writer.status, input.isReadyForMoreMediaData)
                _ = GMMediaFaults.rejectAppend(writer: writer, mediaType: AVMediaType.video.rawValue)
                input.markAsFinished()
                continuation.resume(returning: before)
            }
        }

        #expect(beforeAppend.0 == .writing)
        #expect(beforeAppend.1)
        #expect(writer.status == .failed)
        #expect((writer.error as NSError?)?.code == -11800)
        #expect(controller.handle(["kind": "writer", "action": "status"])["firedCount"] as? Int == 1)
    }

    @Test func Writer_VideoAppend_ReportsPersistentFailureAndFinishes() async throws {
        let controller = try createSUT()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try createWriter(url: url)
        _ = controller.handle(["kind": "writer", "action": "arm", "mediaType": "video"])

        let rejected = GMMediaFaults.rejectAppend(writer: writer, mediaType: AVMediaType.video.rawValue)
        await withCheckedContinuation { continuation in writer.finishWriting { continuation.resume() } }

        #expect(rejected)
        #expect(writer.status == .failed)
        #expect((writer.error as NSError?)?.code == -11800)
        #expect(((writer.error as NSError?)?.userInfo[NSUnderlyingErrorKey] as? NSError)?.code == -19649)
    }

    @Test func Writer_Failure_NotifiesWritingToFailed() throws {
        let controller = try createSUT()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try createWriter(url: url)
        let transitions = Mutex<[(Bool, AVAssetWriter.Status)]>([])
        let observation = writer.observe(\.status, options: [.prior]) { writer, change in
            transitions.withLock { $0.append((change.isPrior, writer.status)) }
        }
        defer { observation.invalidate() }
        _ = controller.handle(["kind": "writer", "action": "arm"])

        _ = GMMediaFaults.rejectAppend(writer: writer, mediaType: AVMediaType.video.rawValue)

        let observed = transitions.withLock { $0 }
        #expect(observed.first?.0 == true)
        #expect(observed.first?.1 == .writing)
        #expect(observed.last?.0 == false)
        #expect(observed.last?.1 == .failed)
    }

    private func createSUT() throws -> GMFaultController {
        GMMediaFaults.install(writerErrorCode: -11800, underlyingCode: -19649, exportHooks: true, logger: { _ in })
        let controller = try #require(GMMediaFaults.controller())
        _ = controller.handle(["kind": "writer", "action": "clear"])
        _ = controller.handle(["kind": "export", "action": "clear"])
        return controller
    }

    private func createWriter(url: URL) throws -> AVAssetWriter {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.add(AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 16, AVVideoHeightKey: 16]))
        try #require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        return writer
    }
}
