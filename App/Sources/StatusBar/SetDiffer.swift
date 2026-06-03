import Foundation

struct SetDiffer<Element: Hashable> {
    private var lastSeen: Set<Element> = []

    mutating func diff(current: Set<Element>) -> (added: Set<Element>, removed: Set<Element>) {
        let added = current.subtracting(lastSeen)
        let removed = lastSeen.subtracting(current)
        lastSeen = current
        return (added, removed)
    }
}
