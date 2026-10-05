import Foundation
import Synchronization

/// One feeder session per app launch. Typical setup:
/// ```swift
/// let session = GeistCamSession(delegate: self)
/// try await session.attach(.stillImage(stimURL), to: .backCamera)
/// try await launcher.launch(app, env: session.injectionEnv())
/// try await session.start()
/// ```
/// Call `stop()` when done; the session does not clean up on deinit.
public actor GeistCamSession: SessionDriving {
    public enum State: Sendable { case idle, listening, connected, stopped }

    public private(set) weak var delegate: (any GeistCamSessionDelegate)?

    private nonisolated let socketPath: String
    private nonisolated let shimDylibPath: String?
    private nonisolated let shimLogPath: String?
    private let demandRegistry = DemandRegistry()
    private lazy var hostDetector: HostDetector = {
        HostDetector { [weak self] results in
            Task { await self?.sendMetadataResults(results) }
        }
    }()

    private lazy var sources = CameraSourceRegistry(
        demandRegistry: demandRegistry, hostDetector: hostDetector, heartbeat: heartbeat
    )

    private let heartbeat = FrameHeartbeat()
    private var streamingWatchdog: Task<Void, Never>?
    private var isStreaming: Bool = false
    private var client: SocketClient?
    private var inboundTask: Task<Void, Never>?
    private var pendingControlRequests: [String: CheckedContinuation<Data, Error>] = [:]
    public private(set) var state: State = .idle
    private nonisolated let isRecording = Atomic<Bool>(false)

    public init(delegate: (any GeistCamSessionDelegate)? = nil,
                shimDylibPath: String? = nil, shimLogPath: String? = nil) {
        let uuid = UUID().uuidString.lowercased()
        let tmpDir = NSTemporaryDirectory()
        self.socketPath = (tmpDir as NSString).appendingPathComponent("geistcam-\(uuid).sock")
        self.delegate = delegate
        self.shimDylibPath = shimDylibPath
        self.shimLogPath = shimLogPath
    }

    public init(socketPath: String,
                delegate: (any GeistCamSessionDelegate)? = nil,
                shimDylibPath: String? = nil, shimLogPath: String? = nil) {
        self.socketPath = socketPath
        self.delegate = delegate
        self.shimDylibPath = shimDylibPath
        self.shimLogPath = shimLogPath
    }

    public init(simulator: String, bundleID: String,
                delegate: (any GeistCamSessionDelegate)? = nil,
                shimDylibPath: String? = nil, shimLogPath: String? = nil) {
        let path = Self.conventionalSocketPath(simulator: simulator, bundleID: bundleID)
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir,
                                                  withIntermediateDirectories: true)
        self.socketPath = path
        self.delegate = delegate
        self.shimDylibPath = shimDylibPath
        self.shimLogPath = shimLogPath
    }

    // Must match Server.m:resolveSocketPath fallback when GEISTCAM_SOCKET unset.
    public nonisolated static func conventionalSocketPath(simulator: String, bundleID: String) -> String {
        "/tmp/geistcam/\(simulator)/\(bundleID).sock"
    }

    public nonisolated func injectionEnv() -> [String: String] {
        let dylib = shimDylibPath
            ?? ProcessInfo.processInfo.environment["GEISTCAM_SHIM_DYLIB"]
            ?? GeistCamShimBundled.dylibPath
        var env: [String: String] = [
            "DYLD_INSERT_LIBRARIES": dylib,
            "GEISTCAM_SOCKET": socketPath,
        ]
        if let logPath = shimLogPath {
            env["GEISTCAM_LOG"] = logPath
        }
        return env
    }

    public func attach(_ source: GeistCamSource, to slot: CameraSlot) async throws(SourceSwitchError) {
        if isRecording.load(ordering: .relaxed) {
            throw .recordingInProgress
        }
        guard slot.wireIndex != nil else {
            log.warn("slot \(slot.debugLabel) not supported by v1 shim — ignored")
            return
        }
        guard let producer = await makeProducer(for: source, slot: slot) else {
            return
        }
        // Reentrancy: stop() may have run during the async makeProducer above.
        guard state != .stopped else {
            producer.stop()
            return
        }
        sources.attach(producer, to: slot)
    }

    public func detach(_ slot: CameraSlot) throws(SourceSwitchError) {
        if isRecording.load(ordering: .relaxed) {
            throw .recordingInProgress
        }
        sources.detach(slot)
    }

    /// Attach a paired-stream source. The source is started exactly once and
    /// fans video/audio out to whichever of the named slots are currently
    /// wanted by the shim. Owning a media source on a slot evicts any prior
    /// producer or media source registered for that slot — including, for
    /// paired sources, eviction of the partner slot.
    public func attachMediaSource(_ source: any MediaSource,
                                  video videoSlot: CameraSlot? = nil,
                                  audio audioSlot: CameraSlot? = nil) async throws(SourceSwitchError) {
        if isRecording.load(ordering: .relaxed) {
            throw .recordingInProgress
        }
        sources.attachMediaSource(source, video: videoSlot, audio: audioSlot, isStopped: state == .stopped)
    }

    public func start(connectTimeout: TimeInterval = 10) async throws {
        guard state == .idle else { throw GeistCamError.alreadyStarted }
        state = .listening
        let sourcesSnapshot = sources.snapshot()

        let client = SocketClient(path: socketPath)
        try await client.connect(timeout: connectTimeout)

        // Reentrancy: stop() could have run during the await above.
        if state != .listening {
            client.close()
            throw GeistCamError.stoppedDuringStart
        }

        self.client = client
        state = .connected

        delegate?.sessionDidConnect(self)
        sources.connect(client, snapshot: sourcesSnapshot)
        startInboundTask(client: client)
        startStreamingWatchdog()
    }

    public func stop() {
        state = .stopped
        cleanUpConnection(client: client, inboundTask: inboundTask)
    }

    public func cameraStatus() async throws -> CameraStatusSnapshot {
        let data = try await control(command: "status")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        do {
            return try decoder.decode(CameraStatusSnapshot.self, from: data)
        } catch {
            throw CameraControlError(
                message: "Camera status response was invalid: \(error). Payload: \(String(decoding: data, as: UTF8.self))"
            )
        }
    }

    public func endInterruption(session: String?) async throws -> CameraInterruptionChange {
        let data = try await control(command: "endInterruption", session: session)
        return try JSONDecoder().decode(CameraInterruptionChange.self, from: data)
    }

    public func interrupt(
        reason: CameraInterruptionReason,
        session: String?
    ) async throws -> CameraInterruptionChange {
        let data = try await control(
            command: "interrupt",
            reason: reason.rawAVFoundationValue,
            session: session
        )
        return try JSONDecoder().decode(CameraInterruptionChange.self, from: data)
    }

    private func control(command: String, reason: Int? = nil, session: String? = nil) async throws -> Data {
        guard let client else { throw GeistCamError.notStarted }
        let requestID = UUID().uuidString
        var request: [String: Any] = ["command": command, "requestID": requestID]
        if let reason { request["reason"] = reason }
        if let session { request["session"] = session }
        let payload = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        return try await withCheckedThrowingContinuation { continuation in
            pendingControlRequests[requestID] = continuation
            let admission = client.send(.reliable(type: .controlRequest, payload: payload))
            guard admission == .accepted else {
                pendingControlRequests.removeValue(forKey: requestID)
                continuation.resume(throwing: GeistCamError.notStarted)
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                await self?.timeOutControl(requestID)
            }
        }
    }

    private func timeOutControl(_ requestID: String) {
        pendingControlRequests.removeValue(forKey: requestID)?.resume(
            throwing: CameraControlError(message: "Camera control request timed out")
        )
    }

    private func cleanUpConnection(client: SocketClient?, inboundTask: Task<Void, Never>?) {
        let controls = pendingControlRequests.values
        pendingControlRequests.removeAll()
        for control in controls {
            control.resume(throwing: GeistCamError.notStarted)
        }
        self.client = nil
        self.inboundTask = nil
        sources.disconnect()
        inboundTask?.cancel()
        client?.close()
        stopStreamingWatchdog()
    }

    private func startStreamingWatchdog() {
        streamingWatchdog?.cancel()
        let heartbeat = self.heartbeat
        streamingWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                if Task.isCancelled { break }
                guard let self else { break }
                let last = heartbeat.read()
                let now = DispatchTime.now().uptimeNanoseconds
                let active = (last > 0) && (now &- last < 1_000_000_000)
                await self.applyStreamingState(active)
            }
        }
    }

    private func stopStreamingWatchdog() {
        streamingWatchdog?.cancel()
        streamingWatchdog = nil
        if isStreaming {
            isStreaming = false
            delegate?.session(self, isStreamingChanged: false)
        }
    }

    private func applyStreamingState(_ active: Bool) {
        if active == isStreaming { return }
        isStreaming = active
        delegate?.session(self, isStreamingChanged: active)
    }

    private func makeProducer(for source: GeistCamSource, slot: CameraSlot) async -> CameraSourceRegistry.Producer? {
        let isAudioSlot = (slot == .microphone)
        switch source {
        case .customVideo(let p):
            guard !isAudioSlot else {
                log.warn("video producer attached to audio slot '\(slot.debugLabel)' — ignored")
                return nil
            }
            return .video(p)
        case .customAudio(let p):
            guard isAudioSlot else {
                log.warn("audio producer attached to video slot '\(slot.debugLabel)' — ignored")
                return nil
            }
            return .audio(p)
        case .macOSCamera(let spec):
            guard !isAudioSlot else {
                log.warn("macOSCamera attached to audio slot '\(slot.debugLabel)' — use .macOSMicrophone for audio")
                return nil
            }
            do {
                return .video(try await SharedMacOSCameraSource.producer(device: spec))
            } catch {
                log.warn("macOS camera init failed: \(error)")
                return nil
            }
        case .macOSMicrophone(let spec):
            guard isAudioSlot else {
                log.warn("macOSMicrophone attached to video slot '\(slot.debugLabel)' — use .macOSCamera for video")
                return nil
            }
            do {
                return .audio(try await MacOSMicrophoneProducer(spec))
            } catch {
                log.warn("MacOSMicrophoneProducer init failed: \(error)")
                return nil
            }
        case .stillImage(let url, let fps):
            guard !isAudioSlot else {
                log.warn("stillImage attached to audio slot '\(slot.debugLabel)' — ignored")
                return nil
            }
            do {
                return .video(try StillImageProducer(url: url, fps: fps))
            } catch {
                log.warn("StillImageProducer init failed for \(url.lastPathComponent): \(error)")
                return nil
            }
        }
    }

    private func startInboundTask(client: SocketClient) {
        inboundTask = Task { [weak self] in
            for await msg in client.inbound {
                await self?.handleInbound(msg)
            }
            await self?.handleDisconnected(client: client)
        }
    }

    private func handleInbound(_ msg: SocketClient.InboundMessage) {
        switch msg.type {
        case .helloAck:
            guard let ack = WireHelloAck.decode(msg.payload) else { return }
            log.notice("HELLO_ACK version=\(ack.version) initial_active=\(ack.initialActive)")
            for (idx, active) in ack.initialActive.enumerated() {
                applySlotActive(wireIndex: UInt32(idx), active: active != 0)
            }
        case .slotActive:
            guard let m = WireSlotActive.decode(msg.payload) else { return }
            log.notice("SLOT_ACTIVE slot=\(m.slot) active=\(m.active)")
            applySlotActive(wireIndex: m.slot, active: m.active != 0)
        case .demandUpdate:
            guard let m = WireDemandUpdate.decode(msg.payload) else { return }
            let demand = SlotDemand(wantsQR: m.wantsQR != 0, wantsFace: m.wantsFace != 0)
            log.notice("DEMAND_UPDATE slot=\(m.slot) qr=\(demand.wantsQR) face=\(demand.wantsFace)")
            demandRegistry.update(slot: m.slot, demand: demand)
        case .recordingState:
            guard let m = WireRecordingState.decode(msg.payload) else { return }
            let recording = m.active != 0
            log.notice("RECORDING_STATE → \(recording ? "active" : "idle")")
            isRecording.store(recording, ordering: .relaxed)
        case .activeFormat:
            guard let m = WireActiveFormat.decode(msg.payload) else { return }
            sources.updateActiveFormat(m)
        case .controlResponse:
            handleControlResponse(msg.payload)
        default:
            log.warn("unexpected inbound message \(msg.type)")
        }
    }

    private func handleControlResponse(_ payload: Data) {
        guard
            let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
            let requestID = object["requestID"] as? String,
            let continuation = pendingControlRequests.removeValue(forKey: requestID)
        else { return }
        if let error = object["error"] as? String {
            continuation.resume(throwing: CameraControlError(message: error))
            return
        }
        guard
            let dataObject = object["data"],
            let data = try? JSONSerialization.data(withJSONObject: dataObject, options: [.sortedKeys])
        else {
            continuation.resume(throwing: CameraControlError(message: "Camera control response had no data"))
            return
        }
        continuation.resume(returning: data)
    }

    private func applySlotActive(wireIndex: UInt32, active: Bool) {
        if let missingSlot = sources.setSlotActive(wireIndex: wireIndex, active: active) {
            delegate?.session(self, didActivateSlotWithoutSource: missingSlot)
        }
    }

    private func sendMetadataResults(_ results: WireMetadataResults) {
        guard let client else { return }
        _ = client.send(.reliable(type: .metadataResults, payload: results.encoded()))
    }

    private func handleDisconnected(client disconnectedClient: SocketClient) {
        if client === disconnectedClient {
            state = .stopped
            cleanUpConnection(client: disconnectedClient, inboundTask: inboundTask)
        }
        delegate?.sessionDidDisconnect(self)
    }

}
