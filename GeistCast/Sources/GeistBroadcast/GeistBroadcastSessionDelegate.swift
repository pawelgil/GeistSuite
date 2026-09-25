public protocol GeistBroadcastSessionDelegate: AnyObject, Sendable {
    func session(_ session: GeistBroadcastSession, broadcastStarted: Broadcast)
    func session(_ session: GeistBroadcastSession, broadcastEnded: Broadcast)
    func session(_ session: GeistBroadcastSession,
                 broadcastFailedToStart broadcast: Broadcast,
                 error: Error)
    func session(_ session: GeistBroadcastSession,
                 broadcast: Broadcast,
                 terminatedWithError error: Error)
    func session(_ session: GeistBroadcastSession, stateChanged: GeistBroadcastSession.State)
    func session(_ session: GeistBroadcastSession, extensionConnectedFor extensionBundleID: String)
}

public extension GeistBroadcastSessionDelegate {
    func session(_: GeistBroadcastSession, broadcastStarted _: Broadcast) {}
    func session(_: GeistBroadcastSession, broadcastEnded _: Broadcast) {}
    func session(_: GeistBroadcastSession,
                 broadcastFailedToStart _: Broadcast,
                 error _: Error) {}
    func session(_: GeistBroadcastSession,
                 broadcast _: Broadcast,
                 terminatedWithError _: Error) {}
    func session(_: GeistBroadcastSession, stateChanged _: GeistBroadcastSession.State) {}
    func session(_: GeistBroadcastSession, extensionConnectedFor _: String) {}
}
