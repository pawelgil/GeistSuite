import Foundation

public enum GeistCamError: Error {
    case slotNotSupported(CameraSlot)
    case notStarted
    case alreadyStarted
    case stoppedDuringStart
}

public enum SourceSwitchError: Error {
    case recordingInProgress
}

public enum CameraInterruptionReason: String, Codable, CaseIterable, Sendable {
    case audioDeviceInUseByAnotherClient
    case sensitiveContentMitigationActivated
    case videoDeviceInUseByAnotherClient
    case videoDeviceNotAvailableDueToSystemPressure
    case videoDeviceNotAvailableInBackground
    case videoDeviceNotAvailableWithMultipleForegroundApps

    var rawAVFoundationValue: Int {
        switch self {
        case .videoDeviceNotAvailableInBackground: 1
        case .audioDeviceInUseByAnotherClient: 2
        case .videoDeviceInUseByAnotherClient: 3
        case .videoDeviceNotAvailableWithMultipleForegroundApps: 4
        case .videoDeviceNotAvailableDueToSystemPressure: 5
        case .sensitiveContentMitigationActivated: 6
        }
    }

    static func from(rawAVFoundationValue value: Int) -> CameraInterruptionReason? {
        allCases.first { $0.rawAVFoundationValue == value }
    }
}

public struct CameraSessionSnapshot: Codable, Sendable, Equatable {
    public let holdsCamera: Bool
    public let id: String
    public let inputs: [String]
    public let interruptionReason: Int?
    public let isInterrupted: Bool
    public let isRunning: Bool
    public let outputs: [String]
    public let startOrder: Int?
    public let startedAt: Date?

    public init(
        holdsCamera: Bool,
        id: String,
        inputs: [String],
        interruptionReason: Int?,
        isInterrupted: Bool,
        isRunning: Bool,
        outputs: [String],
        startOrder: Int?,
        startedAt: Date?
    ) {
        self.holdsCamera = holdsCamera
        self.id = id
        self.inputs = inputs
        self.interruptionReason = interruptionReason
        self.isInterrupted = isInterrupted
        self.isRunning = isRunning
        self.outputs = outputs
        self.startOrder = startOrder
        self.startedAt = startedAt
    }
}

public struct CameraStatusSnapshot: Codable, Sendable, Equatable {
    public let holder: String?
    public let runningCount: Int
    public let sessions: [CameraSessionSnapshot]

    public init(holder: String?, runningCount: Int, sessions: [CameraSessionSnapshot]) {
        self.holder = holder
        self.runningCount = runningCount
        self.sessions = sessions
    }
}

public struct CameraInterruptionChange: Codable, Sendable, Equatable {
    public struct Skipped: Codable, Sendable, Equatable {
        public let reason: String
        public let session: String

        public init(reason: String, session: String) {
            self.reason = reason
            self.session = session
        }
    }

    public let affected: [String]
    public let skipped: [Skipped]

    public init(affected: [String], skipped: [Skipped]) {
        self.affected = affected
        self.skipped = skipped
    }
}

public struct CameraControlError: LocalizedError, Sendable {
    public let message: String

    public var errorDescription: String? { message }
}
