import Foundation

public struct ProcessInvocation: Sendable, Equatable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]

    public init(executable: String, arguments: [String], environment: [String: String] = [:]) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }
}

public struct ProcessResult: Sendable, Equatable {
    public let exitStatus: Int32
    public let stdout: Data
    public let stderr: Data

    public init(exitStatus: Int32, stdout: Data, stderr: Data) {
        self.exitStatus = exitStatus
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol ProcessRunner: Sendable {
    func run(_ invocation: ProcessInvocation) async throws -> ProcessResult
}

public struct LiveProcessRunner: ProcessRunner {

    public enum LiveProcessError: Error, Equatable {
        case launchFailed(String)
    }

    public init() {}

    public func run(_ invocation: ProcessInvocation) async throws -> ProcessResult {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: invocation.executable)
        task.arguments = invocation.arguments
        if !invocation.environment.isEmpty {
            task.environment = ProcessInfo.processInfo.environment
                .merging(invocation.environment) { _, new in new }
        }
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe

        async let stdoutData: Data = readAllData(handle: outPipe.fileHandleForReading)
        async let stderrData: Data = readAllData(handle: errPipe.fileHandleForReading)

        let status: Int32
        do {
            status = try await withCheckedThrowingContinuation { continuation in
                task.terminationHandler = { proc in
                    continuation.resume(returning: proc.terminationStatus)
                }
                do {
                    try task.run()
                } catch {
                    task.terminationHandler = nil
                    continuation.resume(throwing: LiveProcessError.launchFailed("\(error)"))
                }
            }
        } catch {
            // Send EOF to the reader tasks so they don't block on
            // availableData forever waiting for a writer that never wrote.
            try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForWriting.close()
            _ = await stdoutData
            _ = await stderrData
            throw error
        }
        return ProcessResult(
            exitStatus: status,
            stdout: await stdoutData,
            stderr: await stderrData
        )
    }
}

private func readAllData(handle: FileHandle) async -> Data {
    await Task.detached(priority: .userInitiated) {
        var data = Data()
        while case let chunk = handle.availableData, !chunk.isEmpty {
            data.append(chunk)
        }
        return data
    }.value
}
