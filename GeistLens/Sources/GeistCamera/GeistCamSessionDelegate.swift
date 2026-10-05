import Foundation

public protocol GeistCamSessionDelegate: AnyObject, Sendable {
    func sessionDidConnect(_ session: GeistCamSession)
    func sessionDidDisconnect(_ session: GeistCamSession)
    func session(_ session: GeistCamSession, didActivateSlotWithoutSource slot: CameraSlot)
    func session(_ session: GeistCamSession, isStreamingChanged isStreaming: Bool)
}

public protocol SessionDriving: AnyObject, Sendable {
    func attachMediaSource(
        _ source: any MediaSource,
        video: CameraSlot?,
        audio: CameraSlot?) async throws(SourceSwitchError)
    func start(connectTimeout: TimeInterval) async throws
    func stop() async
}

extension GeistCamSessionDelegate {
    public func sessionDidConnect(_ session: GeistCamSession) {}
    public func sessionDidDisconnect(_ session: GeistCamSession) {}
    public func session(_ session: GeistCamSession, didActivateSlotWithoutSource slot: CameraSlot) {}
    public func session(_ session: GeistCamSession, isStreamingChanged isStreaming: Bool) {}
}
