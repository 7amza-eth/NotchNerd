import Foundation

/// Thread-safe in-memory cache with a per-entry time-to-live.
///
/// Used to short-circuit repeated synchronous IO calls from hot SwiftUI
/// computed properties (e.g. resolving the git branch for a session row
/// during every layout pass). The TTL guarantees branch / state changes
/// in the underlying source still surface within a bounded window.
///
/// On cache miss the compute closure runs without holding the lock so
/// concurrent callers for distinct keys do not serialize, and a slow
/// compute does not starve other readers. Concurrent misses for the
/// same key may compute twice; that is intentionally tolerated rather
/// than coordinated, since `compute` is assumed idempotent and the
/// duplicate cost is bounded.
final class TimedCache<Key: Hashable, Value>: @unchecked Sendable {
    private struct Entry {
        let value: Value
        let expiresAt: Date
    }

    private let ttl: TimeInterval
    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]

    init(ttl: TimeInterval) {
        self.ttl = ttl
    }

    func value(for key: Key, compute: (Key) -> Value) -> Value {
        let now = Date()

        lock.lock()
        if let entry = entries[key], entry.expiresAt > now {
            let cached = entry.value
            lock.unlock()
            return cached
        }
        lock.unlock()

        let computed = compute(key)

        lock.lock()
        entries[key] = Entry(value: computed, expiresAt: now.addingTimeInterval(ttl))
        lock.unlock()

        return computed
    }

    func removeAll() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }
}
