import Foundation
import Testing
import GeistCam
@testable import GeistLens

@Suite("SessionOrchestrator")
@MainActor
struct SessionOrchestratorTests {
    @Test func handleSocketAppeared_makesSessionViaFactoryAndAttachesSources() async throws {
        let fixture = try OrchestratorFixture.makeWithSinglePreferenceVideoSource()
        let sessionMakerSpy = SessionMakerSpy()
        let orchestrator = fixture.makeOrchestrator(sessionMaker: sessionMakerSpy)
        let entry = fixture.makeSocketEntry()

        orchestrator.handleSocketAppeared(entry)
        await sessionMakerSpy.waitForFirstMake()
        let session = try #require(sessionMakerSpy.lastSession)
        await session.waitForAttachCount(expected: 2, timeout: 1.0)

        #expect(sessionMakerSpy.makeCallCount == 1)
        #expect(sessionMakerSpy.lastSimulatorUDID == fixture.simulatorUDID)
        #expect(sessionMakerSpy.lastBundleID == fixture.bundleID)
        #expect(session.attachCallCount == 2)
        #expect(session.startCallCount == 1)
    }

    @Test func handleSocketAppeared_withMp4Back_routesAudioToBack() async throws {
        let fixture = try OrchestratorFixture.makeWithSinglePreferenceVideoSource()
        let sessionMakerSpy = SessionMakerSpy()
        let orchestrator = fixture.makeOrchestrator(sessionMaker: sessionMakerSpy)
        let entry = fixture.makeSocketEntry()

        orchestrator.handleSocketAppeared(entry)
        await sessionMakerSpy.waitForFirstMake()
        let session = try #require(sessionMakerSpy.lastSession)
        await session.waitForAttachCount(expected: 2, timeout: 1.0)

        let backAttach = try #require(session.attachCalls.first { $0.video == .backCamera })
        let frontAttach = try #require(session.attachCalls.first { $0.video == .frontCamera })
        #expect(backAttach.audio == .microphone)
        #expect(frontAttach.audio == nil)
    }

    @Test func setSource_attachThrowsRecordingInProgress_revertsPreferenceAndShowsAlert() async throws {
        let fixture = try OrchestratorFixture.makeWithSinglePreferenceVideoSource()
        let alertPresenterSpy = AlertPresenterSpy()
        let orchestrator = fixture.makeOrchestrator(
            sessionMaker: AttachThrowsSessionMakerStub(),
            alertPresenter: alertPresenterSpy
        )
        let entry = fixture.makeSocketEntry()
        let originalSource = fixture.preferences.source(
            simulatorUDID: fixture.simulatorUDID,
            bundleID: fixture.bundleID,
            side: .back
        )

        orchestrator.handleSocketAppeared(entry)
        let newPath = try fixture.createTempMp4()
        orchestrator.setSource(.video(path: newPath),
                                 simulatorUDID: fixture.simulatorUDID,
                                 bundleID: fixture.bundleID,
                                 side: .back)
        await alertPresenterSpy.waitForShow(timeout: 2.0)

        #expect(alertPresenterSpy.showCallCount == 1)
        let currentSource = fixture.preferences.source(
            simulatorUDID: fixture.simulatorUDID,
            bundleID: fixture.bundleID,
            side: .back
        )
        #expect(currentSource == originalSource)
    }

    @Test func handleSocketDisappeared_stopsSession() async throws {
        let fixture = try OrchestratorFixture.makeWithSinglePreferenceVideoSource()
        let sessionMakerSpy = SessionMakerSpy()
        let orchestrator = fixture.makeOrchestrator(sessionMaker: sessionMakerSpy)
        let entry = fixture.makeSocketEntry()
        orchestrator.handleSocketAppeared(entry)
        await sessionMakerSpy.waitForFirstMake()
        let session = try #require(sessionMakerSpy.lastSession)
        await session.waitForAttachCount(expected: 2, timeout: 1.0)

        orchestrator.handleSocketDisappeared(entry)
        await session.waitForStop(timeout: 1.0)

        #expect(session.stopCallCount == 1)
    }
}

// MARK: - Fixture

@MainActor
private struct OrchestratorFixture {
    let simulatorUDID = "UDID-SIM-1"
    let bundleID = "com.example.app"
    let preferences: PreferencesStore
    private let tempDir: URL

    static func makeWithSinglePreferenceVideoSource() throws -> OrchestratorFixture {
        let suiteName = "GeistLensTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let preferences = PreferencesStore(defaults: defaults)
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GeistLensTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let videoPath = tempDir.appendingPathComponent("source.mp4").path
        FileManager.default.createFile(atPath: videoPath, contents: Data([0]))
        let udid = "UDID-SIM-1"
        let bundleID = "com.example.app"
        preferences.setSource(.video(path: videoPath),
                                simulatorUDID: udid, bundleID: bundleID, side: .back)
        return OrchestratorFixture(preferences: preferences, tempDir: tempDir)
    }

    func makeSocketEntry() -> SocketWatcher.SocketEntry {
        SocketWatcher.SocketEntry(simulatorUDID: simulatorUDID, bundleID: bundleID, inode: 1)
    }

