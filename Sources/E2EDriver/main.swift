import Foundation
import Geist
import Synchronization

setvbuf(stdout, nil, _IONBF, 0)
setvbuf(stderr, nil, _IONBF, 0)

// Usage:
//   e2e-driver <sim-udid> <host-bundle-id> [--set <path>]
//                                          [--mic-file <path>] [--no-mic]

final class Logger: GeistBroadcastSessionDelegate, Sendable {
    private let onBroadcastStartedBox = Mutex<(@Sendable () -> Void)?>(nil)

    func setOnBroadcastStarted(_ handler: @escaping @Sendable () -> Void) {
        onBroadcastStartedBox.withLock { $0 = handler }
    }

    func session(_: GeistBroadcastSession, broadcastStarted: Broadcast) {
        print("[driver] broadcastStarted: \(broadcastStarted.extensionBundleID) at \(broadcastStarted.startedAt)")
        let handler = onBroadcastStartedBox.withLock { $0 }
        handler?()
    }
    func session(_: GeistBroadcastSession, broadcastEnded: Broadcast) {
        print("[driver] broadcastEnded: \(broadcastEnded.extensionBundleID)")
    }
    func session(_: GeistBroadcastSession,
                 broadcastFailedToStart broadcast: Broadcast,
                 error: Error) {
        print("[driver] broadcastFailedToStart: \(error)")
    }
    func session(_: GeistBroadcastSession, stateChanged: GeistBroadcastSession.State) {
        print("[driver] state -> \(stateChanged)")
    }
}

private func stringArg(_ args: [String], _ flag: String) -> String? {
    guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
    return args[idx + 1]
}

private func doubleArg(_ args: [String], _ flag: String) -> Double? {
    guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
    return Double(args[idx + 1])
}

private func micConfig(from args: [String]) -> MicSource {
    if args.contains("--no-mic") { return .disabled }
    if let path = stringArg(args, "--mic-file") {
        return .mediaFile(URL(fileURLWithPath: path))
    }
    return .systemMicrophone
}

@MainActor
func run() async throws {
    let args = CommandLine.arguments
    let valueFlags: Set<String> = ["--set", "--mic-file", "--interrupt-at", "--interrupt-clear-at"]
    var positional: [String] = []
    var skipNext = false
    for arg in args.dropFirst() {
        if skipNext { skipNext = false; continue }
        if valueFlags.contains(arg) { skipNext = true; continue }
        if arg.hasPrefix("--") { continue }
        positional.append(arg)
    }
    guard positional.count >= 2,
          let udid = UUID(uuidString: positional[0])
    else {
        FileHandle.standardError.write(Data(
            "usage: e2e-driver <sim-udid> <host-bundle-id> [--set <path>] [--mic-file <path>] [--no-mic]\n".utf8))
        exit(1)
    }
    let hostBundleID = positional[1]
    let setPath = stringArg(args, "--set")
    let mic = micConfig(from: args)
    print("[driver] sim=\(udid) host=\(hostBundleID) set=\(setPath ?? "<default>") mic=\(describe(mic))")

    let logger = Logger()
    let session = try await GeistBroadcastSession(
        simulator: udid,
        hostBundleID: hostBundleID,
        simctlSetPath: setPath,
        micAudio: mic,
        delegate: logger
    )
    try await session.start()
    let env = try session.injectionEnv()
    print("[driver] session listening. set DYLD_INSERT_LIBRARIES=\(env["DYLD_INSERT_LIBRARIES"] ?? "?") on the host app launch.")
    print("[driver] kill -USR1 \(getpid()) to pause; -USR2 to resume; -INT to stop.")

    installLifecycleSignalHandlers(session: session)
    logger.setOnBroadcastStarted { [args] in
        Task { @MainActor in
            scheduleMicInterruption(from: args, session: session)
        }
    }

    // Park forever until SIGINT.
    try await Task.sleep(for: .seconds(3600))
}

private func describe(_ mic: MicSource) -> String {
    switch mic {
    case .systemMicrophone: return "systemMicrophone"
    case .mediaFile(let url): return "mediaFile=\(url.path)"
    case .custom: return "custom"
    case .disabled: return "disabled"
    }
}

@MainActor
private func scheduleMicInterruption(from args: [String], session: GeistBroadcastSession) {
    if let onAt = doubleArg(args, "--interrupt-at") {
        Task {
            try? await Task.sleep(for: .seconds(onAt))
            do {
                try await session.simulateMicAudioInterruption(true)
                print("[driver] mic interruption ON at +\(onAt)s")
            } catch { print("[driver] mic interruption ON failed: \(error)") }
        }
    }
    if let offAt = doubleArg(args, "--interrupt-clear-at") {
        Task {
            try? await Task.sleep(for: .seconds(offAt))
            do {
                try await session.simulateMicAudioInterruption(false)
                print("[driver] mic interruption OFF at +\(offAt)s")
            } catch { print("[driver] mic interruption OFF failed: \(error)") }
        }
    }
}

// DispatchSource keeps the async handlers off the signal-safety treadmill;
// signal handler itself stays minimal (SIG_IGN).
@MainActor
func installLifecycleSignalHandlers(session: GeistBroadcastSession) {
    let pauseSource = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
    pauseSource.setEventHandler {
        Task {
            do { try await session.pause(); print("[driver] paused") }
            catch { print("[driver] pause failed: \(error)") }
        }
    }
    pauseSource.resume()
    signal(SIGUSR1, SIG_IGN)

    let resumeSource = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
    resumeSource.setEventHandler {
        Task {
            do { try await session.resume(); print("[driver] resumed") }
            catch { print("[driver] resume failed: \(error)") }
        }
    }
    resumeSource.resume()
    signal(SIGUSR2, SIG_IGN)

    keepSignalSources(pauseSource, resumeSource)
}

private nonisolated(unsafe) var retainedSignalSources: [DispatchSourceSignal] = []

func keepSignalSources(_ sources: DispatchSourceSignal...) {
    retainedSignalSources.append(contentsOf: sources)
}

try await run()
