import Testing
@testable import GeistLens

@Suite("SetDiffer")
struct SetDifferTests {
    @Test func diff_firstObservation_returnsAllAddedNoneRemoved() {
        var differ = SetDiffer<String>()

        let (added, removed) = differ.diff(current: ["A", "B"])

        #expect(added == ["A", "B"])
        #expect(removed.isEmpty)
    }

    @Test func diff_unchangedSet_returnsEmptyAddedAndRemoved() {
        var differ = SetDiffer<String>()
        _ = differ.diff(current: ["A", "B"])

        let (added, removed) = differ.diff(current: ["A", "B"])

        #expect(added.isEmpty)
        #expect(removed.isEmpty)
    }

    @Test func diff_oneNewElement_returnsItInAdded() {
        var differ = SetDiffer<String>()
        _ = differ.diff(current: ["A"])

        let (added, removed) = differ.diff(current: ["A", "B"])

        #expect(added == ["B"])
        #expect(removed.isEmpty)
    }

    @Test func diff_oneElementGone_returnsItInRemoved() {
        var differ = SetDiffer<String>()
        _ = differ.diff(current: ["A", "B"])

        let (added, removed) = differ.diff(current: ["A"])

        #expect(added.isEmpty)
        #expect(removed == ["B"])
    }

    @Test func diff_replaceAllElements_returnsOldRemovedNewAdded() {
        var differ = SetDiffer<String>()
        _ = differ.diff(current: ["A", "B"])

        let (added, removed) = differ.diff(current: ["C", "D"])

        #expect(added == ["C", "D"])
        #expect(removed == ["A", "B"])
    }

    @Test func diff_emptyAfterPopulated_returnsAllInRemoved() {
        var differ = SetDiffer<String>()
        _ = differ.diff(current: ["A", "B"])

        let (added, removed) = differ.diff(current: [])

        #expect(added.isEmpty)
        #expect(removed == ["A", "B"])
    }
}
