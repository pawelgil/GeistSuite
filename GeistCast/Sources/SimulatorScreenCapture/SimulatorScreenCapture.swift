internal import CoreSimulatorPrivate
import Foundation
import IOSurface
import Synchronization

/// @unchecked Sendable: `device` is an ObjC `SimDevice` (not formally
/// Sendable) but is `let`-immutable post-init; `registrar` is protected
/// by `Mutex`.
public final class SimulatorScreenCapture: @unchecked Sendable {
    public typealias FrameHandler = @Sendable (ScreenFrame) -> Void

    private let device: SimDevice
    private let emitter: FrameEmitter
    private let registrarUUID = UUID()
    private let registrarQueue = DispatchQueue(label: "geistcast.simulator-capture.callbacks", qos: .userInteractive)
    private let registrar = Mutex<ScreenCallbackRegistrar?>(nil)

    /// `setPath` is the CoreSimulator device set (e.g. a noggenfogger
    /// session sandbox); `nil` uses the Xcode default set.
    public init(udid: UUID, setPath: String? = nil) throws {
        guard NSClassFromString("SimServiceContext") != nil else {
            throw SimulatorScreenError.frameworkUnavailable
        }
        let developerDir = try Self.resolveDeveloperDir()
        let context: SimServiceContext
        do {
            context = try SimServiceContext(forDeveloperDir: developerDir)
        } catch {
            throw SimulatorScreenError.serviceContextFailed(error)
        }
        let deviceSet: SimDeviceSet
        do {
            if let setPath { deviceSet = try context.deviceSet(withPath: setPath) }
            else { deviceSet = try context.defaultDeviceSet() }
        } catch {
            throw SimulatorScreenError.deviceSetFailed(error)
        }
        guard let resolved = deviceSet.devicesByUDID?[udid] else {
            throw SimulatorScreenError.deviceNotFound(udid)
        }
        guard let surface = SurfaceLocator.primarySurface(of: resolved) else {
            throw SimulatorScreenError.noIOSurface
        }
        self.device = resolved
        self.emitter = FrameEmitter(surface: surface)
    }

    /// Replaces any prior handler.
    public func start(deliveringTo handler: @escaping FrameHandler) throws {
        let emitter = self.emitter
        let fresh = try ScreenCallbackRegistrar(
            device: device,
            queue: registrarQueue,
            uuid: registrarUUID,
            frameHandler: { emitter.notifyFrame() },
            surfaceSwapHandler: { surface in emitter.replaceSurface(surface) }
        )
        registrar.withLock { $0 = fresh }
        // Closes the race between grabbing the initial surface in init and
        // registering the swap callback above: a swap during that gap would
        // have updated the surface without us knowing.
        if let surface = SurfaceLocator.primarySurface(of: device) {
            emitter.replaceSurface(surface)
        }
        emitter.start(receiver: handler)
    }

    /// Synchronous + idempotent.
    public func stop() {
        let previous = registrar.withLock { current -> ScreenCallbackRegistrar? in
            let r = current
            current = nil
            return r
        }
        previous?.invalidate()
        emitter.stop()
    }

    deinit {
        stop()
    }

    private static func resolveDeveloperDir() throws -> String {
        if let envDir = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !envDir.isEmpty {
            return envDir
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SimulatorScreenError.frameworkUnavailable
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let out = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !out.isEmpty
        else { throw SimulatorScreenError.frameworkUnavailable }
        return out
    }
}
