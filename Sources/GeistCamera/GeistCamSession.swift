import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Synchronization
import GeistKit

public enum GeistCamError: Error {
    case slotNotSupported(CameraSlot)
    case notStarted
    case alreadyStarted
    case stoppedDuringStart
}

public enum SourceSwitchError: Error {
    case recordingInProgress
}

public protocol GeistCamSessionDelegate: AnyObject, Sendable {
    func sessionDidConnect(_ session: GeistCamSession)
    func sessionDidDisconnect(_ session: GeistCamSession)
    func session(_ session: GeistCamSession, didActivateSlotWithoutSource slot: CameraSlot)
    func session(_ session: GeistCamSession, isStreamingChanged isStreaming: Bool)
}

public protocol SessionDriving: AnyObject, Sendable {
    func attachMediaSource(_ source: any MediaSource,
                           video: CameraSlot?,
                           audio: CameraSlot?) async throws(SourceSwitchError)
    func start(connectTimeout: TimeInterval) async throws
    func stop() async
}

public extension GeistCamSessionDelegate {
    func sessionDidConnect(_ session: GeistCamSession) {}
    func sessionDidDisconnect(_ session: GeistCamSession) {}
    func session(_ session: GeistCamSession, didActivateSlotWithoutSource slot: CameraSlot) {}
    func session(_ session: GeistCamSession, isStreamingChanged isStreaming: Bool) {}
}

