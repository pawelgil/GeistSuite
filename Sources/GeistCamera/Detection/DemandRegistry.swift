import Foundation
import Synchronization

struct SlotDemand: Equatable, Sendable {
    var wantsQR: Bool
    var wantsFace: Bool

    static let none = SlotDemand(wantsQR: false, wantsFace: false)
    var isEmpty: Bool { !wantsQR && !wantsFace }
}

final class DemandRegistry: Sendable {
    private let storage = Mutex<[UInt32: SlotDemand]>([:])

    func update(slot: UInt32, demand: SlotDemand) {
        storage.withLock { $0[slot] = demand }
    }

    func demand(slot: UInt32) -> SlotDemand {
        storage.withLock { $0[slot] ?? .none }
    }
}
