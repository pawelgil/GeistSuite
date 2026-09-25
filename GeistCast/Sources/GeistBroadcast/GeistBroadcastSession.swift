import CommonCrypto
import Darwin
import Foundation
import GeistKit

public actor GeistBroadcastSession {
    // MARK: Nested Types

    public enum State: Sendable { case idle, listening, stopped }

    public enum SessionError: Error, Equatable {
        case socketCreate(errno: Int32)
        case bind(errno: Int32)
        case listen(errno: Int32)
        case alreadyStarted
        case unknownBroadcast
        case notConnected
        case notBroadcasting
        case alreadyPaused
        case notPaused
        case controlTimedOut
        case extensionDiedBeforeStart
        case shimDylibMissing(String)
    }

    private typealias Connection = BroadcastControlTransport.Connection
    private typealias ConnectionID = BroadcastControlTransport.ConnectionID

    private struct ControlPeer {
        let connection: Connection
        var process: SpawnedAppex?
    }

    // MARK: Properties

    public nonisolated let simulator: String
    public nonisolated let hostBundleID: String
    public private(set) weak var delegate: (any GeistBroadcastSessionDelegate)?
    public private(set) var state: State = .idle
    public private(set) var activeBroadcasts: Set<Broadcast> = []
    public private(set) var lastBroadcastEndedNormally: Bool?
    public private(set) var lastExtensionTerminationError: ExtensionTerminationError?

    public nonisolated let socketPath: String
    public private(set) var micDeliveryMode: BroadcastMicDeliveryMode = .normal

    nonisolated let extensionContext: ExtensionContext

    private let simctlSetPath: String?
    private let mediaSources: BroadcastMediaSources
    private let frameTransport: BroadcastFrameTransport
    private let stager: any AppexStaging
    private let spawner: any AppexSpawning
    private var stagedAppex: Task<StagedAppex, Error>?
    private var lastStagedSourceHash: String?
    private let appShimDylibPath: String?
    private let extensionShimDylibPath: String?
    private let additionalExtensionDylibPaths: [String]
    private var controlTransport: BroadcastControlTransport?
    private var hostConnection: Connection?
    private var extensionConnection: Connection?
    private var controlPeers: [ConnectionID: ControlPeer] = [:]
    private var pendingBroadcast: Broadcast?
    // True once user has confirmed start (countdown ended). Until then, even
    // if the extension has connected via helloExtension, we don't send `begin`
    // — it sits parked. Cleared by userCancelledStart or session reset.
    private var userConfirmedStart: Bool = false
    private var launchTask: Task<Void, Never>?
    private var launchGeneration: UUID?
    private var attemptState = BroadcastAttemptState()
    private var lifecycleContinuations: [UUID: AsyncStream<BroadcastLifecycleEvent>.Continuation] = [:]
    private var spawnedAppex: SpawnedAppex?
    private var reapTasks: [UUID: Task<Void, Never>] = [:]
    private var disconnectedExtensionPeerPID: pid_t?
    private var micAuthPollTask: Task<Void, Never>?
    private var lastMicAuth: Bool = false
    private var pausedBroadcasts: Set<Broadcast> = []
    private var pendingControlRequests: [String: CheckedContinuation<Void, Error>] = [:]

    // MARK: Computed Properties

    public nonisolated var extensionAppexPath: String {
        extensionContext.appexPath
    }

    public var hasInFlightBroadcast: Bool {
        !activeBroadcasts.isEmpty
            || extensionConnection != nil
            || pendingBroadcast != nil
            || userConfirmedStart
    }

    public var extensionProcessID: pid_t? {
        spawnedAppex?.pid ?? extensionConnection?.peerPID
    }

    public var isPaused: Bool {
        guard let broadcast = activeBroadcasts.first else { return false }
        return pausedBroadcasts.contains(broadcast)
    }

    // MARK: Lifecycle

    public init(
        simulator: UUID,
        hostBundleID: String,
        simctlSetPath: String? = nil,
        extensionBundleID: String? = nil,
        videoCapture: VideoCaptureConfig = .simulatorScreen,
        micAudio: MicAudioConfig = .systemMicrophone,
        additionalExtensionDylibPaths: [String] = [],
        delegate: (any GeistBroadcastSessionDelegate)? = nil,
    ) async throws {
        let resolved = try await ExtensionDiscovery.resolve(
            simulator: simulator,
            hostBundleID: hostBundleID,
            extensionBundleID: extensionBundleID,
            simctlSetPath: simctlSetPath,
        )
        let appShim = try GeistBroadcastShimBundled.appShimDylibPath()
        let extShim = try GeistBroadcastShimBundled.extensionShimDylibPath()
        self.init(
            simulatorUDID: simulator.uuidString,
            hostBundleID: hostBundleID,
            extensionContext: ExtensionContext(
                bundleID: resolved.extensionBundleID,
                appexPath: resolved.appexPath,
            ),
            simctlSetPath: simctlSetPath,
            videoCapture: videoCapture,
            micAudio: micAudio,
            delegate: delegate,
            stager: AppexStager(),
            spawner: AppexSpawner(),
            appShimDylibPath: appShim,
            extensionShimDylibPath: extShim,
            additionalExtensionDylibPaths: additionalExtensionDylibPaths,
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
        extensionShimDylibPath: String? = nil,
        additionalExtensionDylibPaths: [String] = [],
    ) {
        simulator = simulatorUDID
        self.hostBundleID = hostBundleID
        self.extensionContext = extensionContext
        self.simctlSetPath = simctlSetPath
        socketPath = Self.conventionalSocketPath(
            simulator: simulatorUDID, bundleID: hostBundleID,
        )
        let frameTransport = BroadcastFrameTransport(path: Self.conventionalFrameSocketPath(
            simulator: simulatorUDID, bundleID: hostBundleID,
        ))
        self.frameTransport = frameTransport
        self.delegate = delegate
        self.stager = stager
        self.spawner = spawner
        let appexPath = extensionContext.appexPath
        // Staging captures only Sendable inputs and must not block the session actor.
        stagedAppex = Task.detached(priority: .utility) {
            try await stager.stage(appexAt: appexPath)
        }
        lastStagedSourceHash = Self.sourceBinaryHash(appexPath: appexPath)
        self.appShimDylibPath = appShimDylibPath
        self.extensionShimDylibPath = extensionShimDylibPath
        self.additionalExtensionDylibPaths = additionalExtensionDylibPaths
        mediaSources = BroadcastMediaSources(
            simulator: simulatorUDID, simctlSetPath: simctlSetPath,
            videoCapture: videoCapture, micAudio: micAudio, sink: frameTransport.sink,
        )
    }

    // MARK: Static Functions

    public static func broadcastCapableApps(
        simulator: UUID,
        simctlSetPath: String? = nil,
    ) async throws -> [BroadcastApp] {
        try await ExtensionDiscovery.broadcastCapableApps(
            simulator: simulator, simctlSetPath: simctlSetPath,
        )
    }

    /// Both the macOS host and the iOS simulator derive this path independently
    /// from (simulator UDID, host bundle ID) — there is no handshake. `/tmp/`
    /// is the only directory they see at the same filesystem location.
    private static func conventionalSocketPath(
        simulator: String, bundleID: String,
    ) -> String {
        "/tmp/geistcast-\(simulator)-\(bundleID).sock"
    }

    private static func conventionalFrameSocketPath(
        simulator: String, bundleID: String,
    ) -> String {
        "/tmp/geistcast-frames-\(simulator)-\(bundleID).sock"
    }

    private nonisolated static func sourceBinaryHash(appexPath: String) -> String? {
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

    private static func sessionError(_ error: any Error) -> any Error {
        if error is BroadcastFrameTransport.Error || error is BroadcastControlTransport.Error {
            return SessionError.alreadyStarted
        }
        guard let error = error as? UnixSocketListener.Error else { return error }
        return switch error {
        case let .socketCreate(code): SessionError.socketCreate(errno: code)
        case let .bind(code): SessionError.bind(errno: code)
        case let .listen(code): SessionError.listen(errno: code)
        }
    }

    // MARK: Functions

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
        try startTransports()
        transition(to: .listening)
        lastMicAuth = mediaSources.isMacOSMicAuthorized
        micAuthPollTask = Task { [weak self] in await self?.pollMicAuth() }
        let bundle = hostBundleID, path = socketPath
        log.notice("[Session \(bundle)] start: listening at \(path)")
    }

    public func stop() {
        for continuation in lifecycleContinuations.values {
            continuation.finish()
        }
        lifecycleContinuations.removeAll()
        let bundle = hostBundleID
        log.notice("[Session \(bundle)] stop")
        mediaSources.stopAll()
        micAuthPollTask?.cancel()
        micAuthPollTask = nil
        launchTask?.cancel()
        launchTask = nil
        launchGeneration = nil
        attemptState.discard()
        let stagingTask = stagedAppex
        stagedAppex = nil
        stagingTask?.cancel()
        cancelReaps()
        frameTransport.stop()
        controlTransport?.stop()
        hostConnection = nil
        extensionConnection = nil
        pausedBroadcasts.removeAll()
        transition(to: .stopped)
    }

    public func lifecycleEvents() -> AsyncStream<BroadcastLifecycleEvent> {
        let pair = AsyncStream<BroadcastLifecycleEvent>.makeStream()
        let id = UUID()
        lifecycleContinuations[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeLifecycleObserver(id) }
        }
        if let event = attemptState.processStarted(processID: extensionProcessID) {
            pair.continuation.yield(event)
        }
        if state == .stopped { pair.continuation.finish() }
        return pair.stream
    }

    public func snapshot() -> BroadcastSessionSnapshot {
        let lifecycle: BroadcastSessionSnapshot.Lifecycle = if isPaused { .paused }
        else if !activeBroadcasts.isEmpty { .recording }
        else if attemptState.id != nil { .starting }
        else { .idle }
        return BroadcastSessionSnapshot(
            lifecycle: lifecycle,
            micDelivery: micDeliveryMode,
            attemptID: attemptState.id,
            processID: extensionProcessID,
            attemptSequence: attemptState.sequence,
        )
    }

    @discardableResult
    public func stopBroadcast() -> BroadcastEnd? {
        let end = endAttempt(reason: .stopped)
        if let extensionClient = extensionConnection {
            send(.finish, to: extensionClient)
            extensionConnection = nil
        }
        for broadcast in activeBroadcasts {
            activeBroadcasts.remove(broadcast)
            pausedBroadcasts.remove(broadcast)
            delegate?.session(self, broadcastEnded: broadcast)
            if let hostConnection { send(.broadcastEnded(broadcast), to: hostConnection) }
        }
        if let pending = pendingBroadcast {
            if let hostConnection { send(.broadcastEnded(pending), to: hostConnection) }
            pendingBroadcast = nil
        }
        userConfirmedStart = false
        launchTask?.cancel()
        launchTask = nil
        launchGeneration = nil
        mediaSources.setMicEnabled(false)
        mediaSources.stopVideo()
        return end
    }

    public func pause() async throws {
        guard let broadcast = activeBroadcasts.first else {
            throw SessionError.notBroadcasting
        }
        guard let extensionClient = extensionConnection else {
            throw SessionError.notConnected
        }
        guard !pausedBroadcasts.contains(broadcast) else { throw SessionError.alreadyPaused }
        pausedBroadcasts.insert(broadcast)
        do {
            try await sendControl({ .pause(requestID: $0) }, to: extensionClient)
        } catch {
            pausedBroadcasts.remove(broadcast)
            throw error
        }
    }

    public func resume() async throws {
        guard let broadcast = activeBroadcasts.first else {
            throw SessionError.notBroadcasting
        }
        guard let extensionClient = extensionConnection else {
            throw SessionError.notConnected
        }
        guard pausedBroadcasts.contains(broadcast) else { throw SessionError.notPaused }
        pausedBroadcasts.remove(broadcast)
        do {
            try await sendControl({ .resume(requestID: $0) }, to: extensionClient)
        } catch {
            pausedBroadcasts.insert(broadcast)
            throw error
        }
    }

    /// Takes effect on the next broadcast; an in-flight broadcast keeps its
    /// existing mic source until it ends.
    public func setMicAudio(_ config: MicAudioConfig) {
        mediaSources.setMicAudio(config)
    }

    /// Re-stage the appex in the background if the source binary's hash has
    /// changed since we last staged. Skipped while a broadcast is in flight
    /// or pending — swapping out from under an active spawn would race.
    public func refreshStagedAppexIfNeeded() {
        guard state != .stopped else { return }
        guard pendingBroadcast == nil, activeBroadcasts.isEmpty else { return }
        let appexPath = extensionContext.appexPath
        guard let currentHash = Self.sourceBinaryHash(appexPath: appexPath) else { return }
        if currentHash == lastStagedSourceHash { return }
        lastStagedSourceHash = currentHash
        let stager = stager
        let previousStagingTask = stagedAppex
        // Staging captures only Sendable inputs and must not block the session actor.
        stagedAppex = Task.detached(priority: .utility) {
            try await stager.stage(appexAt: appexPath)
        }
        previousStagingTask?.cancel()
    }

    public func simulateMicAudioInterruption(_ active: Bool) async throws {
        try await setMicDelivery(active ? .notReady : .normal)
    }

    public func setMicDelivery(_ mode: BroadcastMicDeliveryMode) async throws {
        guard let attemptID = attemptState.id,
              !activeBroadcasts.isEmpty || userConfirmedStart && pendingBroadcast != nil
        else {
            micDeliveryMode = mode
            return
        }
        guard let extensionClient = extensionConnection else {
            if !activeBroadcasts.isEmpty { throw SessionError.notConnected }
            micDeliveryMode = mode
            return
        }
        try await sendControl({ .setMicDelivery(mode: mode.rawValue, requestID: $0) }, to: extensionClient)
        guard attemptState.id == attemptID else { return }
        micDeliveryMode = mode
    }

    private func startTransports() throws {
        let control = BroadcastControlTransport(path: socketPath)
        do {
            try control.start { [weak self, weak control] event in
                guard let control else { return }
                await self?.receive(event, from: control)
            }
            try frameTransport.start { [weak self] in
                Task { await self?.frameTransportFailed() }
            }
        } catch {
            control.stop()
            throw Self.sessionError(error)
        }
        controlTransport = control
    }

    private func receive(_ event: BroadcastControlTransport.Event, from transport: BroadcastControlTransport) {
        guard controlTransport === transport else { return }
        switch event {
        case let .connected(connection):
            guard state == .listening else { transport.shutdown(connection.id); return }
            controlPeers[connection.id] = ControlPeer(connection: connection)
            associateControlProcessIfKnown(connection)
        case let .messages(connection, messages):
            ingest(messages, from: connection)
        case let .disconnected(connection):
            connectionEnded(connection)
        case .listenerFailed:
            guard state == .listening else { return }
            stop()
        }
    }

    private func associateControlProcessIfKnown(_ connection: Connection) {
        guard let peer = controlPeers[connection.id], peer.process == nil,
              let process = spawnedAppex,
              connection.peerPID == process.pid else { return }
        controlPeers[connection.id]?.process = process
    }

    private func removeLifecycleObserver(_ id: UUID) {
        lifecycleContinuations.removeValue(forKey: id)
    }

    private func emitLifecycle(_ event: BroadcastLifecycleEvent) {
        for continuation in lifecycleContinuations.values {
            continuation.yield(event)
        }
    }

    private func sendControl(
        _ message: (String) -> WireMessage,
        to connection: Connection,
    ) async throws {
        let requestID = UUID().uuidString
        try await withCheckedThrowingContinuation { continuation in
            pendingControlRequests[requestID] = continuation
            send(message(requestID), to: connection)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                await self?.timeOutControlRequest(requestID)
            }
        }
    }

    private func timeOutControlRequest(_ requestID: String) {
        pendingControlRequests.removeValue(forKey: requestID)?.resume(throwing: SessionError.controlTimedOut)
    }

    private func transition(to newState: State) {
        state = newState
        delegate?.session(self, stateChanged: newState)
    }

    private func connectionEnded(_ connection: Connection) {
        let process = controlPeers.removeValue(forKey: connection.id)?.process
        let peerPID = connection.peerPID
        if hostConnection == connection {
            log.notice("[Session \(hostBundleID)] host connection closed (connection=\(String(describing: connection.id)))")
            hostConnection = nil
        }
        if extensionConnection == connection {
            log.notice("[Session \(hostBundleID)] extension connection closed (connection=\(String(describing: connection.id))) activeBroadcasts=\(activeBroadcasts.count) pending=\(pendingBroadcast != nil)")
            extensionConnection = nil
            let requests = pendingControlRequests.values
            pendingControlRequests.removeAll()
            for request in requests {
                request.resume(throwing: SessionError.notConnected)
            }
            // Extension going away with an active broadcast is the only
            // signal we have that the broadcast actually ended (extension
            // process died for any reason). Fire the delegate and clean up.
            for broadcast in activeBroadcasts {
                endAttempt(reason: .disconnected, processID: process?.pid ?? peerPID)
                activeBroadcasts.remove(broadcast)
                pausedBroadcasts.remove(broadcast)
                delegate?.session(self, broadcastEnded: broadcast)
                if let hostConnection { send(.broadcastEnded(broadcast), to: hostConnection) }
            }
            if let pending = pendingBroadcast {
                endAttempt(reason: .disconnected, processID: process?.pid ?? peerPID)
                delegate?.session(self,
                                  broadcastFailedToStart: pending,
                                  error: SessionError.extensionDiedBeforeStart)
                if let hostConnection { send(.broadcastEnded(pending), to: hostConnection) }
                pendingBroadcast = nil
            }
            userConfirmedStart = false
            mediaSources.setMicEnabled(false)
            mediaSources.stopVideo()
            if let process {
                scheduleDisconnectedExtensionReap(process)
            } else {
                disconnectedExtensionPeerPID = peerPID
            }
        }
    }

    private func scheduleDisconnectedExtensionReap(_ process: SpawnedAppex) {
        cancelReaps()
        let spawner = spawner
        reapTasks[process.generation] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { await spawner.terminate(process) }
            await self?.reapFinished(generation: process.generation)
        }
    }

    private func cancelReaps() {
        for task in reapTasks.values {
            task.cancel()
        }
    }

    private func reapFinished(generation: UUID) {
        reapTasks.removeValue(forKey: generation)
    }

    private func ingest(_ messages: [WireMessage], from connection: Connection) {
        guard state == .listening else { return }
        for message in messages {
            ingest(message, from: connection)
        }
    }

    private func ingest(_ message: WireMessage, from connection: Connection) {
        switch message {
        case .helloHost:
            connectHost(connection)

        case let .helloExtension(extensionBundleID):
            connectExtension(connection, bundleID: extensionBundleID)

        case let .userPressedStart(micEnabled):
            confirmStart(micEnabled: micEnabled)

        case .userCancelledStart:
            cancelStart()

        case .userPressedStop:
            requestFinish()

        case let .userToggledMic(enabled):
            log.notice("[Session \(hostBundleID)] userToggledMic enabled=\(enabled)")
            mediaSources.setMicEnabled(enabled)

        case let .broadcastStarted(broadcast):
            recordStart(broadcast, from: connection)

        case let .broadcastEnded(broadcast):
            recordEnd(broadcast, from: connection)

        case let .extensionTerminated(domain, code, message):
            recordFailure(ExtensionTerminationError(domain: domain, code: code, message: message), from: connection)

        case let .controlAck(requestID):
            pendingControlRequests.removeValue(forKey: requestID)?.resume()

        case .begin, .finish, .pause, .resume, .setMicAudioReadiness, .setMicDelivery, .state:
            break
        }
    }

    private func connectHost(_ connection: Connection) {
        log.notice("[Session \(hostBundleID)] helloHost connection=\(String(describing: connection.id)) recording=\(!activeBroadcasts.isEmpty)")
        hostConnection = connection
        let currentBroadcast = activeBroadcasts.first
        send(.state(recording: currentBroadcast != nil,
                    broadcast: currentBroadcast,
                    micEnabled: mediaSources.isMicAttached,
                    macOSMicAuthorized: mediaSources.isMacOSMicAuthorized,
                    micEnabledByDefault: mediaSources.isMicEnabledByDefault),
             to: connection)
    }

    private func connectExtension(_ connection: Connection, bundleID extensionBundleID: String) {
        log.notice("[Session \(hostBundleID)] helloExtension bundle=\(extensionBundleID) connection=\(String(describing: connection.id)) userConfirmedStart=\(userConfirmedStart) prevExtFD=\(String(describing: extensionConnection?.id))")
        if let old = extensionConnection {
            controlTransport?.shutdown(old.id)
        }
        cancelReaps()
        associateControlProcessIfKnown(connection)
        disconnectedExtensionPeerPID = nil
        extensionConnection = connection
        announceProcess()
        if userConfirmedStart, let broadcast = pendingBroadcast {
            send(.begin(broadcast, micDeliveryMode: micDeliveryMode), to: connection)
        }
        delegate?.session(self, extensionConnectedFor: extensionBundleID)
    }

    private func confirmStart(micEnabled: Bool) {
        log.notice("[Session \(hostBundleID)] userPressedStart micEnabled=\(micEnabled) extensionClient=\(String(describing: extensionConnection?.id))")
        armBroadcast()
        userConfirmedStart = true
        if let extensionClient = extensionConnection, let broadcast = pendingBroadcast {
            send(.begin(broadcast, micDeliveryMode: micDeliveryMode), to: extensionClient)
        }
        mediaSources.startVideo()
        if micEnabled {
            mediaSources.setMicEnabled(true)
        }
    }

    private func cancelStart() {
        endAttempt(reason: .cancelled)
        log.notice("[Session \(hostBundleID)] userCancelledStart")
        launchTask?.cancel()
        launchTask = nil
        launchGeneration = nil
        if let extensionClient = extensionConnection {
            controlTransport?.shutdown(extensionClient.id)
            extensionConnection = nil
        }
        pendingBroadcast = nil
        userConfirmedStart = false
        mediaSources.setMicEnabled(false)
        mediaSources.stopVideo()
    }

    private func requestFinish() {
        log.notice("[Session \(hostBundleID)] userPressedStop extensionClient=\(String(describing: extensionConnection?.id))")
        if let extensionClient = extensionConnection {
            send(.finish, to: extensionClient)
        }
        mediaSources.setMicEnabled(false)
        mediaSources.stopVideo()
    }

    private func recordStart(_ broadcast: Broadcast, from connection: Connection) {
        if attemptState.id == nil {
            _ = attemptState.begin(processTermination: spawnedAppex?.termination)
        }
        announceProcess()
        activeBroadcasts.insert(broadcast)
        delegate?.session(self, broadcastStarted: broadcast)
        pendingBroadcast = nil
        if let hostConnection, connection != hostConnection {
            send(.broadcastStarted(broadcast), to: hostConnection)
        }
    }

    private func recordEnd(_ broadcast: Broadcast, from connection: Connection) {
        let wasActive = activeBroadcasts.remove(broadcast) != nil
        pausedBroadcasts.remove(broadcast)
        guard wasActive else { return }
        endAttempt(reason: .finished)
        delegate?.session(self, broadcastEnded: broadcast)
        if let hostConnection, connection != hostConnection {
            send(.broadcastEnded(broadcast), to: hostConnection)
        }
        mediaSources.setMicEnabled(false)
        mediaSources.stopVideo()
    }

    private func recordFailure(_ error: ExtensionTerminationError, from connection: Connection) {
        lastExtensionTerminationError = error
        let processID = connection.peerPID ?? controlPeers[connection.id]?.process?.pid
        endAttempt(reason: .failed(error), processID: processID)
        if let broadcast = activeBroadcasts.first {
            activeBroadcasts.remove(broadcast)
            pausedBroadcasts.remove(broadcast)
            delegate?.session(self, broadcast: broadcast, terminatedWithError: error)
            if let hostConnection { send(.broadcastEnded(broadcast), to: hostConnection) }
        } else if let pending = pendingBroadcast {
            delegate?.session(self, broadcastFailedToStart: pending, error: error)
            if let hostConnection { send(.broadcastEnded(pending), to: hostConnection) }
            pendingBroadcast = nil
        }
        userConfirmedStart = false
        mediaSources.setMicEnabled(false)
        mediaSources.stopVideo()
    }

    @discardableResult
    private func endAttempt(reason: BroadcastEnd.Reason, processID: Int32? = nil) -> BroadcastEnd? {
        guard let end = attemptState.end(
            reason: reason, processID: processID ?? extensionProcessID,
        ) else { return nil }
        lastBroadcastEndedNormally = reason == .finished
        emitLifecycle(.ended(end))
        micDeliveryMode = .normal
        return end
    }

    private func announceProcess() {
        guard let event = attemptState.announce(processID: extensionProcessID) else { return }
        emitLifecycle(event)
    }

    private func armBroadcast() {
        guard pendingBroadcast == nil else { return }
        cancelReaps()
        disconnectedExtensionPeerPID = nil
        lastBroadcastEndedNormally = nil
        lastExtensionTerminationError = nil
        spawnedAppex = nil
        let broadcast = Broadcast(
            simulatorUDID: simulator,
            hostAppBundleID: hostBundleID,
            extensionBundleID: extensionContext.bundleID,
            startedAt: Date(),
        )
        pendingBroadcast = broadcast
        log.notice("[Session \(hostBundleID)] armBroadcast: spawning extension \(extensionContext.bundleID)")
        let attempt = attemptState.begin()
        launchGeneration = attempt.id
        launchTask = Task { [weak self] in await self?.launchExtension(attempt: attempt) }
    }

    private func pollMicAuth() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            if Task.isCancelled { return }
            let current = mediaSources.isMacOSMicAuthorized
            if current != lastMicAuth {
                lastMicAuth = current
                let bundle = hostBundleID
                log.notice("[Session \(bundle)] macOS mic auth changed → \(current)")
                if let hostConnection {
                    let currentBroadcast = activeBroadcasts.first
                    send(.state(recording: currentBroadcast != nil,
                                broadcast: currentBroadcast,
                                micEnabled: mediaSources.isMicAttached,
                                macOSMicAuthorized: current,
                                micEnabledByDefault: mediaSources.isMicEnabledByDefault),
                         to: hostConnection)
                }
            }
        }
    }

    private func launchExtension(attempt: BroadcastAttemptState.Attempt) async {
        let generation = attempt.id
        do {
            guard launchGeneration == generation,
                  !Task.isCancelled,
                  state == .listening else { return }
            guard let stagingTask = stagedAppex else { return }
            let staged = try await stagingTask.value
            guard launchGeneration == generation,
                  !Task.isCancelled,
                  state == .listening else { return }
            let process = try await spawner.spawn(
                stagedAppex: staged,
                simulatorUDID: simulator,
                simctlSetPath: simctlSetPath,
                environment: extensionLaunchEnv(),
            )
            attempt.forwardTermination(from: process.termination)
            guard launchGeneration == generation,
                  !Task.isCancelled,
                  state == .listening
            else {
                await spawner.terminate(process)
                return
            }
            spawnedAppex = process
            announceProcess()
            for peer in controlPeers.values {
                associateControlProcessIfKnown(peer.connection)
            }
            if disconnectedExtensionPeerPID == process.pid {
                disconnectedExtensionPeerPID = nil
                scheduleDisconnectedExtensionReap(process)
            }
            finishLaunch(generation: generation)
        } catch {
            guard launchGeneration == generation else { return }
            log.warn("Session: launchExtension failed: \(error)")
            let failure = error as NSError
            endAttempt(reason: .failed(ExtensionTerminationError(
                domain: failure.domain, code: failure.code, message: failure.localizedDescription,
            )))
            if let pending = pendingBroadcast {
                delegate?.session(self, broadcastFailedToStart: pending, error: error)
            }
            pendingBroadcast = nil
            userConfirmedStart = false
            finishLaunch(generation: generation)
        }
    }

    private func finishLaunch(generation: UUID) {
        guard launchGeneration == generation else { return }
        launchTask = nil
        launchGeneration = nil
    }

    private func extensionLaunchEnv() throws -> [String: String] {
        var env: [String: String] = [
            "GEISTCAST_SOCKET": socketPath,
            "GEISTCAST_HOST_SOCKET": frameTransport.path,
        ]
        let dylibPaths = additionalExtensionDylibPaths + [extensionShimDylibPath].compactMap(\.self)
        for path in dylibPaths {
            guard FileManager.default.fileExists(atPath: path) else {
                throw SessionError.shimDylibMissing(path)
            }
        }
        if !dylibPaths.isEmpty { env["DYLD_INSERT_LIBRARIES"] = dylibPaths.joined(separator: ":") }
        env["OS_ACTIVITY_DT_MODE"] = "YES"
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

    private func frameTransportFailed() {
        guard state == .listening else { return }
        stop()
    }

    private func send(_ message: WireMessage, to connection: Connection) {
        controlTransport?.send(message, to: connection.id)
    }
}
