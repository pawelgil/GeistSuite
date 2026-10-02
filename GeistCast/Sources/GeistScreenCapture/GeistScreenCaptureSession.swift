import Darwin
import Foundation
import GeistScreenCaptureShimCore

public actor GeistScreenCaptureSession {
    // MARK: Nested Types

    public enum Error: Swift.Error, Equatable {
        case alreadyStarted
        case bind(errno: Int32)
        case listen(errno: Int32)
        case socketCreate(errno: Int32)
    }

    // MARK: Properties

    public nonisolated let simulator: UUID
    public nonisolated let socketPath: String

    private let coordinator: CaptureCoordinator
    private let writer: SocketFrameWriter
    private let acceptQueue = DispatchQueue(label: "com.geist.screencapture.accept")
    private let connectionQueue = DispatchQueue(
        label: "com.geist.screencapture.connection",
        attributes: .concurrent
    )
    private var acceptSource: DispatchSourceRead?
    private var listenerFD: Int32 = -1
    private var activeFD: Int32?
    private var connectionGeneration: UInt64 = 0

    // MARK: Lifecycle

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

    // MARK: Static Functions

    private nonisolated static func openListener(path: String) throws -> Int32 {
        unlinkSocket(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Error.socketCreate(errno: errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw Error.bind(errno: ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
            path.utf8CString.withUnsafeBytes { source in
                bytes.copyBytes(from: source)
            }
        }
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let value = errno
            close(fd)
            throw Error.bind(errno: value)
        }
        chmod(path, S_IRUSR | S_IWUSR)
        guard Darwin.listen(fd, 4) == 0 else {
            let value = errno
            close(fd)
            unlinkSocket(path)
            throw Error.listen(errno: value)
        }
        return fd
    }

    private nonisolated static func acceptClient(_ listener: Int32) -> Int32? {
        let fd = Darwin.accept(listener, nil, nil)
        guard fd >= 0 else { return nil }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    private nonisolated static func read(_ fd: Int32, count: Int) -> Data? {
        var data = Data(count: count)
        let readCount = data.withUnsafeMutableBytes { bytes -> Int in
            guard let base = bytes.baseAddress else { return 0 }
            var offset = 0
            while offset < count {
                let result = Darwin.read(fd, base.advanced(by: offset), count - offset)
                guard result > 0 else { return -1 }
                offset += result
            }
            return offset
        }
        return readCount == count ? data : nil
    }

    @discardableResult
    private nonisolated static func respond(_ status: Int32, to fd: Int32) -> Bool {
        var response = geist_sck_start_response_t(
            magic: GEIST_SCK_WIRE_MAGIC,
            status: status
        )
        return withUnsafeBytes(of: &response) { bytes in
            guard let base = bytes.baseAddress else { return true }
            var offset = 0
            while offset < bytes.count {
                let result = Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
                guard result > 0 else { return false }
                offset += result
            }
            return true
        }
    }

    private nonisolated static func close(_ fd: Int32) {
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }

    private nonisolated static func isDisconnected(_ fd: Int32) -> Bool {
        var byte: UInt8 = 0
        let result = Darwin.recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        return result == 0 || result < 0 && errno != EAGAIN && errno != EWOULDBLOCK
    }

    private nonisolated static func unlinkSocket(_ path: String) {
        var metadata = stat()
        guard lstat(path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFSOCK
        else { return }
        unlink(path)
    }

    // MARK: Functions

    public func start() async throws {
        guard listenerFD < 0 else { throw Error.alreadyStarted }
        let listener = try Self.openListener(path: socketPath)
        listenerFD = listener
        startAccepting(listener)
    }

    public func stop() async {
        await coordinator.stop()
        writer.close()
        activeFD = nil
        connectionGeneration &+= 1
        if listenerFD >= 0 {
            acceptSource?.cancel()
            acceptSource = nil
            Self.close(listenerFD)
            listenerFD = -1
            Self.unlinkSocket(socketPath)
        }
    }

    private func startAccepting(_ listener: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: acceptQueue)
        source.setEventHandler { [weak self] in
            guard let client = Self.acceptClient(listener) else { return }
            self?.readRequest(from: client)
        }
        source.resume()
        acceptSource = source
    }

    private nonisolated func readRequest(from fd: Int32) {
        connectionQueue.async { [weak self] in
            guard let data = Self.read(fd, count: StartRequest.byteCount) else {
                Self.close(fd)
                return
            }
            Task { await self?.handleRequest(data, from: fd) }
        }
    }

    private func handleRequest(_ data: Data, from fd: Int32) async {
        let request: StartRequest
        do {
            request = try StartRequest.decode(data)
        } catch StartRequest.Error.notSupported {
            Self.respond(GEIST_SCK_STATUS_NOT_SUPPORTED, to: fd)
            Self.close(fd)
            return
        } catch {
            Self.respond(GEIST_SCK_STATUS_INVALID_REQUEST, to: fd)
            Self.close(fd)
            return
        }

        if let activeFD, Self.isDisconnected(activeFD) {
            self.activeFD = nil
            connectionGeneration &+= 1
            await coordinator.stop()
            writer.close()
        }
        guard activeFD == nil else {
            Self.respond(GEIST_SCK_STATUS_BUSY, to: fd)
            Self.close(fd)
            return
        }
        do {
            try await coordinator.start(outputs: request.outputs)
        } catch CaptureCoordinator.Error.busy {
            Self.respond(GEIST_SCK_STATUS_BUSY, to: fd)
            Self.close(fd)
            return
        } catch {
            Self.respond(GEIST_SCK_STATUS_FAILED, to: fd)
            Self.close(fd)
            return
        }

        guard Self.respond(GEIST_SCK_STATUS_OK, to: fd) else {
            await coordinator.stop()
            Self.close(fd)
            return
        }
        activeFD = fd
        connectionGeneration &+= 1
        let generation = connectionGeneration
        writer.bind(fd)
        watchForDisconnect(fd, generation: generation)
    }

    private nonisolated func watchForDisconnect(_ fd: Int32, generation: UInt64) {
        connectionQueue.async { [weak self] in
            var byte: UInt8 = 0
            _ = Darwin.read(fd, &byte, 1)
            Task { await self?.connectionClosed(fd, generation: generation) }
        }
    }

    private func connectionClosed(_ fd: Int32, generation: UInt64) async {
        guard activeFD == fd, connectionGeneration == generation else { return }
        activeFD = nil
        connectionGeneration &+= 1
        await coordinator.stop()
        writer.close()
    }
}
