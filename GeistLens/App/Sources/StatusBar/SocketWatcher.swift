import Darwin
import Foundation
import GeistKit

protocol SocketScanning: Sendable {
    func scan() -> Set<SocketWatcher.SocketEntry>
}

struct DefaultSocketScanner: SocketScanning {
    func scan() -> Set<SocketWatcher.SocketEntry> { SocketWatcher.scanSockets() }
}

final class SocketWatcher {
    typealias OnChange = (_ added: [SocketEntry], _ removed: [SocketEntry]) -> Void

    struct SocketEntry: Hashable {
        let simulatorUDID: String
        let bundleID: String
        // Same path + new inode = shim relaunch; equality includes inode so
        // the watcher fires removed+added on the swap.
        let inode: UInt64
        var path: String { "/tmp/geistcam/\(simulatorUDID)/\(bundleID).sock" }
    }

    static let socketRoot = "/tmp/geistcam"

    private let pollInterval: TimeInterval
    private let onChange: OnChange
    private let scanner: any SocketScanning
    private let queue = DispatchQueue(label: "geistlens.socket-watcher")
    private var timer: DispatchSourceTimer?
    private var differ = SetDiffer<SocketEntry>()
    private var tickCount: UInt64 = 0

    init(pollInterval: TimeInterval = 1.0,
         scanner: any SocketScanning = DefaultSocketScanner(),
         onChange: @escaping OnChange) {
        self.pollInterval = pollInterval
        self.scanner = scanner
        self.onChange = onChange
    }

    func start() {
        let interval = pollInterval
        log.notice("SocketWatcher: starting (poll=\(interval)s)")
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: pollInterval)
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    func stop() {
        log.notice("SocketWatcher: stopping")
        timer?.cancel()
        timer = nil
    }

    func pollNow() {
        log.notice("SocketWatcher: pollNow()")
        queue.async { [weak self] in self?.tick() }
    }

    private func tick() {
        tickCount &+= 1
        let current = scanner.scan()
        let (addedSet, removedSet) = differ.diff(current: current)
        let added = Array(addedSet)
        let removed = Array(removedSet)
        if tickCount % 60 == 0 {
            let count = tickCount
            let total = current.count
            log.info("SocketWatcher.heartbeat: tick=\(count) sockets=\(total)")
        }
        if added.isEmpty && removed.isEmpty { return }
        let addedNames = added.map(\.bundleID).sorted()
        let removedNames = removed.map(\.bundleID).sorted()
        let total = current.count
        log.notice("SocketWatcher.tick: added=\(addedNames) removed=\(removedNames) totalNow=\(total)")
        DispatchQueue.main.async { [onChange] in onChange(added, removed) }
    }

    static func scanSockets() -> Set<SocketEntry> {
        let fm = FileManager.default
        var result: Set<SocketEntry> = []
        guard let udids = try? fm.contentsOfDirectory(atPath: socketRoot) else {
            return []
        }
        for udid in udids {
            let dir = "\(socketRoot)/\(udid)"
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for f in files where f.hasSuffix(".sock") {
                let bundleID = String(f.dropLast(".sock".count))
                let path = "\(dir)/\(f)"
                guard let inode = inodeOf(path: path) else { continue }
                result.insert(SocketEntry(simulatorUDID: udid, bundleID: bundleID, inode: inode))
            }
        }
        return result
    }

    private static func inodeOf(path: String) -> UInt64? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return UInt64(st.st_ino)
    }
}
