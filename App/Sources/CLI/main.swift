import AVFoundation
import Foundation

let cliVersion = "0.1.0"

let usage = """
Usage:
  geistlens list                           Show booted simulators, installed apps, and current sources.
  geistlens sources                        List available macOS cameras.
  geistlens set <sim> <bundle> <side> <src>
                                           Set the camera source for an app on a simulator.
  geistlens unset <sim> <bundle> <side>    Clear the source (use built-in colorbars).
  geistlens status                         Daemon status, control socket, dylib install path.
  geistlens version                        Print CLI version.
  geistlens help                           Print this message.

Arguments:
  <sim>     Simulator UDID, or 'booted' to target the single booted simulator.
  <bundle>  iOS app bundle identifier, e.g. com.apple.AVCam.
  <side>    'back' or 'front'.
  <src>     One of:
              camera                       Default macOS camera (system preferred).
              camera:<unique-id>           Specific camera by unique ID (see 'sources').
              video:<path>                   Loop a video file (mp4/mov/m4v).
              image:<path>                 Hold a still image.
"""

func main() -> Int32 {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let cmd = args.first else {
        printUsage(toStderr: true)
        return 1
    }

    do {
        switch cmd {
        case "help", "-h", "--help":
            printUsage(toStderr: false)
            return 0
        case "version", "-v", "--version":
            print(cliVersion)
            return 0
        case "list":
            return try send(.list)
        case "sources":
            return try send(.sources)
        case "status":
            return try send(.status)
        case "set":
            return try send(parseSet(Array(args.dropFirst())))
        case "unset":
            return try send(parseUnset(Array(args.dropFirst())))
        default:
            throw CLIError.unknownCommand(cmd)
        }
    } catch let error as CLIError {
        FileHandle.standardError.write(Data("error: \(error.description)\n".utf8))
        return 1
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        return 1
    }
}

func send(_ request: ControlRequest) throws -> Int32 {
    let response = try roundTripWithAutoLaunch(request)
    return ResponseFormatter.print(response)
}

func roundTripWithAutoLaunch(_ request: ControlRequest) throws -> ControlResponse {
    do {
        return try ControlClient.roundTrip(request)
    } catch CLIError.daemonUnreachable {
        FileHandle.standardError.write(Data("GeistLens not running, launching…\n".utf8))
        guard AppLauncher.launchOwnApp() else { throw CLIError.daemonUnreachable }
        guard AppLauncher.waitForDaemon(timeout: 4.0) else { throw CLIError.daemonUnreachable }
        return try ControlClient.roundTrip(request)
    }
}

func parseSet(_ args: [String]) throws -> ControlRequest {
    guard args.count == 4 else {
        throw CLIError.usage("set takes 4 arguments: <sim> <bundle> <side> <src>")
    }
    let side = try parseSide(args[2])
    let source = try parseSource(args[3])
    return .set(.init(simulator: args[0], bundleID: args[1], side: side, source: source))
}

func parseUnset(_ args: [String]) throws -> ControlRequest {
    guard args.count == 3 else {
        throw CLIError.usage("unset takes 3 arguments: <sim> <bundle> <side>")
    }
    let side = try parseSide(args[2])
    return .unset(.init(simulator: args[0], bundleID: args[1], side: side))
}

func parseSide(_ s: String) throws -> CameraSide {
    switch s.lowercased() {
    case "back": return .back
    case "front": return .front
    default: throw CLIError.unknownSide(s)
    }
}

func parseSource(_ s: String) throws -> PersistableSource {
    if s == "camera" {
        guard let uid = defaultCameraUID() else {
            throw CLIError.usage("no macOS camera detected; pass an explicit camera:<uid> (run 'geistlens sources')")
        }
        return .macOSCamera(deviceUID: uid)
    }
    let parts = s.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2 else { throw CLIError.unknownSource(s) }
    let kind = String(parts[0])
    let value = String(parts[1])
    switch kind {
    case "camera":
        guard !value.isEmpty else { throw CLIError.unknownSource(s) }
        return .macOSCamera(deviceUID: value)
    case "video":
        return .video(path: absolute(value))
    case "image":
        return .image(path: absolute(value))
    default:
        throw CLIError.unknownSource(s)
    }
}

func defaultCameraUID() -> String? {
    if #available(macOS 13.0, *), let pref = AVCaptureDevice.systemPreferredCamera {
        return pref.uniqueID
    }
    var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
    if #available(macOS 14.0, *) {
        types.append(contentsOf: [.external, .continuityCamera, .deskViewCamera])
    }
    let session = AVCaptureDevice.DiscoverySession(
        deviceTypes: types, mediaType: .video, position: .unspecified)
    return session.devices.first?.uniqueID
}

func absolute(_ path: String) -> String {
    if path.hasPrefix("/") { return path }
    let cwd = FileManager.default.currentDirectoryPath
    return (cwd as NSString).appendingPathComponent(path)
}

func printUsage(toStderr: Bool) {
    let data = Data((usage + "\n").utf8)
    if toStderr {
        FileHandle.standardError.write(data)
    } else {
        FileHandle.standardOutput.write(data)
    }
}

exit(main())
