import Foundation

public protocol SimulatorEventSource: AnyObject {
    func startObserving(onPoke: @escaping () -> Void) -> Bool
    func currentBootedUDIDs() -> Set<String>
    func stopObserving()
}
