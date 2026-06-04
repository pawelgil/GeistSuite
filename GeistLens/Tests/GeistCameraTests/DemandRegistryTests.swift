import Testing
@testable import GeistCamera

@Suite("DemandRegistry")
struct DemandRegistryTests {
    @Test func demand_neverUpdated_returnsNone() {
        let registry = DemandRegistry()

        let result = registry.demand(slot: 0)

        #expect(result == .none)
    }

    @Test func demand_afterUpdate_returnsThatDemand() {
        let registry = DemandRegistry()
        let wantQR = SlotDemand(wantsQR: true, wantsFace: false)

        registry.update(slot: 0, demand: wantQR)

        #expect(registry.demand(slot: 0) == wantQR)
    }

    @Test func demand_updatedTwiceForSameSlot_returnsLatestValue() {
        let registry = DemandRegistry()
        let wantQR = SlotDemand(wantsQR: true, wantsFace: false)
        let wantFace = SlotDemand(wantsQR: false, wantsFace: true)

        registry.update(slot: 0, demand: wantQR)
        registry.update(slot: 0, demand: wantFace)

        #expect(registry.demand(slot: 0) == wantFace)
    }

    @Test func demand_perSlotIsolated_doesNotLeakBetweenSlots() {
        let registry = DemandRegistry()
        let wantQR = SlotDemand(wantsQR: true, wantsFace: false)

        registry.update(slot: 0, demand: wantQR)

        #expect(registry.demand(slot: 1) == .none)
    }

    @Test func slotDemand_neitherFlag_isEmpty() {
        #expect(SlotDemand.none.isEmpty)
    }

    @Test func slotDemand_anyFlagSet_isNotEmpty() {
        let qrOnly = SlotDemand(wantsQR: true, wantsFace: false)
        let faceOnly = SlotDemand(wantsQR: false, wantsFace: true)

        #expect(qrOnly.isEmpty == false)
        #expect(faceOnly.isEmpty == false)
    }
}