/// One feeder session per app launch. Typical setup:
/// ```swift
/// let session = GeistCamSession(delegate: self)
/// await session.attach(.video(stimURL), to: .backCamera)
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

    fileprivate enum AnyProducer {
        case video(any VideoFrameProducer)
        case audio(any AudioFrameProducer)

        func stop() {
            switch self {
            case .video(let p): p.stop()
            case .audio(let p): p.stop()
            }
        }
    }

    fileprivate final class MediaSourceRegistration {
        let source: any MediaSource
        let videoSlot: CameraSlot?
        let audioSlot: CameraSlot?
        let fanout: FanoutMediaSink
        var videoSink: VideoSlotBoundSink?
        var audioSink: AudioSlotBoundSink?
        var running: Bool = false

        init(source: any MediaSource, video: CameraSlot?, audio: CameraSlot?) {
            self.source = source
            self.videoSlot = video
            self.audioSlot = audio
            self.fanout = FanoutMediaSink()
        }
    }

    private var producers: [CameraSlot: AnyProducer] = [:]
    private var videoSinks: [CameraSlot: VideoSlotBoundSink] = [:]
    private var lastActiveFormat: [CameraSlot: VideoSlotFormat] = [:]
    private var runningProducers: Set<CameraSlot> = []
    private var mediaSources: [ObjectIdentifier: MediaSourceRegistration] = [:]
    private var slotToMediaSource: [CameraSlot: ObjectIdentifier] = [:]

    private let heartbeat = FrameHeartbeat()
    private var streamingWatchdog: Task<Void, Never>?
    private var isStreaming: Bool = false
    // Decoupled from `runningProducers` so detach→reattach restarts
    // the new producer when the shim still wants frames.
    private var slotsWantedByShim: Set<CameraSlot> = []
    private var loggedActivationsWithoutSource: Set<CameraSlot> = []
    private var client: SocketClient?
    private var inboundTask: Task<Void, Never>?
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
            Log.warn("slot \(slot.debugLabel) not supported by v1 shim — ignored")
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
        if runningProducers.contains(slot), let prev = producers[slot] {
            prev.stop()
            runningProducers.remove(slot)
        }
        producers[slot] = producer
        let shouldStart = slotsWantedByShim.contains(slot) && client != nil
        if shouldStart {
            startProducer(producer, for: slot)
        }
    }

    public func detach(_ slot: CameraSlot) throws(SourceSwitchError) {
        if isRecording.load(ordering: .relaxed) {
            throw .recordingInProgress
        }
        if let id = slotToMediaSource[slot] {
            evictMediaSource(id)
            return
        }
        let p = producers.removeValue(forKey: slot)
        videoSinks.removeValue(forKey: slot)
        if runningProducers.remove(slot) != nil {
            p?.stop()
        }
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
        if videoSlot == nil && audioSlot == nil {
            Log.warn("attachMediaSource called with no slots")
            return
        }
        if let v = videoSlot, v.wireIndex == nil {
            Log.warn("attachMediaSource: video slot \(v.debugLabel) not supported by v1 shim")
            return
        }
        if let a = audioSlot, a.wireIndex == nil {
            Log.warn("attachMediaSource: audio slot \(a.debugLabel) not supported by v1 shim")
            return
        }

        // Evict any prior owners of the requested slots.
        var evicting: Set<ObjectIdentifier> = []
        if let v = videoSlot, let id = slotToMediaSource[v] { evicting.insert(id) }
        if let a = audioSlot, let id = slotToMediaSource[a] { evicting.insert(id) }
        for id in evicting { evictMediaSource(id) }

        for slot in [videoSlot, audioSlot].compactMap({ $0 }) {
            if let p = producers.removeValue(forKey: slot) {
                videoSinks.removeValue(forKey: slot)
                if runningProducers.remove(slot) != nil { p.stop() }
            }
        }

        let reg = MediaSourceRegistration(source: source, video: videoSlot, audio: audioSlot)
        let id = ObjectIdentifier(reg)
        mediaSources[id] = reg
        if let v = videoSlot { slotToMediaSource[v] = id }
        if let a = audioSlot { slotToMediaSource[a] = id }

        // Reentrancy: stop() may have run during the async makeProducer-free path
        // is gone, but we keep the guard for symmetry with attach().
        guard state != .stopped else {
            evictMediaSource(id)
            return
        }

        // The initial HELLO usually fires before the orchestrator attaches any
        // MediaSource, so the shim's per-slot info (format, features) is
        // empty. Re-publish whenever sources change so the shim sees current
        // declared formats and feature flags.
        if let client = self.client {
            sendHello(producers: producers, media: Array(mediaSources.values), client: client)
        }

        let anyWanted = (videoSlot.map { slotsWantedByShim.contains($0) } ?? false)
                     || (audioSlot.map { slotsWantedByShim.contains($0) } ?? false)
        if anyWanted, let client = self.client {
            startMediaSource(reg, client: client)
        }
    }

    private func evictMediaSource(_ id: ObjectIdentifier) {
        guard let reg = mediaSources.removeValue(forKey: id) else { return }
        if let v = reg.videoSlot {
            slotToMediaSource.removeValue(forKey: v)
            videoSinks.removeValue(forKey: v)
            runningProducers.remove(v)
        }
        if let a = reg.audioSlot {
            slotToMediaSource.removeValue(forKey: a)
            runningProducers.remove(a)
        }
        reg.fanout.setVideoSink(nil)
        reg.fanout.setAudioSink(nil)
        if reg.running {
            reg.source.stop()
        }
    }

    private func startMediaSource(_ reg: MediaSourceRegistration, client: SocketClient) {
        if reg.running { return }
        if let v = reg.videoSlot, let idx = v.wireIndex, slotsWantedByShim.contains(v) {
            bindVideoSlot(reg: reg, slot: v, wireIndex: idx, client: client)
        }
        if let a = reg.audioSlot, let idx = a.wireIndex, slotsWantedByShim.contains(a) {
            bindAudioSlot(reg: reg, slot: a, wireIndex: idx, client: client)
        }
        do {
            try reg.source.start(into: reg.fanout)
            reg.running = true
            if let v = reg.videoSlot, reg.videoSink != nil { runningProducers.insert(v) }
            if let a = reg.audioSlot, reg.audioSink != nil { runningProducers.insert(a) }
            if let v = reg.videoSlot, let af = lastActiveFormat[v] {
                reg.source.reformat(to: af)
            }
            Log.notice("started media source: video=\(reg.videoSlot?.debugLabel ?? "-") audio=\(reg.audioSlot?.debugLabel ?? "-")")
        } catch {
            Log.warn("media source failed to start: \(error)")
            reg.fanout.setVideoSink(nil)
            reg.fanout.setAudioSink(nil)
            reg.videoSink = nil
            reg.audioSink = nil
        }
    }

    private func bindVideoSlot(reg: MediaSourceRegistration, slot: CameraSlot, wireIndex idx: UInt32, client: SocketClient) {
        let initialFormat = lastActiveFormat[slot]
            ?? reg.source.declaredVideoFormat
            ?? VideoSlotFormat(width: 1280, height: 720, pixelFormat: .yuv420FullRange, fps: 30)
        let socketSink = VideoSlotBoundSink(wireIndex: idx, declaredFormat: initialFormat, client: client, heartbeat: heartbeat)
        let routed = DetectionRouter(slot: idx, downstream: socketSink, demand: demandRegistry, detector: hostDetector)
        reg.fanout.setVideoSink(routed)
        reg.videoSink = socketSink
        videoSinks[slot] = socketSink
    }

    private func bindAudioSlot(reg: MediaSourceRegistration, slot: CameraSlot, wireIndex idx: UInt32, client: SocketClient) {
        let format = reg.source.declaredAudioFormat ?? AudioSlotFormat(sampleRate: 48000, channels: 1)
        let sink = AudioSlotBoundSink(wireIndex: idx, declaredFormat: format, client: client, heartbeat: heartbeat)
        reg.fanout.setAudioSink(sink)
        reg.audioSink = sink
    }

    private func stopMediaSource(_ reg: MediaSourceRegistration) {
        reg.fanout.setVideoSink(nil)
        reg.fanout.setAudioSink(nil)
        reg.videoSink = nil
        reg.audioSink = nil
        if let v = reg.videoSlot {
            runningProducers.remove(v)
            videoSinks.removeValue(forKey: v)
        }
        if let a = reg.audioSlot { runningProducers.remove(a) }
        if reg.running {
            reg.source.stop()
            reg.running = false
        }
    }

    public func start(connectTimeout: TimeInterval = 10) async throws {
        guard state == .idle else { throw GeistCamError.alreadyStarted }
        state = .listening
        let producersSnapshot = producers
        let mediaSnapshot = Array(mediaSources.values)

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
        sendHello(producers: producersSnapshot, media: mediaSnapshot, client: client)
        startInboundTask(client: client)
        startStreamingWatchdog()
    }

    public func stop() {
        let active = runningProducers
        let prods = producers
        let media = Array(mediaSources.values)
        let cl = client
        let task = inboundTask
        client = nil
        inboundTask = nil
        runningProducers.removeAll()
        state = .stopped
        for slot in active { prods[slot]?.stop() }
        for reg in media { stopMediaSource(reg) }
        task?.cancel()
        cl?.close()
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

    private func makeProducer(for source: GeistCamSource, slot: CameraSlot) async -> AnyProducer? {
        let isAudioSlot = (slot == .microphone)
        switch source {
        case .customVideo(let p):
            guard !isAudioSlot else {
                Log.warn("video producer attached to audio slot '\(slot.debugLabel)' — ignored")
                return nil
            }
            return .video(p)
        case .customAudio(let p):
            guard isAudioSlot else {
                Log.warn("audio producer attached to video slot '\(slot.debugLabel)' — ignored")
                return nil
            }
            return .audio(p)
        case .macOSCamera(let spec):
            guard !isAudioSlot else {
                Log.warn("macOSCamera attached to audio slot '\(slot.debugLabel)' — use .macOSMicrophone for audio")
                return nil
            }
            do {
                return .video(try await SharedMacOSCameraSource.producer(device: spec))
            } catch {
                Log.warn("macOS camera init failed: \(error)")
                return nil
            }
        case .macOSMicrophone(let spec):
            guard isAudioSlot else {
                Log.warn("macOSMicrophone attached to video slot '\(slot.debugLabel)' — use .macOSCamera for video")
                return nil
            }
            do {
                return .audio(try await MacOSMicrophoneProducer(spec))
            } catch {
                Log.warn("MacOSMicrophoneProducer init failed: \(error)")
                return nil
            }
        case .stillImage(let url, let fps):
            guard !isAudioSlot else {
                Log.warn("stillImage attached to audio slot '\(slot.debugLabel)' — ignored")
                return nil
            }
            do {
                return .video(try StillImageProducer(url: url, fps: fps))
            } catch {
                Log.warn("StillImageProducer init failed for \(url.lastPathComponent): \(error)")
                return nil
            }
        }
    }

    private func sendHello(producers: [CameraSlot: AnyProducer],
                            media: [MediaSourceRegistration],
                            client: SocketClient) {
        var slots: [WireSlotInfo] = []
        for (slot, producer) in producers {
            guard let idx = slot.wireIndex else { continue }
            switch producer {
            case .video(let p):
                let f = p.declaredFormat
                slots.append(WireSlotInfo(
                    kind: UInt32(idx),
                    width: UInt32(f.width), height: UInt32(f.height),
                    pixelFormat: f.pixelFormat.osType,
                    fpsNum: UInt32(f.fps), fpsDen: 1,
                    features: 0
                ))
            case .audio(let p):
                let f = p.declaredFormat
                slots.append(WireSlotInfo(
                    kind: UInt32(idx),
                    width: 0, height: UInt32(f.channels),
                    pixelFormat: 0,
                    fpsNum: UInt32(f.sampleRate), fpsDen: 1,
                    features: 0
                ))
            }
        }
        for reg in media {
            let features = reg.source.features.rawValue
            if let v = reg.videoSlot, let idx = v.wireIndex, let f = reg.source.declaredVideoFormat {
                slots.append(WireSlotInfo(
                    kind: UInt32(idx),
                    width: UInt32(f.width), height: UInt32(f.height),
                    pixelFormat: f.pixelFormat.osType,
                    fpsNum: UInt32(f.fps), fpsDen: 1,
                    features: features
                ))
            }
            if let a = reg.audioSlot, let idx = a.wireIndex, let f = reg.source.declaredAudioFormat {
                slots.append(WireSlotInfo(
                    kind: UInt32(idx),
                    width: 0, height: UInt32(f.channels),
                    pixelFormat: 0,
                    fpsNum: UInt32(f.sampleRate), fpsDen: 1,
                    features: features
                ))
            }
        }
        let hello = WireHello(slots: slots)
        client.send(Data.framed(.hello, payload: hello.encoded()))
    }

    private func startInboundTask(client: SocketClient) {
        inboundTask = Task { [weak self] in
            for await msg in client.inbound {
                await self?.handleInbound(msg)
            }
            await self?.handleDisconnected()
        }
    }

    private func handleInbound(_ msg: SocketClient.InboundMessage) {
        switch msg.type {
        case .helloAck:
            guard let ack = WireHelloAck.decode(msg.payload) else { return }
            Log.notice("HELLO_ACK version=\(ack.version) initial_active=\(ack.initialActive)")
            for (idx, active) in ack.initialActive.enumerated() {
                applySlotActive(wireIndex: UInt32(idx), active: active != 0)
            }
        case .slotActive:
            guard let m = WireSlotActive.decode(msg.payload) else { return }
            Log.notice("SLOT_ACTIVE slot=\(m.slot) active=\(m.active)")
            applySlotActive(wireIndex: m.slot, active: m.active != 0)
        case .demandUpdate:
            guard let m = WireDemandUpdate.decode(msg.payload) else { return }
            let demand = SlotDemand(wantsQR: m.wantsQR != 0, wantsFace: m.wantsFace != 0)
            Log.notice("DEMAND_UPDATE slot=\(m.slot) qr=\(demand.wantsQR) face=\(demand.wantsFace)")
            demandRegistry.update(slot: m.slot, demand: demand)
        case .recordingState:
            guard let m = WireRecordingState.decode(msg.payload) else { return }
            let recording = m.active != 0
            Log.notice("RECORDING_STATE → \(recording ? "active" : "idle")")
            isRecording.store(recording, ordering: .relaxed)
        case .activeFormat:
            guard let m = WireActiveFormat.decode(msg.payload) else { return }
            handleActiveFormatChanged(m)
        default:
            Log.warn("unexpected inbound message \(msg.type)")
        }
    }

    private func handleActiveFormatChanged(_ m: WireActiveFormat) {
        let slot = slotForWireIndex(m.slot)
        guard let pixfmt = PixelFormat(osType: m.pixelFormat) else {
            Log.warn("ACTIVE_FORMAT slot=\(m.slot): unsupported pixfmt 0x\(String(m.pixelFormat, radix: 16))")
            return
        }
        let fps: Int
        if case .video(let p) = producers[slot] {
            fps = p.declaredFormat.fps
        } else if let id = slotToMediaSource[slot],
                  let reg = mediaSources[id],
                  let dvf = reg.source.declaredVideoFormat {
            fps = dvf.fps
        } else {
            fps = 30
        }
        let target = VideoSlotFormat(width: Int(m.width), height: Int(m.height),
                                     pixelFormat: pixfmt, fps: fps)
        Log.notice("ACTIVE_FORMAT slot=\(slot.debugLabel) → \(m.width)x\(m.height) \(pixfmt)")
        lastActiveFormat[slot] = target
        videoSinks[slot]?.updateExpectedFormat(target)
        if case .video(let p) = producers[slot] {
            p.reformat(to: target)
        }
        if let id = slotToMediaSource[slot], let reg = mediaSources[id] {
            reg.source.reformat(to: target)
        }
    }

    private func applySlotActive(wireIndex: UInt32, active: Bool) {
        let slot = slotForWireIndex(wireIndex)
        if active { slotsWantedByShim.insert(slot) } else { slotsWantedByShim.remove(slot) }

        if let id = slotToMediaSource[slot], let reg = mediaSources[id] {
            handleMediaSlotActive(reg: reg, slot: slot, active: active)
            return
        }

        let producer = producers[slot]
        let alreadyRunning = runningProducers.contains(slot)
        let shouldLogMissing = active && producer == nil && !loggedActivationsWithoutSource.contains(slot)
        if shouldLogMissing { loggedActivationsWithoutSource.insert(slot) }

        if shouldLogMissing {
            Log.notice("slot '\(slot.debugLabel)' activated with no source — preview will be blank")
            delegate?.session(self, didActivateSlotWithoutSource: slot)
        }
        guard let producer else { return }
        if active && !alreadyRunning {
            startProducer(producer, for: slot)
        } else if !active && alreadyRunning {
            stopProducer(producer, for: slot)
        }
    }

    private func handleMediaSlotActive(reg: MediaSourceRegistration, slot: CameraSlot, active: Bool) {
        guard let client else { return }
        let isVideo = (slot == reg.videoSlot)
        let isAudio = (slot == reg.audioSlot)
        if active {
            if !reg.running {
                startMediaSource(reg, client: client)
                return
            }
            if isVideo, reg.videoSink == nil, let idx = slot.wireIndex {
                bindVideoSlot(reg: reg, slot: slot, wireIndex: idx, client: client)
                runningProducers.insert(slot)
                if let af = lastActiveFormat[slot] { reg.source.reformat(to: af) }
            }
            if isAudio, reg.audioSink == nil, let idx = slot.wireIndex {
                bindAudioSlot(reg: reg, slot: slot, wireIndex: idx, client: client)
                runningProducers.insert(slot)
            }
        } else {
            if isVideo {
                reg.fanout.setVideoSink(nil)
                reg.videoSink = nil
                videoSinks.removeValue(forKey: slot)
                runningProducers.remove(slot)
            }
            if isAudio {
                reg.fanout.setAudioSink(nil)
                reg.audioSink = nil
                runningProducers.remove(slot)
            }
            if reg.videoSink == nil && reg.audioSink == nil {
                stopMediaSource(reg)
            }
        }
    }

    private func startProducer(_ producer: AnyProducer, for slot: CameraSlot) {
        guard let idx = slot.wireIndex else { return }
        guard let client else { return }
        do {
            switch producer {
            case .video(let p):
                let initialFormat = lastActiveFormat[slot] ?? p.declaredFormat
                let socketSink = VideoSlotBoundSink(wireIndex: idx, declaredFormat: initialFormat, client: client, heartbeat: heartbeat)
                videoSinks[slot] = socketSink
                let routedSink = DetectionRouter(slot: idx,
                                                  downstream: socketSink,
                                                  demand: demandRegistry,
                                                  detector: hostDetector)
                try p.start(into: routedSink)
                if let af = lastActiveFormat[slot] {
                    p.reformat(to: af)
                }
            case .audio(let p):
                let sink = AudioSlotBoundSink(wireIndex: idx, declaredFormat: p.declaredFormat, client: client, heartbeat: heartbeat)
                try p.start(into: sink)
            }
            runningProducers.insert(slot)
            Log.notice("started producer for \(slot.debugLabel)")
        } catch {
            Log.warn("producer failed to start for \(slot.debugLabel): \(error)")
        }
    }

    private func sendMetadataResults(_ results: WireMetadataResults) {
        guard let client else { return }
        client.send(Data.framed(.metadataResults, payload: results.encoded()))
    }

    private func stopProducer(_ producer: AnyProducer, for slot: CameraSlot) {
        producer.stop()
        runningProducers.remove(slot)
        videoSinks.removeValue(forKey: slot)
        Log.notice("stopped producer for \(slot.debugLabel)")
    }

    private func handleDisconnected() {
        let active = runningProducers
        let prods = producers
        let media = Array(mediaSources.values)
        runningProducers.removeAll()
        state = .stopped
        for slot in active { prods[slot]?.stop() }
        for reg in media { stopMediaSource(reg) }
        stopStreamingWatchdog()
        delegate?.sessionDidDisconnect(self)
    }

    private nonisolated func slotForWireIndex(_ idx: UInt32) -> CameraSlot {
        switch idx {
        case 0: return .backCamera
        case 1: return .frontCamera
        case 2: return .microphone
        default: return .backCamera
        }
    }
}
