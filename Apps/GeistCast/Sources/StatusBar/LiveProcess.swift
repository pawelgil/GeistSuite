import Foundation

struct LiveProcess: ProcessRunning {
    init() {}

    func run(executable: String, arguments: [String]) async throws -> Data {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
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
                    continuation.resume(throwing: error)
                }
            }
        } catch {
            try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForWriting.close()
            _ = await stdoutData
            _ = await stderrData
            throw error
        }

        return try LiveProcessError.unwrap(
            status: status,
            stdout: await stdoutData,
            stderr: await stderrData
        )
    }
}

enum LiveProcessError: Error, Equatable {
    case nonzeroExit(status: Int, stdout: String, stderr: String)

    static func unwrap(status: Int32, stdout: Data, stderr: Data) throws -> Data {
        guard status == 0 else {
            throw LiveProcessError.nonzeroExit(
                status: Int(status),
                stdout: String(decoding: stdout, as: UTF8.self),
                stderr: String(decoding: stderr, as: UTF8.self)
            )
        }
        return stdout
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
