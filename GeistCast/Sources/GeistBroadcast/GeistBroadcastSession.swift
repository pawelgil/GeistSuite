import AVFoundation
import CommonCrypto
import CoreMedia
import CoreVideo
import Foundation
import Darwin
import GeistKit

struct ExtensionContext: Sendable, Equatable {
    let bundleID: String
    let appexPath: String
}

public protocol GeistBroadcastSessionDelegate: AnyObject, Sendable {
    func session(_ session: GeistBroadcastSession, broadcastStarted: Broadcast)
    func session(_ session: GeistBroadcastSession, broadcastEnded: Broadcast)
    func session(_ session: GeistBroadcastSession,
                 broadcastFailedToStart broadcast: Broadcast,
                 error: Error)
    func session(_ session: GeistBroadcastSession,
                 broadcast: Broadcast,
                 terminatedWithError error: Error)
    func session(_ session: GeistBroadcastSession, stateChanged: GeistBroadcastSession.State)
    func session(_ session: GeistBroadcastSession, extensionConnectedFor extensionBundleID: String)
}

public extension GeistBroadcastSessionDelegate {
    func session(_ session: GeistBroadcastSession, broadcastStarted: Broadcast) {}
    func session(_ session: GeistBroadcastSession, broadcastEnded: Broadcast) {}
    func session(_ session: GeistBroadcastSession,
                 broadcastFailedToStart broadcast: Broadcast,
                 error: Error) {}
    func session(_ session: GeistBroadcastSession,
                 broadcast: Broadcast,
                 terminatedWithError error: Error) {}
    func session(_ session: GeistBroadcastSession, stateChanged: GeistBroadcastSession.State) {}
    func session(_ session: GeistBroadcastSession, extensionConnectedFor extensionBundleID: String) {}
}

public struct ExtensionTerminationError: Error, Equatable, Sendable {
    public let domain: String
    public let code: Int
    public let message: String

    public init(domain: String, code: Int, message: String) {
        self.domain = domain
        self.code = code
        self.message = message
    }
}

