import Dispatch

@globalActor
actor CameraActor: GlobalActor {
    static let shared = CameraActor()

    nonisolated let serialQueue = DispatchSerialQueue(label: "geistcam.camera",
                                                       qos: .userInitiated)

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        serialQueue.asUnownedSerialExecutor()
    }

    // Bridge from a context known at runtime to be running on serialQueue
    // (e.g. AVF delegate callbacks we configured to use this queue) into the
    // global actor's isolation. Mirrors the unsafeBitCast pattern used
    // internally by MainActor.assumeIsolated.
    static func assumeIsolated<T: Sendable>(
        _ operation: @CameraActor () throws -> T,
        file: StaticString = #fileID, line: UInt = #line
    ) rethrows -> T {
        typealias YesActor = @CameraActor () throws -> T
        typealias NoActor = () throws -> T
        shared.preconditionIsolated(file: file, line: line)
        return try withoutActuallyEscaping(operation) {
            (_ fn: @escaping YesActor) throws -> T in
            let rawFn = unsafeBitCast(fn, to: NoActor.self)
            return try rawFn()
        }
    }
}
