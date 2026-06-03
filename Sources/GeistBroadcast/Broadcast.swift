import Foundation

public struct Broadcast: Sendable, Equatable, Hashable {
    public let simulatorUDID: String
    public let hostAppBundleID: String
    public let extensionBundleID: String
    public let startedAt: Date

    public init(
        simulatorUDID: String,
        hostAppBundleID: String,
        extensionBundleID: String,
        startedAt: Date
    ) {
        self.simulatorUDID = simulatorUDID
        self.hostAppBundleID = hostAppBundleID
        self.extensionBundleID = extensionBundleID
        self.startedAt = startedAt
    }
}

