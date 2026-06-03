import Foundation

enum ControlSocket {
    static var path: String {
        let dir = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/GeistLens")
        return (dir as NSString).appendingPathComponent("control.sock")
    }
}

enum ControlRequest: Codable, Sendable {
    case list
    case sources
    case set(SetArgs)
    case unset(UnsetArgs)
    case status

    struct SetArgs: Codable, Sendable {
        let simulator: String
        let bundleID: String
        let side: CameraSide
        let source: PersistableSource
    }

    struct UnsetArgs: Codable, Sendable {
        let simulator: String
        let bundleID: String
        let side: CameraSide
    }
}

enum ControlResponse: Codable, Sendable {
    case ok
    case list(ListReply)
    case sources(SourcesReply)
    case status(StatusReply)
    case error(ErrorReply)

    struct ListReply: Codable, Sendable {
        let simulators: [SimulatorReply]
        let cameraNames: [String: String]
    }

    struct SimulatorReply: Codable, Sendable {
        let udid: String
        let name: String
        let runtime: String
        let displayLabel: String
        let injected: Bool
        let apps: [AppReply]
    }

    struct AppReply: Codable, Sendable {
        let bundleID: String
        let displayName: String
        let back: PersistableSource?
        let front: PersistableSource?
        let active: Bool
    }

    struct SourcesReply: Codable, Sendable {
        let cameras: [CameraInfo]
    }

    struct CameraInfo: Codable, Sendable {
        let uniqueID: String
        let localizedName: String
    }

    struct StatusReply: Codable, Sendable {
        let version: String
        let socketPath: String
        let dylibInstalledAt: String?
        let injectedSimulators: [String]
        let activeSessionCount: Int
    }

    struct ErrorReply: Codable, Sendable {
        let message: String
    }
}
