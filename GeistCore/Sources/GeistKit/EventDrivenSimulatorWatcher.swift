import Foundation

public final class EventDrivenSimulatorWatcher: @unchecked Sendable {
    public typealias OnChange = @Sendable (Set<String>, Set<String>) -> Void
    public typealias Deliver = @Sendable (@escaping @Sendable () -> Void) -> Void

    private let source: any SimulatorEventSource
    private let deliver: Deliver
    private let onChange: OnChange
    private var differ = SetDiffer<String>()

    public init(source: any SimulatorEventSource,
                deliver: @escaping Deliver = { work in DispatchQueue.main.async { work() } },
                onChange: @escaping OnChange) {
        self.source = source
        self.deliver = deliver
        self.onChange = onChange
    }

    @discardableResult
    public func start() -> Bool {
        guard source.startObserving(onPoke: { [weak self] in self?.rediff() }) else { return false }
        rediff()
        return true
    }

    public func stop() {
        source.stopObserving()
    }

    private func rediff() {
        let current = source.currentBootedUDIDs()
        deliver { [weak self] in
            guard let self else { return }
            let (added, removed) = self.differ.diff(current: current)
            if added.isEmpty && removed.isEmpty { return }
            self.onChange(added, removed)
        }
    }
}
