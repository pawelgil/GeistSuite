import Darwin
import Foundation
import GeistScreenCaptureShimCore

public actor GeistScreenCaptureSession {
    public enum Error: Swift.Error, Equatable {
        case alreadyStarted
        case bind(errno: Int32)
        case listen(errno: Int32)
        case socketCreate(errno: Int32)
    }

    public nonisolated let simulator: UUID
    public nonisolated let socketPath: String

    private let coordinator: CaptureCoordinator
    private let writer: SocketFrameWriter
    private let connectionQueue = DispatchQueue(
        label: "com.geist.screencapture.connection",
        attributes: .concurrent
    )
    private var listener: CaptureListener?
    private var activeConnection: CaptureConnection?
    private var pendingConnections: [UUID: CaptureConnection] = [:]
    private var generation = UUID()
    private var transition: Task<Void, Never>?
    private var stopping = false

    public init(
        simulator: UUID,
        setPath: String? = nil
    ) throws {
        let writer = SocketFrameWriter()
        self.simulator = simulator
        socketPath = "/tmp/geistsck-\(simulator.uuidString.lowercased()).sock"
        self.writer = writer
        coordinator = CaptureCoordinator(
            screen: SimulatorScreenFrameSource(simulator: simulator, setPath: setPath),
            microphone: SystemMicrophoneCapture(),
            writer: writer
        )
    }

    init(
        simulator: UUID,
        socketPath: String,
        coordinator: CaptureCoordinator,
        writer: SocketFrameWriter
    ) {
        self.simulator = simulator
        self.socketPath = socketPath
        self.coordinator = coordinator
        self.writer = writer
    }

    deinit {
        listener?.stop()
        for client in pendingConnections.values { client.shutdown() }
        activeConnection?.shutdown()
        writer.close()
    }

    public func start() async throws {
        guard listener == nil, !stopping else { throw Error.alreadyStarted }
        generation = UUID()
        let epoch = generation
        listener = try CaptureListener(path: socketPath) { [weak self] client in
            Task { await self?.accept(client, generation: epoch) }
        }
        log.notice("ScreenCaptureKit listener started: \(simulator)")
    }

    public func stop() async {
        if stopping {
            await transition?.value
            return
        }
        stopping = true
        generation = UUID()
        listener?.stop()
        listener = nil
        for client in pendingConnections.values { client.shutdown() }
        pendingConnections.removeAll()
        activeConnection?.shutdown()
        let cleanup = enqueue { await self.stopCapture() }
        await cleanup.value
        stopping = false
    }

    @discardableResult
    private func enqueue(_ operation: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        let previous = transition
        let task = Task {
            await previous?.value
            await operation()
        }
        transition = task
        return task
    }

    private func accept(_ client: CaptureConnection, generation: UUID) {
        guard listener != nil, self.generation == generation,
              pendingConnections.count < 8
        else {
            client.shutdown()
            return
        }
        let id = UUID()
        pendingConnections[id] = client
        connectionQueue.async { [weak self] in
            let request = client.read(count: StartRequest.byteCount)
            Task { await self?.received(request, from: client, id: id, generation: generation) }
        }
    }

    private func received(_ data: Data?, from client: CaptureConnection, id: UUID, generation: UUID) {
        guard pendingConnections[id] != nil else { return }
        enqueue {
            await self.handleRequest(data, from: client, id: id, generation: generation)
        }
    }

    private func handleRequest(_ data: Data?, from client: CaptureConnection, id: UUID, generation: UUID) async {
        defer { pendingConnections.removeValue(forKey: id) }
        guard self.generation == generation, let data else {
            client.shutdown()
            return
        }
        let request: StartRequest
        do {
            request = try StartRequest.decode(data)
        } catch StartRequest.Error.notSupported {
            reject(client, status: GEIST_SCK_STATUS_NOT_SUPPORTED)
            return
        } catch {
            reject(client, status: GEIST_SCK_STATUS_INVALID_REQUEST)
            return
        }
        if let activeConnection, activeConnection.isDisconnected {
            await stopCapture()
        }
        guard self.generation == generation else {
            client.shutdown()
            return
        }
        guard activeConnection == nil else {
            reject(client, status: GEIST_SCK_STATUS_BUSY)
            return
        }
        do {
            try await coordinator.start(outputs: request.outputs)
        } catch {
            log.warn("ScreenCaptureKit capture failed: \(error)")
            reject(client, status: GEIST_SCK_STATUS_FAILED)
            return
        }
        guard self.generation == generation, writer.bind(client, initialData: response(GEIST_SCK_STATUS_OK)) else {
            await coordinator.stop()
            client.shutdown()
            return
        }
        activeConnection = client
        await coordinator.activate()
        connectionQueue.async { [weak self] in
            client.waitForDisconnect()
            Task { await self?.disconnected(client) }
        }
    }

    private func disconnected(_ client: CaptureConnection) {
        enqueue {
            await self.stopCapture(ifActive: client)
        }
    }

    private func stopCapture(ifActive client: CaptureConnection) async {
        guard activeConnection === client else { return }
        await stopCapture()
    }

    private func stopCapture() async {
        activeConnection?.shutdown()
        writer.close()
        await coordinator.stop()
        activeConnection = nil
    }

    private func reject(_ client: CaptureConnection, status: Int32) {
        _ = client.write(response(status))
        client.shutdown()
    }

    private func response(_ status: Int32) -> Data {
        var response = geist_sck_start_response_t(magic: GEIST_SCK_WIRE_MAGIC, status: status)
        return withUnsafeBytes(of: &response) { Data($0) }
    }
}