    func makeOrchestrator(
        sessionMaker: any SessionMaking,
        alertPresenter: (any AlertPresenting)? = nil
    ) -> SessionOrchestrator {
        GlobalPreferences.shared.defaultSource = nil
        return SessionOrchestrator(
            preferences: preferences,
            permissions: PermissionsStub(camera: true, microphone: true),
            mediaSourceFactory: EmptyMediaSourceFactoryStub(),
            sessionMaker: sessionMaker,
            alertPresenter: alertPresenter ?? AlertPresenterSpy()
        )
    }

    func createTempMp4() throws -> String {
        let path = tempDir.appendingPathComponent("replacement-\(UUID().uuidString).mp4").path
        FileManager.default.createFile(atPath: path, contents: Data([0]))
        return path
    }
}

// MARK: - Test Doubles

private struct PermissionsStub: PermissionsQuerying {
    let cameraAuthorized: Bool
    let microphoneAuthorized: Bool

    init(camera: Bool, microphone: Bool) {
        self.cameraAuthorized = camera
        self.microphoneAuthorized = microphone
    }
}

private struct EmptyMediaSourceFactoryStub: MediaSourceConstructing {
    func make(_ persistable: PersistableSource?, wantsAudio: Bool) async -> any MediaSource {
        EmptyMediaSourceStub()
    }
}

private final class EmptyMediaSourceStub: MediaSource, @unchecked Sendable {
    let hasVideo = true
    let hasAudio = false
    let declaredVideoFormat: VideoSlotFormat? = VideoSlotFormat(width: 320, height: 240, pixelFormat: .yuv420FullRange, fps: 30)
    let declaredAudioFormat: AudioSlotFormat? = nil
    func start(into sink: any MediaSink) throws {}
    func stop() {}
    func reformat(to target: VideoSlotFormat) {}
}

private final class SessionMakerSpy: SessionMaking, @unchecked Sendable {
    private let lock = NSLock()
    private var _callCount = 0
    private var _lastSession: SessionDrivingSpy?
    private var _lastUDID: String?
    private var _lastBundleID: String?

    var makeCallCount: Int { lock.lock(); defer { lock.unlock() }; return _callCount }
    var lastSession: SessionDrivingSpy? { lock.lock(); defer { lock.unlock() }; return _lastSession }
    var lastSimulatorUDID: String? { lock.lock(); defer { lock.unlock() }; return _lastUDID }
    var lastBundleID: String? { lock.lock(); defer { lock.unlock() }; return _lastBundleID }

    func make(simulatorUDID: String, bundleID: String,
              delegate: (any GeistCamSessionDelegate)?) -> any SessionDriving {
        let session = SessionDrivingSpy()
        lock.lock()
        _callCount += 1
        _lastSession = session
        _lastUDID = simulatorUDID
        _lastBundleID = bundleID
        lock.unlock()
        return session
    }

    func waitForFirstMake(timeout: TimeInterval = 1.0) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if makeCallCount > 0 { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}

private struct AttachThrowsSessionMakerStub: SessionMaking {
    func make(simulatorUDID: String, bundleID: String,
              delegate: (any GeistCamSessionDelegate)?) -> any SessionDriving {
        AttachThrowsSessionStub()
    }
}

private final class SessionDrivingSpy: SessionDriving, @unchecked Sendable {
    struct AttachCall: Sendable {
        let video: CameraSlot?
        let audio: CameraSlot?
    }

    private let lock = NSLock()
    private var _attachCalls: [AttachCall] = []
    private var _startCount = 0
    private var _stopCount = 0

    var attachCalls: [AttachCall] { lock.lock(); defer { lock.unlock() }; return _attachCalls }
    var attachCallCount: Int { lock.lock(); defer { lock.unlock() }; return _attachCalls.count }
    var startCallCount: Int { lock.lock(); defer { lock.unlock() }; return _startCount }
    var stopCallCount: Int { lock.lock(); defer { lock.unlock() }; return _stopCount }

    func attachMediaSource(_ source: any MediaSource,
                           video: CameraSlot?,
                           audio: CameraSlot?) async throws(SourceSwitchError) {
        lock.lock()
        _attachCalls.append(AttachCall(video: video, audio: audio))
        lock.unlock()
    }

    func start(connectTimeout: TimeInterval) async throws {
        lock.lock(); defer { lock.unlock() }
        _startCount += 1
    }

    func stop() async {
        lock.lock(); defer { lock.unlock() }
        _stopCount += 1
    }

    func waitForAttachCount(expected: Int, timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if attachCallCount >= expected { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func waitForStop(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if stopCallCount > 0 { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}

private final class AttachThrowsSessionStub: SessionDriving, @unchecked Sendable {
    func attachMediaSource(_ source: any MediaSource,
                           video: CameraSlot?,
                           audio: CameraSlot?) async throws(SourceSwitchError) {
        throw .recordingInProgress
    }

    func start(connectTimeout: TimeInterval) async throws {}
    func stop() async {}
}

@MainActor
private final class AlertPresenterSpy: AlertPresenting {
    private var _showCallCount = 0

    var showCallCount: Int { _showCallCount }

    func showRecordingInProgress() {
        _showCallCount += 1
    }

    func waitForShow(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if _showCallCount > 0 { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}
