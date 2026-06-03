import Foundation
import Testing
@testable import GeistKit

@Suite("EventDrivenSimulatorWatcher")
struct EventDrivenSimulatorWatcherTests {
    @Test func EventDrivenSimulatorWatcher_startWithBootedDevice_emitsItAsAdded() {
        let source = FakeSimulatorEventSource()
        source.setBooted(["A1"])
        let spy = OnChangeSpy()
        let watcher = EventDrivenSimulatorWatcher(source: source, deliver: { $0() }, onChange: spy.record)

        watcher.start()

        #expect(spy.last?.added == Set(["A1"]))
        #expect(spy.last?.removed.isEmpty == true)
    }

    @Test func EventDrivenSimulatorWatcher_pokeAfterNewDeviceBoots_emitsAddedDelta() {
        let source = FakeSimulatorEventSource()
        source.setBooted(["A1"])
        let spy = OnChangeSpy()
        let watcher = EventDrivenSimulatorWatcher(source: source, deliver: { $0() }, onChange: spy.record)
        watcher.start()

        source.setBooted(["A1", "B2"])
        source.emitPoke()

        #expect(spy.last?.added == Set(["B2"]))
        #expect(spy.last?.removed.isEmpty == true)
    }

    @Test func EventDrivenSimulatorWatcher_pokeAfterDeviceShutsDown_emitsRemovedDelta() {
        let source = FakeSimulatorEventSource()
        source.setBooted(["A1", "B2"])
        let spy = OnChangeSpy()
        let watcher = EventDrivenSimulatorWatcher(source: source, deliver: { $0() }, onChange: spy.record)
        watcher.start()

        source.setBooted(["A1"])
        source.emitPoke()

        #expect(spy.last?.removed == Set(["B2"]))
        #expect(spy.last?.added.isEmpty == true)
    }

    @Test func EventDrivenSimulatorWatcher_pokeWithNoChange_doesNotEmitAgain() {
        let source = FakeSimulatorEventSource()
        source.setBooted(["A1"])
        let spy = OnChangeSpy()
        let watcher = EventDrivenSimulatorWatcher(source: source, deliver: { $0() }, onChange: spy.record)
        watcher.start()

        source.emitPoke()

        #expect(spy.count == 1)
    }

    @Test func EventDrivenSimulatorWatcher_rapidPokes_diffAgainstLatestSnapshot() {
        let source = FakeSimulatorEventSource()
        source.setBooted([])
        let spy = OnChangeSpy()
        let watcher = EventDrivenSimulatorWatcher(source: source, deliver: { $0() }, onChange: spy.record)
        watcher.start()

        source.setBooted(["A1"]); source.emitPoke()
        source.setBooted(["A1", "B2"]); source.emitPoke()

        #expect(spy.calls.map(\.added) == [Set(["A1"]), Set(["B2"])])
    }

    @Test func EventDrivenSimulatorWatcher_stop_unregistersSourceAndStopsEmitting() {
        let source = FakeSimulatorEventSource()
        source.setBooted(["A1"])
        let spy = OnChangeSpy()
        let watcher = EventDrivenSimulatorWatcher(source: source, deliver: { $0() }, onChange: spy.record)
        watcher.start()

        watcher.stop()
        source.setBooted(["A1", "B2"])
        source.emitPoke()

        #expect(source.stopCount == 1)
        #expect(spy.count == 1)
    }

    @Test func EventDrivenSimulatorWatcher_sourceUnavailable_doesNotObserveOrEmit() {
        let source = FakeSimulatorEventSource()
        source.startResult = false
        source.setBooted(["A1"])
        let spy = OnChangeSpy()
        let watcher = EventDrivenSimulatorWatcher(source: source, deliver: { $0() }, onChange: spy.record)

        let started = watcher.start()
        source.emitPoke()

        #expect(started == false)
        #expect(spy.count == 0)
    }

    @Test func EventDrivenSimulatorWatcher_emitsThroughInjectedDeliver() {
        let source = FakeSimulatorEventSource()
        source.setBooted(["A1"])
        let deliverSpy = DeliverSpy()
        let spy = OnChangeSpy()
        let watcher = EventDrivenSimulatorWatcher(source: source, deliver: deliverSpy.record, onChange: spy.record)

        watcher.start()

        #expect(deliverSpy.count == 1)
        #expect(spy.count == 1)
    }

    @Test func EventDrivenSimulatorWatcher_serviceRestartPoke_reReadsFreshSnapshot() {
        let source = FakeSimulatorEventSource()
        source.setBooted(["A1"])
        let spy = OnChangeSpy()
        let watcher = EventDrivenSimulatorWatcher(source: source, deliver: { $0() }, onChange: spy.record)
        watcher.start()

        source.setBooted(["C3"])
        source.emitPoke()

        #expect(spy.last?.added == Set(["C3"]))
        #expect(spy.last?.removed == Set(["A1"]))
    }
}

private final class OnChangeSpy: @unchecked Sendable {
    typealias Call = (added: Set<String>, removed: Set<String>)
    private let lock = NSLock()
    private var _calls: [Call] = []

    func record(_ added: Set<String>, _ removed: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        _calls.append((added, removed))
    }

    var calls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }
    var last: Call? { calls.last }
    var count: Int { calls.count }
}

private final class DeliverSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0

    func record(_ work: @escaping @Sendable () -> Void) {
        lock.lock(); _count += 1; lock.unlock()
        work()
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return _count
    }
}

private final class FakeSimulatorEventSource: SimulatorEventSource, @unchecked Sendable {
    private let lock = NSLock()
    private var bootedUDIDs: Set<String> = []
    private var poke: (() -> Void)?
    var startResult = true
    private(set) var stopCount = 0

    func startObserving(onPoke: @escaping () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if startResult { poke = onPoke }
        return startResult
    }

    func currentBootedUDIDs() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return bootedUDIDs
    }

    func stopObserving() {
        lock.lock(); defer { lock.unlock() }
        stopCount += 1
        poke = nil
    }

    func setBooted(_ udids: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        bootedUDIDs = udids
    }

    func emitPoke() {
        lock.lock(); let p = poke; lock.unlock()
        p?()
    }
}