public actor GeistBroadcastSession {

    public enum State: Sendable { case idle, listening, stopped }

    public enum SessionError: Error, Equatable {
        case socketCreate(errno: Int32)
        case bind(errno: Int32)
        case listen(errno: Int32)
        case alreadyStarted
        case unknownBroadcast
        case notConnected
        case notBroadcasting
        case extensionDiedBeforeStart
        case shimDylibMissing(String)
    }

    public nonisolated let simulator: String
    public nonisolated let hostBundleID: String
    nonisolated let extensionContext: ExtensionContext

    public nonisolated var extensionAppexPath: String { extensionContext.appexPath }

    public private(set) weak var delegate: (any GeistBroadcastSessionDelegate)?
    public private(set) var state: State = .idle
    public private(set) var activeBroadcasts: Set<Broadcast> = []

    private let simctlSetPath: String?
    private let videoCapture: VideoCaptureConfig
    private var micAudio: MicAudioConfig
    public nonisolated let socketPath: String
    private let frameSocketPath: String
    private let stager: any AppexStaging
    private let spawner: any AppexSpawning
    private var stagedAppex: Task<StagedAppex, Error>
    private var lastStagedSourceHash: String?
    private let appShimDylibPath: String?
    private let extensionShimDylibPath: String?
    private let encoder = WireEncoder()

    private static let videoQueueCapacity = 1
    private static let audioQueueCapacity = 16

    private var listenFD: Int32 = -1
    private var frameListenFD: Int32 = -1
    private var acceptTask: Task<Void, Never>?
    private var frameAcceptTask: Task<Void, Never>?
    private var hostFD: Int32?
    private var extensionFD: Int32?
    private var pendingBroadcast: Broadcast?
    // True once user has confirmed start (countdown ended). Until then, even
    // if the extension has connected via helloExtension, we don't send `begin`
    // — it sits parked. Cleared by userCancelledStart or session reset.
    private var userConfirmedStart: Bool = false
    private var launchTask: Task<Void, Never>?
    private var micAuthPollTask: Task<Void, Never>?
    private var lastMicAuth: Bool = false
    private var clientFDs: Set<Int32> = []
    private var pausedBroadcasts: Set<Broadcast> = []

    private var videoSource: (any BroadcastSource)?
    private var micSource: (any BroadcastSource)?

    private let videoQueue: BoundedFrameQueue<Data>
    private let micQueue: BoundedFrameQueue<Data>
    private let sink: SessionBroadcastSink

    public init(
        simulator: UUID,
        hostBundleID: String,
        simctlSetPath: String? = nil,
        extensionBundleID: String? = nil,
        videoCapture: VideoCaptureConfig = .simulatorScreen,
        micAudio: MicAudioConfig = .systemMicrophone,
        delegate: (any GeistBroadcastSessionDelegate)? = nil
    ) async throws {
        let resolved = try await ExtensionDiscovery.resolve(
            simulator: simulator,
            hostBundleID: hostBundleID,
            extensionBundleID: extensionBundleID,
            simctlSetPath: simctlSetPath
        )
        let appShim = try GeistBroadcastShimBundled.appShimDylibPath()
        let extShim = try GeistBroadcastShimBundled.extensionShimDylibPath()
        self.init(
            simulatorUDID: simulator.uuidString,
            hostBundleID: hostBundleID,
            extensionContext: ExtensionContext(
                bundleID: resolved.extensionBundleID,
                appexPath: resolved.appexPath
            ),
            simctlSetPath: simctlSetPath,
            videoCapture: videoCapture,
            micAudio: micAudio,
            delegate: delegate,
            stager: AppexStager(),
            spawner: AppexSpawner(),
            appShimDylibPath: appShim,
            extensionShimDylibPath: extShim
        )
    }

    public static func broadcastCapableApps(
        simulator: UUID,
        simctlSetPath: String? = nil
    ) async throws -> [BroadcastApp] {
        try await ExtensionDiscovery.broadcastCapableApps(
            simulator: simulator, simctlSetPath: simctlSetPath
        )
    }

    init(
        simulatorUDID: String,
        hostBundleID: String,
        extensionContext: ExtensionContext,
        simctlSetPath: String?,
        videoCapture: VideoCaptureConfig = .simulatorScreen,
        micAudio: MicAudioConfig = .systemMicrophone,
        delegate: (any GeistBroadcastSessionDelegate)?,
        stager: any AppexStaging,
        spawner: any AppexSpawning,
        appShimDylibPath: String? = nil,
        extensionShimDylibPath: String? = nil
    ) {
        self.simulator = simulatorUDID
        self.hostBundleID = hostBundleID
        self.extensionContext = extensionContext
        self.simctlSetPath = simctlSetPath
        self.videoCapture = videoCapture
        self.micAudio = micAudio
        self.socketPath = Self.conventionalSocketPath(
            simulator: simulatorUDID, bundleID: hostBundleID
        )
        self.frameSocketPath = Self.conventionalFrameSocketPath(
            simulator: simulatorUDID, bundleID: hostBundleID
        )
        self.delegate = delegate
        self.stager = stager
        self.spawner = spawner
        let appexPath = extensionContext.appexPath
        self.stagedAppex = Task.detached(priority: .utility) {
            try await stager.stage(appexAt: appexPath)
        }
        self.lastStagedSourceHash = Self.sourceBinaryHash(appexPath: appexPath)
        self.appShimDylibPath = appShimDylibPath
        self.extensionShimDylibPath = extensionShimDylibPath
        let videoQueue = BoundedFrameQueue<Data>(capacity: GeistBroadcastSession.videoQueueCapacity)
        let micQueue = BoundedFrameQueue<Data>(capacity: GeistBroadcastSession.audioQueueCapacity)
        self.videoQueue = videoQueue
        self.micQueue = micQueue
        self.sink = SessionBroadcastSink(videoQueue: videoQueue, micQueue: micQueue)
    }

    // Both the macOS host and the iOS simulator derive this path independently
    // from (simulator UDID, host bundle ID) — there is no handshake. `/tmp/`
    // is the only directory they see at the same filesystem location.
    private static func conventionalSocketPath(
        simulator: String, bundleID: String
    ) -> String {
        "/tmp/geistcast-\(simulator)-\(bundleID).sock"
    }

    private static func conventionalFrameSocketPath(
        simulator: String, bundleID: String
    ) -> String {
        "/tmp/geistcast-frames-\(simulator)-\(bundleID).sock"
    }

    public nonisolated func injectionEnv() throws -> [String: String] {
        var env: [String: String] = ["GEISTCAST_SOCKET": socketPath]
        if let path = appShimDylibPath {
            // Path was resolved at init; re-verify the file is still on disk —
            // e.g. Xcode wiping DerivedData while GeistCast keeps running.
            guard FileManager.default.fileExists(atPath: path) else {
                throw SessionError.shimDylibMissing(path)
            }
            env["DYLD_INSERT_LIBRARIES"] = path
        }
        return env
    }

    public func start() throws {
        guard state == .idle else { throw SessionError.alreadyStarted }
        try openListenSocket()
        try openFrameListenSocket()
        transition(to: .listening)
        spawnAcceptLoop()
        spawnFrameAcceptLoop()
        lastMicAuth = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        micAuthPollTask = Task { [weak self] in await self?.pollMicAuth() }
        let bundle = hostBundleID, path = socketPath
        log.notice("[Session \(bundle)] start: listening at \(path)")
    }

    public func stop() {
        let bundle = hostBundleID
        log.notice("[Session \(bundle)] stop")
        videoSource?.stop()
        videoSource = nil
        micSource?.stop()
        micSource = nil
        acceptTask?.cancel()
        acceptTask = nil
        frameAcceptTask?.cancel()
        frameAcceptTask = nil
        micAuthPollTask?.cancel()
        micAuthPollTask = nil
        stagedAppex.cancel()
        videoQueue.close()
        micQueue.close()
        // shutdown() before close() forces blocked accept()/read() syscalls
        // to return immediately; Task.cancel() alone doesn't interrupt
        // kernel-level blocking, so without this the detached loop threads
        // would stay parked until the kernel decided to GC the fd.
        if listenFD >= 0 {
            shutdown(listenFD, SHUT_RDWR); close(listenFD); listenFD = -1
        }
        if frameListenFD >= 0 {
            shutdown(frameListenFD, SHUT_RDWR); close(frameListenFD); frameListenFD = -1
        }
        for fd in clientFDs { shutdown(fd, SHUT_RDWR); close(fd) }
        clientFDs.removeAll()
        hostFD = nil
        extensionFD = nil
        pausedBroadcasts.removeAll()
        unlink(socketPath)
        unlink(frameSocketPath)
        transition(to: .stopped)
    }

    private func registerClientFD(_ fd: Int32) {
        clientFDs.insert(fd)
    }

    private func closeClientFD(_ fd: Int32) {
        if clientFDs.remove(fd) != nil {
            close(fd)
        }
    }

    public var hasInFlightBroadcast: Bool {
        !activeBroadcasts.isEmpty
            || extensionFD != nil
            || pendingBroadcast != nil
            || userConfirmedStart
    }

    /// Always forwards `.broadcastEnded` to the host shim, even when no
    /// `.broadcastStarted` ever arrived — the host's `gFakeCaptured` was
    /// already flipped on at user confirm and stays stuck otherwise.
    public func stopBroadcast() {
        if let extFD = extensionFD {
            send(.finish, to: extFD)
            extensionFD = nil
        }
        for broadcast in activeBroadcasts {
            activeBroadcasts.remove(broadcast)
            pausedBroadcasts.remove(broadcast)
            delegate?.session(self, broadcastEnded: broadcast)
            if let hostFD { send(.broadcastEnded(broadcast), to: hostFD) }
        }
        if let pending = pendingBroadcast {
            if let hostFD { send(.broadcastEnded(pending), to: hostFD) }
            pendingBroadcast = nil
        }
        userConfirmedStart = false
        launchTask?.cancel()
        launchTask = nil
        detachMicSource()
        detachVideoSource()
    }

    public func pause() throws {
        guard let broadcast = activeBroadcasts.first else {
            throw SessionError.notBroadcasting
        }
        guard let extFD = extensionFD else {
            throw SessionError.notConnected
        }
        guard !pausedBroadcasts.contains(broadcast) else { return }
        pausedBroadcasts.insert(broadcast)
        send(.pause, to: extFD)
    }

    public func resume() throws {
        guard let broadcast = activeBroadcasts.first else {
            throw SessionError.notBroadcasting
        }
        guard let extFD = extensionFD else {
            throw SessionError.notConnected
        }
        guard pausedBroadcasts.contains(broadcast) else { return }
        pausedBroadcasts.remove(broadcast)
        send(.resume, to: extFD)
    }

    /// Takes effect on the next broadcast; an in-flight broadcast keeps its
    /// existing mic source until it ends.
    public func setMicAudio(_ config: MicAudioConfig) {
        micAudio = config
    }

    /// Re-stage the appex in the background if the source binary's hash has
    /// changed since we last staged. Skipped while a broadcast is in flight
    /// or pending — swapping out from under an active spawn would race.
    public func refreshStagedAppexIfNeeded() {
        guard pendingBroadcast == nil, activeBroadcasts.isEmpty else { return }
        let appexPath = extensionContext.appexPath
        guard let currentHash = Self.sourceBinaryHash(appexPath: appexPath) else { return }
        if currentHash == lastStagedSourceHash { return }
        lastStagedSourceHash = currentHash
        let stager = self.stager
        stagedAppex = Task.detached(priority: .utility) {
            try await stager.stage(appexAt: appexPath)
        }
    }

    nonisolated private static func sourceBinaryHash(appexPath: String) -> String? {
        let appexURL = URL(fileURLWithPath: appexPath)
        let executableName = (appexPath as NSString).lastPathComponent
            .replacingOccurrences(of: ".appex", with: "")
        let executableURL = appexURL.appendingPathComponent(executableName)
        let fd = open(executableURL.path, O_RDONLY)
        if fd < 0 { return nil }
        defer { close(fd) }
        var ctx = CC_SHA256_CTX()
        CC_SHA256_Init(&ctx)
        let bufSize = 64 * 1024
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 1)
        defer { buf.deallocate() }
        while true {
            let n = read(fd, buf, bufSize)
            if n < 0 { return nil }
            if n == 0 { break }
            CC_SHA256_Update(&ctx, buf, CC_LONG(n))
        }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256_Final(&digest, &ctx)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public func simulateMicAudioInterruption(_ active: Bool) throws {
        guard let extFD = extensionFD else {
            throw SessionError.notConnected
        }
        send(.setMicAudioReadiness(ready: !active), to: extFD)
    }

    private func transition(to newState: State) {
        state = newState
        delegate?.session(self, stateChanged: newState)
    }

    private func attachVideoSource() {
        guard videoSource == nil else { return }
        let source: any BroadcastSource
        switch videoCapture {
        case .simulatorScreen:
            guard let udid = UUID(uuidString: simulator) else {
                log.warn("Session: simulator '\(self.simulator)' is not a valid UUID; skipping simulator-screen capture")
                return
            }
            do {
                source = try SimulatorScreenBroadcastSource(
                    udid: udid, simctlSetPath: simctlSetPath
                )
            } catch {
                log.warn("Session: simulator-screen capture init failed: \(error)")
                return
            }
        case .custom(let producer):
            source = CustomVideoBroadcastSource(producer)
        }
        do {
            try source.start(into: sink)
            videoSource = source
        } catch {
            log.warn("Session: video source start failed: \(error)")
        }
    }

    private func detachVideoSource() {
        videoSource?.stop()
        videoSource = nil
    }

    private func attachMicSource() {
        guard micSource == nil else { return }
        let source: (any BroadcastSource)?
        switch micAudio {
        case .systemMicrophone: source = SystemMicrophoneBroadcastSource()
        case .mediaFile(let url): source = MediaFileMicAudioSource(url: url)
        case .custom(let producer): source = CustomMicAudioBroadcastSource(producer)
        case .disabled: source = nil
        }
        guard let source else { return }
        do {
            try source.start(into: sink)
            micSource = source
        } catch {
            log.warn("Session: mic source attach failed: \(error)")
        }
    }

    private func detachMicSource() {
        micSource?.stop()
        micSource = nil
    }

    private func openListenSocket() throws {
        listenFD = try Self.openUnixListener(path: socketPath, backlog: 8)
    }

    private static func openUnixListener(path: String, backlog: Int32) throws -> Int32 {
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SessionError.socketCreate(errno: errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
        _ = path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
                tuplePtr.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { dst in
                    strlcpy(dst, src, pathCapacity)
                }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let err = errno
            close(fd)
            throw SessionError.bind(errno: err)
        }

        guard listen(fd, backlog) == 0 else {
            let err = errno
            close(fd)
            throw SessionError.listen(errno: err)
        }

        return fd
    }

    private func spawnAcceptLoop() {
        let fd = listenFD
        acceptTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                let clientFD = accept(fd, nil, nil)
                if clientFD < 0 { return }
                // Writing to a half-closed socket otherwise raises SIGPIPE
                // and terminates the host process. Per-socket is preferable
                // to a process-wide signal handler.
                var noSigPipe: Int32 = 1
                setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE,
                           &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
                await self?.registerClientFD(clientFD)
                self?.startReadLoop(fd: clientFD)
            }
        }
    }

    // Blocking read() must run on a real OS thread, not the Swift cooperative
    // pool — a handful of in-flight Task.detached read loops will exhaust the
    // pool (default ≈ cpuCount), preventing new Tasks from being scheduled at
    // all. Subsequent accepts then never get their handle Task body to fire.
    // GCD's pool is much larger and tolerates blocked threads.
    private nonisolated func startReadLoop(fd clientFD: Int32) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var decoder = WireDecoder()
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = buf.withUnsafeMutableBufferPointer { bp in
                    read(clientFD, bp.baseAddress, bp.count)
                }
                if n <= 0 {
                    Task { [weak self] in
                        await self?.cleanupConnection(fd: clientFD)
                        await self?.closeClientFD(clientFD)
                    }
                    return
                }
                let chunk = Data(buf[0..<n])
                let messages = decoder.feed(chunk)
                // One Task per chunk with sequential awaits — N Tasks
                // would let the scheduler reorder them on the actor.
                if !messages.isEmpty {
                    Task { [weak self] in
                        for message in messages {
                            await self?.ingest(message, from: clientFD)
                        }
                    }
                }
                if self == nil {
                    close(clientFD)
                    return
                }
            }
        }
    }

    private func cleanupConnection(fd: Int32) async {
        if hostFD == fd {
            log.notice("[Session \(self.hostBundleID)] host fd closed (fd=\(fd))")
            hostFD = nil
        }
        if extensionFD == fd {
            log.notice("[Session \(self.hostBundleID)] extension fd closed (fd=\(fd)) activeBroadcasts=\(self.activeBroadcasts.count) pending=\(self.pendingBroadcast != nil)")
            extensionFD = nil
            // Extension going away with an active broadcast is the only
            // signal we have that the broadcast actually ended (extension
            // process died for any reason). Fire the delegate and clean up.
            for broadcast in activeBroadcasts {
                activeBroadcasts.remove(broadcast)
                pausedBroadcasts.remove(broadcast)
                delegate?.session(self, broadcastEnded: broadcast)
                if let hostFD { send(.broadcastEnded(broadcast), to: hostFD) }
            }
            if let pending = pendingBroadcast {
                delegate?.session(self,
                                  broadcastFailedToStart: pending,
                                  error: SessionError.extensionDiedBeforeStart)
                // Host shim's gFakeCaptured was flipped on at user confirm
                // and stays stuck without an ended notification.
                if let hostFD { send(.broadcastEnded(pending), to: hostFD) }
                pendingBroadcast = nil
            }
            userConfirmedStart = false
            detachMicSource()
            detachVideoSource()
            // Reap any appex process that survived past control disconnect
            // (e.g. CoreAudio init wedged in a non-fatal assertion loop) —
            // otherwise it lingers and the next spawn can't bind sockets.
            // killStale uses pkill -f against the binary path, which a fresh
            // extension also matches, so skip the reap if one connected (or
            // re-armed) during the awaits.
            if let staged = try? await stagedAppex.value,
               extensionFD == nil, pendingBroadcast == nil {
                await spawner.killStale(stagedBinary: staged.binaryPath)
            }
        }
    }

    private func ingest(_ message: WireMessage, from fd: Int32) async {
        switch message {
        case .helloHost:
            log.notice("[Session \(self.hostBundleID)] helloHost fd=\(fd) recording=\(!self.activeBroadcasts.isEmpty)")
            hostFD = fd
            let currentBroadcast = activeBroadcasts.first
            let micAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            send(.state(recording: currentBroadcast != nil,
                        broadcast: currentBroadcast,
                        micEnabled: micSource != nil,
                        macOSMicAuthorized: micAuthorized),
                 to: fd)

        case .helloExtension(let extensionBundleID):
            log.notice("[Session \(self.hostBundleID)] helloExtension bundle=\(extensionBundleID) fd=\(fd) userConfirmedStart=\(self.userConfirmedStart) prevExtFD=\(self.extensionFD ?? -1)")
            // Old fd — shutdown only; closeClientFD happens in the
            // read-loop teardown so a recycled fd number can't be
            // killed by a stale close.
            if let old = extensionFD {
                shutdown(old, SHUT_RDWR)
            }
            extensionFD = fd
            if userConfirmedStart, let broadcast = pendingBroadcast {
                send(.begin(broadcast), to: fd)
            }
            delegate?.session(self, extensionConnectedFor: extensionBundleID)

        case .userPressedStart(let micEnabled):
            log.notice("[Session \(self.hostBundleID)] userPressedStart micEnabled=\(micEnabled) extFD=\(self.extensionFD ?? -1)")
            armBroadcast()
            userConfirmedStart = true
            if let extFD = extensionFD, let broadcast = pendingBroadcast {
                send(.begin(broadcast), to: extFD)
            }
            attachVideoSource()
            if micEnabled {
                attachMicSource()
            }

        case .userCancelledStart:
            log.notice("[Session \(self.hostBundleID)] userCancelledStart")
            launchTask?.cancel()
            launchTask = nil
            if let extFD = extensionFD {
                // shutdown only; closeClientFD happens in the read-loop
                // teardown so a recycled fd number can't be killed by
                // a stale close.
                shutdown(extFD, SHUT_RDWR)
                extensionFD = nil
            }
            pendingBroadcast = nil
            userConfirmedStart = false
            detachMicSource()
            detachVideoSource()

        case .userPressedStop:
            log.notice("[Session \(self.hostBundleID)] userPressedStop extFD=\(self.extensionFD ?? -1)")
            if let extFD = extensionFD {
                send(.finish, to: extFD)
            }
            detachMicSource()
            detachVideoSource()

        case .userToggledMic(let enabled):
            log.notice("[Session \(self.hostBundleID)] userToggledMic enabled=\(enabled)")
            if enabled {
                attachMicSource()
            } else {
                detachMicSource()
            }

        case .broadcastStarted(let broadcast):
            activeBroadcasts.insert(broadcast)
            delegate?.session(self, broadcastStarted: broadcast)
            pendingBroadcast = nil
            if let hostFD, fd != hostFD {
                send(.broadcastStarted(broadcast), to: hostFD)
            }

        case .broadcastEnded(let broadcast):
            // The extension emits "ended" after its ~5s post-finish grace.
            // stopBroadcast() and cleanupConnection() may have already
            // processed the end — re-firing the delegate and re-sending the
            // wire envelope to the host would confuse the host's state
            // machine (HOST treats a late "ended" as a forced stop and
            // bounces the user out of its questionnaire).
            let wasActive = activeBroadcasts.remove(broadcast) != nil
            pausedBroadcasts.remove(broadcast)
            if wasActive {
                delegate?.session(self, broadcastEnded: broadcast)
                if let hostFD, fd != hostFD {
                    send(.broadcastEnded(broadcast), to: hostFD)
                }
                detachMicSource()
                detachVideoSource()
            }

        case .extensionTerminated(let domain, let code, let message):
            let error = ExtensionTerminationError(
                domain: domain, code: code, message: message
            )
            if let broadcast = activeBroadcasts.first {
                activeBroadcasts.remove(broadcast)
                pausedBroadcasts.remove(broadcast)
                delegate?.session(self, broadcast: broadcast, terminatedWithError: error)
            } else if let pending = pendingBroadcast {
                delegate?.session(self, broadcastFailedToStart: pending, error: error)
                pendingBroadcast = nil
            }
            detachMicSource()
            detachVideoSource()

        case .state, .begin, .finish, .pause, .resume, .setMicAudioReadiness:
            break
        }
    }

    private func armBroadcast() {
        guard pendingBroadcast == nil else { return }
        let broadcast = Broadcast(
            simulatorUDID: simulator,
            hostAppBundleID: hostBundleID,
            extensionBundleID: extensionContext.bundleID,
            startedAt: Date()
        )
        pendingBroadcast = broadcast
        log.notice("[Session \(self.hostBundleID)] armBroadcast: spawning extension \(self.extensionContext.bundleID)")
        // simctl spawn blocks until the extension exits.
        launchTask = Task { [weak self] in await self?.launchExtension() }
    }

    private func pollMicAuth() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            if Task.isCancelled { return }
            let current = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            if current != lastMicAuth {
                lastMicAuth = current
                let bundle = hostBundleID
                log.notice("[Session \(bundle)] macOS mic auth changed → \(current)")
                if let hostFD {
                    let currentBroadcast = activeBroadcasts.first
                    send(.state(recording: currentBroadcast != nil,
                                broadcast: currentBroadcast,
                                micEnabled: micSource != nil,
                                macOSMicAuthorized: current),
                         to: hostFD)
                }
            }
        }
    }

    private func launchExtension() async {
        do {
            let staged = try await stagedAppex.value
            try await spawner.spawn(
                stagedBinary: staged.binaryPath,
                simulatorUDID: simulator,
                simctlSetPath: simctlSetPath,
                environment: try extensionLaunchEnv()
            )
        } catch {
            log.warn("Session: launchExtension failed: \(error)")
            if let pending = pendingBroadcast {
                delegate?.session(self, broadcastFailedToStart: pending, error: error)
            }
            pendingBroadcast = nil
            userConfirmedStart = false
        }
    }

    private func extensionLaunchEnv() throws -> [String: String] {
        var env: [String: String] = [
            "GEISTCAST_SOCKET": socketPath,
            "GEISTCAST_HOST_SOCKET": frameSocketPath,
        ]
        if let path = extensionShimDylibPath {
            guard FileManager.default.fileExists(atPath: path) else {
                throw SessionError.shimDylibMissing(path)
            }
            env["DYLD_INSERT_LIBRARIES"] = path
        }
        // Staging copies the appex to /tmp without its host's Frameworks/
        // and PackageFrameworks/ siblings, breaking @rpath resolution for
        // SPM-bundled dylibs.
        let appPath = URL(fileURLWithPath: extensionContext.appexPath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
        env["DYLD_FRAMEWORK_PATH"] = "\(appPath)/Frameworks:\(appPath)/PackageFrameworks"
        env["DYLD_LIBRARY_PATH"] = "\(appPath)/Frameworks:\(appPath)/PackageFrameworks"
        return env
    }

    private func openFrameListenSocket() throws {
        frameListenFD = try Self.openUnixListener(path: frameSocketPath, backlog: 4)
    }

    private func spawnFrameAcceptLoop() {
        let fd = frameListenFD
        let videoQ = videoQueue
        let micQ = micQueue
        frameAcceptTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                let clientFD = accept(fd, nil, nil)
                if clientFD < 0 { return }
                var noSigPipe: Int32 = 1
                setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE,
                           &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
                await self?.registerClientFD(clientFD)
                Task.detached { [weak self] in
                    await Self.serveFrames(
                        fd: clientFD,
                        videoQueue: videoQ,
                        micQueue: micQ
                    )
                    await self?.closeClientFD(clientFD)
                }
            }
        }
    }

    nonisolated private static func serveFrames(
        fd: Int32,
        videoQueue: BoundedFrameQueue<Data>,
        micQueue: BoundedFrameQueue<Data>
    ) async {
        while !Task.isCancelled {
            var wroteAny = false
            var openCount = 0

            switch micQueue.dequeue(timeoutSeconds: 0) {
            case .received(let payload):
                if !writeAll(fd: fd, data: payload) { return }
                wroteAny = true
                openCount += 1
            case .empty:
                openCount += 1
            case .closed:
                break
            }

            switch videoQueue.dequeue(timeoutSeconds: 0) {
            case .received(let payload):
                if !writeAll(fd: fd, data: payload) { return }
                wroteAny = true
                openCount += 1
            case .empty:
                openCount += 1
            case .closed:
                break
            }

            if openCount == 0 { return }
            if !wroteAny {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }


    nonisolated private static func writeAll(fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { ptr -> Bool in
            guard let base = ptr.baseAddress else { return true }
            var remaining = ptr.count
            var off = 0
            while remaining > 0 {
                let n = write(fd, base.advanced(by: off), remaining)
                if n <= 0 { return false }
                remaining -= n
                off += n
            }
            return true
        }
    }

    private func send(_ message: WireMessage, to fd: Int32) {
        _ = Self.writeAll(fd: fd, data: encoder.encode(message))
    }
}

private nonisolated(unsafe) var loggedUnsupportedAudioFormat = false
private let loggedUnsupportedAudioFormatLock = NSLock()

private func logUnsupportedAudioFormatOnce(_ format: AVAudioFormat) {
    loggedUnsupportedAudioFormatLock.lock()
    let alreadyLogged = loggedUnsupportedAudioFormat
    loggedUnsupportedAudioFormat = true
    loggedUnsupportedAudioFormatLock.unlock()
    guard !alreadyLogged else { return }
    log.warn("encodeAudio dropping buffers: unsupported common format \(format.commonFormat.rawValue) (sr=\(format.sampleRate) ch=\(format.channelCount))")
}

final class SessionBroadcastSink: BroadcastSink {
    private let videoQueue: BoundedFrameQueue<Data>
    private let micQueue: BoundedFrameQueue<Data>

    init(videoQueue: BoundedFrameQueue<Data>,
         micQueue: BoundedFrameQueue<Data>) {
        self.videoQueue = videoQueue
        self.micQueue = micQueue
    }

    func sendVideo(_ pixelBuffer: CVPixelBuffer) {
        guard let payload = Self.encodeVideo(pixelBuffer) else { return }
        _ = videoQueue.enqueueOrDropNewest(payload)
    }

    func sendMicAudio(_ samples: AVAudioPCMBuffer) {
        guard let payload = Self.encodeAudio(samples, stream: .audioMic) else { return }
        _ = micQueue.enqueueOrDropNewest(payload)
    }

    private static func encodeVideo(_ pixelBuffer: CVPixelBuffer) -> Data? {
        let lockResult = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        guard lockResult == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = UInt32(CVPixelBufferGetWidth(pixelBuffer))
        let height = UInt32(CVPixelBufferGetHeight(pixelBuffer))
        let fourCC = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)

        var payload = Data()
        let bytesPerRowPlane0: UInt32
        let bytesPerRowPlane1: UInt32

        if planeCount == 0 {
            guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
            let bpr: Int = CVPixelBufferGetBytesPerRow(pixelBuffer)
            bytesPerRowPlane0 = UInt32(bpr)
            bytesPerRowPlane1 = 0
            payload.append(UnsafeBufferPointer(
                start: base.assumingMemoryBound(to: UInt8.self),
                count: bpr * Int(height)
            ))
        } else {
            let bpr0: Int = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let h0: Int = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
            guard let p0 = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }
            bytesPerRowPlane0 = UInt32(bpr0)
            payload.append(UnsafeBufferPointer(
                start: p0.assumingMemoryBound(to: UInt8.self), count: bpr0 * h0
            ))
            if planeCount >= 2 {
                let bpr1: Int = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
                let h1: Int = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
                guard let p1 = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else { return nil }
                bytesPerRowPlane1 = UInt32(bpr1)
                payload.append(UnsafeBufferPointer(
                    start: p1.assumingMemoryBound(to: UInt8.self), count: bpr1 * h1
                ))
            } else {
                bytesPerRowPlane1 = 0
            }
        }

        let header = FrameHeader.video(
            pixelFormatFourCC: UInt32(fourCC),
            width: width,
            height: height,
            bytesPerRowPlane0: bytesPerRowPlane0,
            bytesPerRowPlane1: bytesPerRowPlane1,
            payloadSize: UInt32(payload.count)
        )
        var out = header.encoded()
        out.append(payload)
        return out
    }

    private static func encodeAudio(_ buffer: AVAudioPCMBuffer, stream: StreamType) -> Data? {
        let format = buffer.format
        let sampleCount = UInt32(buffer.frameLength)
        guard sampleCount > 0 else { return nil }

        let wireFormat: AudioWireSampleFormat
        let bytesPerSample: Int
        var payload = Data()

        switch format.commonFormat {
        case .pcmFormatInt16:
            wireFormat = .pcmInt16
            bytesPerSample = 2
            guard let int16 = buffer.int16ChannelData else { return nil }
            for channelIdx in 0..<Int(format.channelCount) {
                let channel = int16[channelIdx]
                let bytes = Int(sampleCount) * bytesPerSample
                payload.append(UnsafeBufferPointer(
                    start: UnsafeRawPointer(channel).assumingMemoryBound(to: UInt8.self),
                    count: bytes
                ))
            }
        case .pcmFormatFloat32:
            wireFormat = .pcmFloat32
            bytesPerSample = 4
            guard let floatData = buffer.floatChannelData else { return nil }
            for channelIdx in 0..<Int(format.channelCount) {
                let channel = floatData[channelIdx]
                let bytes = Int(sampleCount) * bytesPerSample
                payload.append(UnsafeBufferPointer(
                    start: UnsafeRawPointer(channel).assumingMemoryBound(to: UInt8.self),
                    count: bytes
                ))
            }
        default:
            logUnsupportedAudioFormatOnce(format)
            return nil
        }

        // AVAudioPCMBuffer exposes per-channel pointers (planar), so what we
        // emit on the wire is non-interleaved unless we interleave ourselves.
        // The extension reassembles per-channel data with isInterleaved=false.
        let header = FrameHeader.audio(
            stream: stream,
            sampleRate: UInt32(format.sampleRate),
            channelCount: UInt32(format.channelCount),
            sampleFormat: wireFormat,
            isInterleaved: false,
            sampleCount: sampleCount,
            payloadSize: UInt32(payload.count)
        )
        var out = header.encoded()
        out.append(payload)
        return out
    }
}
