import Foundation

// Owned and accessed exclusively by GeistCamSession's actor executor.
final class CameraSourceRegistry {
    enum Producer {
        case video(any VideoFrameProducer)
        case audio(any AudioFrameProducer)

        func stop() {
            switch self {
            case .video(let producer): producer.stop()
            case .audio(let producer): producer.stop()
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

    private var producers: [CameraSlot: Producer] = [:]
    private var videoSinks: [CameraSlot: VideoSlotBoundSink] = [:]
    private var lastActiveFormat: [CameraSlot: VideoSlotFormat] = [:]
    private var runningProducers: Set<CameraSlot> = []
    private var mediaSources: [ObjectIdentifier: MediaSourceRegistration] = [:]
    private var slotToMediaSource: [CameraSlot: ObjectIdentifier] = [:]

    private let demandRegistry: DemandRegistry
    private let hostDetector: any HostDetecting
    private let heartbeat: FrameHeartbeat
    // Slot demand survives source replacement so a replacement starts immediately.
    private var slotsWantedByShim: Set<CameraSlot> = []
    private var loggedActivationsWithoutSource: Set<CameraSlot> = []
    private var client: SocketClient?

    init(demandRegistry: DemandRegistry, hostDetector: any HostDetecting, heartbeat: FrameHeartbeat) {
        self.demandRegistry = demandRegistry
        self.hostDetector = hostDetector
        self.heartbeat = heartbeat
    }

    // Registrations retain their identity while socket connection suspends the session.
    struct Snapshot {
        fileprivate let producers: [CameraSlot: Producer]
        fileprivate let media: [MediaSourceRegistration]
    }

    func snapshot() -> Snapshot {
        Snapshot(producers: producers, media: Array(mediaSources.values))
    }

    func connect(_ client: SocketClient, snapshot: Snapshot) {
        self.client = client
        sendHello(producers: snapshot.producers, media: snapshot.media, client: client)
    }

    func disconnect() {
        let active = runningProducers
        let sources = producers
        let media = Array(mediaSources.values)
        client = nil
        runningProducers.removeAll()
        for slot in active { sources[slot]?.stop() }
        for registration in media { stopMediaSource(registration) }
    }

    func attach(_ producer: Producer, to slot: CameraSlot) {
        detach(slot)
        producers[slot] = producer
        let shouldStart = slotsWantedByShim.contains(slot) && client != nil
        if shouldStart {
            startProducer(producer, for: slot)
        }
    }

    func detach(_ slot: CameraSlot) {
        if let registrationID = slotToMediaSource[slot] {
            evictMediaSource(registrationID)
            return
        }
        let producer = producers.removeValue(forKey: slot)
        videoSinks.removeValue(forKey: slot)
        if runningProducers.remove(slot) != nil {
            producer?.stop()
        }
    }

    func attachMediaSource(
        _ source: any MediaSource,
        video videoSlot: CameraSlot?,
        audio audioSlot: CameraSlot?,
        isStopped: Bool
    ) {
        if videoSlot == nil && audioSlot == nil {
            log.warn("attachMediaSource called with no slots")
            return
        }
        if let videoSlot, videoSlot.wireIndex == nil {
            log.warn("attachMediaSource: video slot \(videoSlot.debugLabel) not supported by v1 shim")
            return
        }
        if let audioSlot, audioSlot.wireIndex == nil {
            log.warn("attachMediaSource: audio slot \(audioSlot.debugLabel) not supported by v1 shim")
            return
        }

        var evicting: Set<ObjectIdentifier> = []
        if let videoSlot, let registrationID = slotToMediaSource[videoSlot] { evicting.insert(registrationID) }
        if let audioSlot, let registrationID = slotToMediaSource[audioSlot] { evicting.insert(registrationID) }
        for registrationID in evicting { evictMediaSource(registrationID) }

        for slot in [videoSlot, audioSlot].compactMap({ $0 }) {
            if let producer = producers.removeValue(forKey: slot) {
                videoSinks.removeValue(forKey: slot)
                if runningProducers.remove(slot) != nil { producer.stop() }
            }
        }

        let registration = MediaSourceRegistration(source: source, video: videoSlot, audio: audioSlot)
        let registrationID = ObjectIdentifier(registration)
        mediaSources[registrationID] = registration
        if let videoSlot { slotToMediaSource[videoSlot] = registrationID }
        if let audioSlot { slotToMediaSource[audioSlot] = registrationID }

        guard !isStopped else {
            evictMediaSource(registrationID)
            return
        }

        // The initial HELLO usually fires before the orchestrator attaches any
        // MediaSource, so the shim's per-slot info (format, features) is
        // empty. Re-publish whenever sources change so the shim sees current
        // declared formats and feature flags.
        if let client = self.client {
            sendHello(producers: producers, media: Array(mediaSources.values), client: client)
        }

        let anyWanted =
            (videoSlot.map { slotsWantedByShim.contains($0) } ?? false)
            || (audioSlot.map { slotsWantedByShim.contains($0) } ?? false)
        if anyWanted, let client = self.client {
            startMediaSource(registration, client: client)
        }
    }

    private func evictMediaSource(_ registrationID: ObjectIdentifier) {
        guard let registration = mediaSources.removeValue(forKey: registrationID) else { return }
        if let videoSlot = registration.videoSlot {
            slotToMediaSource.removeValue(forKey: videoSlot)
            videoSinks.removeValue(forKey: videoSlot)
            runningProducers.remove(videoSlot)
        }
        if let audioSlot = registration.audioSlot {
            slotToMediaSource.removeValue(forKey: audioSlot)
            runningProducers.remove(audioSlot)
        }
        registration.fanout.setVideoSink(nil)
        registration.fanout.setAudioSink(nil)
        if registration.running {
            registration.source.stop()
        }
    }

    private func startMediaSource(_ registration: MediaSourceRegistration, client: SocketClient) {
        if registration.running { return }
        if let videoSlot = registration.videoSlot, let wireIndex = videoSlot.wireIndex,
            slotsWantedByShim.contains(videoSlot)
        {
            bindVideoSlot(registration: registration, slot: videoSlot, wireIndex: wireIndex, client: client)
        }
        if let audioSlot = registration.audioSlot, let wireIndex = audioSlot.wireIndex,
            slotsWantedByShim.contains(audioSlot)
        {
            bindAudioSlot(registration: registration, wireIndex: wireIndex, client: client)
        }
        do {
            try registration.source.start(into: registration.fanout)
            registration.running = true
            if let videoSlot = registration.videoSlot, registration.videoSink != nil {
                runningProducers.insert(videoSlot)
            }
            if let audioSlot = registration.audioSlot, registration.audioSink != nil {
                runningProducers.insert(audioSlot)
            }
            if let videoSlot = registration.videoSlot, let activeFormat = lastActiveFormat[videoSlot] {
                registration.source.reformat(to: activeFormat)
            }
            log.notice(
                "started media source: video=\(registration.videoSlot?.debugLabel ?? "-") audio=\(registration.audioSlot?.debugLabel ?? "-")"
            )
        } catch {
            log.warn("media source failed to start: \(error)")
            registration.fanout.setVideoSink(nil)
            registration.fanout.setAudioSink(nil)
            registration.videoSink = nil
            registration.audioSink = nil
        }
    }

    private func bindVideoSlot(
        registration: MediaSourceRegistration, slot: CameraSlot, wireIndex: UInt32, client: SocketClient
    ) {
        let initialFormat =
            lastActiveFormat[slot]
            ?? registration.source.declaredVideoFormat
            ?? VideoSlotFormat(width: 1280, height: 720, pixelFormat: .yuv420FullRange, fps: 30)
        let socketSink = VideoSlotBoundSink(
            wireIndex: wireIndex, declaredFormat: initialFormat, client: client, heartbeat: heartbeat)
        let routed = DetectionRouter(
            slot: wireIndex, downstream: socketSink, demand: demandRegistry, detector: hostDetector)
        registration.fanout.setVideoSink(routed)
        registration.videoSink = socketSink
        videoSinks[slot] = socketSink
    }

    private func bindAudioSlot(registration: MediaSourceRegistration, wireIndex: UInt32, client: SocketClient) {
        let format = registration.source.declaredAudioFormat ?? AudioSlotFormat(sampleRate: 48000, channels: 1)
        let sink = AudioSlotBoundSink(
            wireIndex: wireIndex, declaredFormat: format, client: client, heartbeat: heartbeat)
        registration.fanout.setAudioSink(sink)
        registration.audioSink = sink
    }

    private func stopMediaSource(_ registration: MediaSourceRegistration) {
        registration.fanout.setVideoSink(nil)
        registration.fanout.setAudioSink(nil)
        registration.videoSink = nil
        registration.audioSink = nil
        if let videoSlot = registration.videoSlot {
            runningProducers.remove(videoSlot)
            videoSinks.removeValue(forKey: videoSlot)
        }
        if let audioSlot = registration.audioSlot { runningProducers.remove(audioSlot) }
        if registration.running {
            registration.source.stop()
            registration.running = false
        }
    }

    private func sendHello(
        producers: [CameraSlot: Producer],
        media: [MediaSourceRegistration],
        client: SocketClient
    ) {
        var slots: [WireSlotInfo] = []
        for (slot, producer) in producers {
            guard let wireIndex = slot.wireIndex else { continue }
            switch producer {
            case .video(let producer):
                let format = producer.declaredFormat
                slots.append(
                    WireSlotInfo(
                        kind: UInt32(wireIndex),
                        width: UInt32(format.width), height: UInt32(format.height),
                        pixelFormat: format.pixelFormat.osType,
                        fpsNum: UInt32(format.fps), fpsDen: 1,
                        features: 0
                    ))
            case .audio(let producer):
                let format = producer.declaredFormat
                slots.append(
                    WireSlotInfo(
                        kind: UInt32(wireIndex),
                        width: 0, height: UInt32(format.channels),
                        pixelFormat: 0,
                        fpsNum: UInt32(format.sampleRate), fpsDen: 1,
                        features: 0
                    ))
            }
        }
        for registration in media {
            let features = registration.source.features.rawValue
            if let videoSlot = registration.videoSlot, let wireIndex = videoSlot.wireIndex,
                let format = registration.source.declaredVideoFormat
            {
                slots.append(
                    WireSlotInfo(
                        kind: UInt32(wireIndex),
                        width: UInt32(format.width), height: UInt32(format.height),
                        pixelFormat: format.pixelFormat.osType,
                        fpsNum: UInt32(format.fps), fpsDen: 1,
                        features: features
                    ))
            }
            if let audioSlot = registration.audioSlot, let wireIndex = audioSlot.wireIndex,
                let format = registration.source.declaredAudioFormat
            {
                slots.append(
                    WireSlotInfo(
                        kind: UInt32(wireIndex),
                        width: 0, height: UInt32(format.channels),
                        pixelFormat: 0,
                        fpsNum: UInt32(format.sampleRate), fpsDen: 1,
                        features: features
                    ))
            }
        }
        let hello = WireHello(slots: slots)
        _ = client.send(.reliable(type: .hello, payload: hello.encoded()))
    }

    func updateActiveFormat(_ message: WireActiveFormat) {
        let slot = slotForWireIndex(message.slot)
        guard let pixelFormat = PixelFormat(osType: message.pixelFormat) else {
            log.warn(
                "ACTIVE_FORMAT slot=\(message.slot): unsupported pixelFormat 0x\(String(message.pixelFormat, radix: 16))"
            )
            return
        }
        let fps: Int
        if case .video(let producer) = producers[slot] {
            fps = producer.declaredFormat.fps
        } else if let registrationID = slotToMediaSource[slot],
            let registration = mediaSources[registrationID],
            let videoFormat = registration.source.declaredVideoFormat
        {
            fps = videoFormat.fps
        } else {
            fps = 30
        }
        let target = VideoSlotFormat(
            width: Int(message.width), height: Int(message.height),
            pixelFormat: pixelFormat, fps: fps)
        log.notice("ACTIVE_FORMAT slot=\(slot.debugLabel) → \(message.width)x\(message.height) \(pixelFormat)")
        lastActiveFormat[slot] = target
        videoSinks[slot]?.updateExpectedFormat(target)
        if case .video(let producer) = producers[slot] {
            producer.reformat(to: target)
        }
        if let registrationID = slotToMediaSource[slot], let registration = mediaSources[registrationID] {
            registration.source.reformat(to: target)
        }
    }

    func setSlotActive(wireIndex: UInt32, active: Bool) -> CameraSlot? {
        let slot = slotForWireIndex(wireIndex)
        if active { slotsWantedByShim.insert(slot) } else { slotsWantedByShim.remove(slot) }

        if let registrationID = slotToMediaSource[slot], let registration = mediaSources[registrationID] {
            handleMediaSlotActive(registration: registration, slot: slot, active: active)
            return nil
        }

        let producer = producers[slot]
        let alreadyRunning = runningProducers.contains(slot)
        let shouldLogMissing = active && producer == nil && !loggedActivationsWithoutSource.contains(slot)
        if shouldLogMissing { loggedActivationsWithoutSource.insert(slot) }

        if shouldLogMissing {
            log.notice("slot '\(slot.debugLabel)' activated with no source — preview will be blank")
        }
        guard let producer else { return shouldLogMissing ? slot : nil }
        if active && !alreadyRunning {
            startProducer(producer, for: slot)
        } else if !active && alreadyRunning {
            stopProducer(producer, for: slot)
        }
        return nil
    }

    private func handleMediaSlotActive(registration: MediaSourceRegistration, slot: CameraSlot, active: Bool) {
        guard let client else { return }
        let isVideo = (slot == registration.videoSlot)
        let isAudio = (slot == registration.audioSlot)
        if active {
            if !registration.running {
                startMediaSource(registration, client: client)
                return
            }
            if isVideo, registration.videoSink == nil, let wireIndex = slot.wireIndex {
                bindVideoSlot(registration: registration, slot: slot, wireIndex: wireIndex, client: client)
                runningProducers.insert(slot)
                if let activeFormat = lastActiveFormat[slot] { registration.source.reformat(to: activeFormat) }
            }
            if isAudio, registration.audioSink == nil, let wireIndex = slot.wireIndex {
                bindAudioSlot(registration: registration, wireIndex: wireIndex, client: client)
                runningProducers.insert(slot)
            }
        } else {
            if isVideo {
                registration.fanout.setVideoSink(nil)
                registration.videoSink = nil
                videoSinks.removeValue(forKey: slot)
                runningProducers.remove(slot)
            }
            if isAudio {
                registration.fanout.setAudioSink(nil)
                registration.audioSink = nil
                runningProducers.remove(slot)
            }
            if registration.videoSink == nil && registration.audioSink == nil {
                stopMediaSource(registration)
            }
        }
    }

    private func startProducer(_ producer: Producer, for slot: CameraSlot) {
        guard let wireIndex = slot.wireIndex else { return }
        guard let client else { return }
        do {
            switch producer {
            case .video(let producer):
                let initialFormat = lastActiveFormat[slot] ?? producer.declaredFormat
                let socketSink = VideoSlotBoundSink(
                    wireIndex: wireIndex, declaredFormat: initialFormat, client: client, heartbeat: heartbeat)
                videoSinks[slot] = socketSink
                let routedSink = DetectionRouter(
                    slot: wireIndex,
                    downstream: socketSink,
                    demand: demandRegistry,
                    detector: hostDetector)
                try producer.start(into: routedSink)
                if let activeFormat = lastActiveFormat[slot] {
                    producer.reformat(to: activeFormat)
                }
            case .audio(let producer):
                let sink = AudioSlotBoundSink(
                    wireIndex: wireIndex, declaredFormat: producer.declaredFormat, client: client, heartbeat: heartbeat)
                try producer.start(into: sink)
            }
            runningProducers.insert(slot)
            log.notice("started producer for \(slot.debugLabel)")
        } catch {
            log.warn("producer failed to start for \(slot.debugLabel): \(error)")
        }
    }

    private func stopProducer(_ producer: Producer, for slot: CameraSlot) {
        producer.stop()
        runningProducers.remove(slot)
        videoSinks.removeValue(forKey: slot)
        log.notice("stopped producer for \(slot.debugLabel)")
    }

    private func slotForWireIndex(_ wireIndex: UInt32) -> CameraSlot {
        switch wireIndex {
        case 0: return .backCamera
        case 1: return .frontCamera
        case 2: return .microphone
        default: return .backCamera
        }
    }
}
