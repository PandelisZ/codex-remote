import Foundation

/// Exactly one process may own the running side of Codex Remote — the SSH tunnels, the health
/// polling, and the Codex app's remote list. Without this, the menu bar app and a
/// `codex-remote` invocation both bind the same loopback ports and both rewrite the same
/// files, which shows up as an endless "Address already in use" reconnect loop.
///
/// The lock is advisory and process-scoped: it is released when the holder exits, even if
/// it crashes, because it is a `flock` on an open descriptor rather than a file that has
/// to be cleaned up.
public final class RuntimeLock: @unchecked Sendable {
    public struct Holder: Sendable {
        public let pid: pid_t
        public let name: String
        public let since: Date
    }

    public static let shared = RuntimeLock()

    private let lock = Lock()
    private var descriptor: Int32 = -1
    private var held = false

    private init() {}

    public var url: URL { Paths.codexRemoteHome.appendingPathComponent("owner.lock") }

    public var isHeld: Bool {
        lock.lock(); defer { lock.unlock() }
        return held
    }

    /// Takes the lock if it is free. Returns true when this process now owns the runtime.
    @discardableResult
    public func acquire(name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if held { return true }
        try? Paths.ensureDirectories()

        let fd = open(url.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else {
            Log.shared.warn("lock", "Could not open \(url.path); running without an ownership lock.")
            held = true            // Fail open: better to work than to refuse everything.
            return true
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }

        ftruncate(fd, 0)
        let payload = "\(getpid())\n\(name)\n\(ISO8601DateFormatter().string(from: Date()))\n"
        _ = payload.withCString { write(fd, $0, strlen($0)) }
        descriptor = fd
        held = true
        Log.shared.info("lock", "\(name) owns the Codex Remote runtime (pid \(getpid())).")
        return true
    }

    public func release() {
        lock.lock(); defer { lock.unlock() }
        guard held, descriptor >= 0 else { held = false; return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
        held = false
    }

    /// Who is holding it, for an error message that tells the user what to do.
    public func currentHolder() -> Holder? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 2, let pid = pid_t(lines[0]) else { return nil }
        // A stale file from a process that has gone away is not a holder.
        guard kill(pid, 0) == 0 || errno == EPERM else { return nil }
        let since = lines.count >= 3
            ? (ISO8601DateFormatter().date(from: lines[2]) ?? Date())
            : Date()
        return Holder(pid: pid, name: lines[1], since: since)
    }
}
