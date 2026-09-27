import Foundation

/// A tiny mutex used everywhere Codex Remote guards shared state.
///
/// `NSLock.lock()` is marked unavailable from async contexts, which is good advice for
/// long holds but wrong for the pattern used here: every critical section is a few
/// field reads or a `removeAll`, with no `await` inside. This wrapper keeps that pattern
/// legal and makes the "never await while holding it" rule explicit.
public final class Lock: @unchecked Sendable {
    private let handle: UnsafeMutablePointer<os_unfair_lock>

    public init() {
        handle = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        handle.initialize(to: os_unfair_lock())
    }

    deinit {
        handle.deinitialize(count: 1)
        handle.deallocate()
    }

    public func lock() { os_unfair_lock_lock(handle) }
    public func unlock() { os_unfair_lock_unlock(handle) }

    /// Preferred form: the body must not suspend.
    public func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
