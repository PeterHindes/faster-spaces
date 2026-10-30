import Foundation

final class DockGeometryCache {
    private let lock = NSLock()
    private var current = DockSnapshot.empty

    func update(_ snapshot: DockSnapshot) {
        lock.lock()
        current = snapshot
        lock.unlock()
    }

    func snapshot() -> DockSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func clear() {
        update(.empty)
    }
}
