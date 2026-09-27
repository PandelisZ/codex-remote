import Foundation

/// The Codex app-server on a remote machine binds to 127.0.0.1 only — it refuses to
/// listen on a public interface, and says so at startup. So the only way to reach it is
/// an SSH local forward, which is also what keeps the bearer token off the open internet.
///
/// This type owns one long-lived `ssh -N -L` process per machine and restarts it with
/// backoff whenever it dies.
public final class TunnelManager: @unchecked Sendable {
    public struct Status: Sendable {
        public let machineID: UUID
        public let isRunning: Bool
        public let restarts: Int
        public let lastExit: String?
    }

    private final class Tunnel {
        let machineID: UUID
        var process: Process?
        var restarts = 0
        var lastExit: String?
        var supervisor: Task<Void, Never>?
        var wantsRunning = true
        init(machineID: UUID) { self.machineID = machineID }
    }

    public static let shared = TunnelManager()

    private let lock = Lock()
    private var tunnels: [UUID: Tunnel] = [:]
    private var onStatusChange: ((UUID) -> Void)?

    public init() {}

    public func setStatusObserver(_ handler: @escaping (UUID) -> Void) {
        lock.lock(); onStatusChange = handler; lock.unlock()
    }

    public func status(for machineID: UUID) -> Status {
        lock.lock(); defer { lock.unlock() }
        guard let tunnel = tunnels[machineID] else {
            return Status(machineID: machineID, isRunning: false, restarts: 0, lastExit: nil)
        }
        return Status(machineID: machineID, isRunning: tunnel.process?.isRunning == true,
                      restarts: tunnel.restarts, lastExit: tunnel.lastExit)
    }

    public func isRunning(_ machineID: UUID) -> Bool { status(for: machineID).isRunning }

    /// Starts (or restarts) the forward for a machine. Idempotent.
    public func start(_ machine: Machine) {
        lock.lock()
        if let existing = tunnels[machine.id] {
            existing.wantsRunning = true
            if existing.process?.isRunning == true {
                lock.unlock()
                return
            }
        }
        let tunnel = tunnels[machine.id] ?? Tunnel(machineID: machine.id)
        tunnel.wantsRunning = true
        tunnels[machine.id] = tunnel
        lock.unlock()

        tunnel.supervisor?.cancel()
        tunnel.supervisor = Task { [weak self] in
            // An `ssh -N -L` outlives a parent that was killed rather than quit, and it
            // keeps holding the forwarded port — which is what turns the next launch into
            // an endless "Address already in use" reconnect loop. Clear any leftover from
            // a previous run before binding.
            await Self.reapOrphanedForwards(localPort: machine.localPort)
            await self?.supervise(machine: machine, tunnel: tunnel)
        }
    }

    public func stop(_ machineID: UUID) {
        lock.lock()
        let tunnel = tunnels[machineID]
        tunnel?.wantsRunning = false
        lock.unlock()
        tunnel?.supervisor?.cancel()
        if let process = tunnel?.process, process.isRunning { process.terminate() }
        lock.lock(); tunnels[machineID] = nil; lock.unlock()
        onStatusChange?(machineID)
    }

    public func stopAll() {
        let ids = { () -> [UUID] in
            lock.lock(); defer { lock.unlock() }
            return Array(tunnels.keys)
        }()
        for id in ids { stop(id) }
    }

    /// Kills any `ssh -N -L 127.0.0.1:<port>:…` left behind by an earlier Codex Remote process.
    /// Matches on Codex Remote's exact forward spec so it can only ever hit its own tunnels.
    static func reapOrphanedForwards(localPort: Int) async {
        guard let pgrep = Shell.which("pgrep") else { return }
        let pattern = "ssh -N -L 127.0.0.1:\(localPort):127.0.0.1:"
        guard let found = try? await Shell.run(pgrep, ["-f", pattern], timeout: 15),
              found.succeeded else { return }

        let mine = ProcessInfo.processInfo.processIdentifier
        let stale = found.stdout
            .split(separator: "\n")
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0 != mine }
        guard !stale.isEmpty else { return }

        for pid in stale { kill(pid, SIGTERM) }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        for pid in stale where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        Log.shared.info("tunnel", "Reaped \(stale.count) leftover forward(s) on 127.0.0.1:\(localPort).")
    }

    private func supervise(machine: Machine, tunnel: Tunnel) async {
        var backoff: UInt64 = 1_000_000_000
        while !Task.isCancelled {
            let keepGoing = { () -> Bool in
                lock.lock(); defer { lock.unlock() }
                return tunnel.wantsRunning
            }()
            guard keepGoing else { return }
            guard let address = machine.instance?.sshAddress else {
                Log.shared.warn("tunnel", "\(machine.name) has no address yet; not starting a tunnel.")
                return
            }
            guard let ssh = Shell.which("ssh") else {
                Log.shared.error("tunnel", "ssh is not on PATH.")
                return
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: ssh)
            process.arguments = [
                "-N",
                "-L", "127.0.0.1:\(machine.localPort):127.0.0.1:\(machine.remotePort)",
                "-o", "IdentitiesOnly=yes",
                "-o", "IdentityAgent=none",
                "-o", "StrictHostKeyChecking=accept-new",
                "-o", "UserKnownHostsFile=\(SSHClient.knownHostsPath)",
                "-o", "ExitOnForwardFailure=yes",
                // Never share or leave behind a multiplexed master: a persisted master
                // would keep holding the forwarded port after Codex Remote quits, and the next
                // launch would then fail to bind it.
                "-o", "ControlMaster=no",
                "-o", "ControlPath=none",
                "-o", "ServerAliveInterval=15",
                "-o", "ServerAliveCountMax=3",
                "-o", "ConnectTimeout=10",
                "-o", "BatchMode=yes",
                "-i", machine.privateKeyPath,
                "-p", String(machine.sshPort),
                "\(machine.sshUser)@\(address)",
            ]
            let errPipe = Pipe()
            process.standardError = errPipe
            process.standardOutput = Pipe()

            do {
                try process.run()
            } catch {
                Log.shared.error("tunnel", "\(machine.name): could not start ssh — \(error.localizedDescription)")
                return
            }

            lock.lock(); tunnel.process = process; lock.unlock()
            onStatusChange?(machine.id)
            Log.shared.info("tunnel", "\(machine.name): forwarding 127.0.0.1:\(machine.localPort) → \(address):\(machine.remotePort).")

            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                process.terminationHandler = { _ in continuation.resume() }
            }

            let stderr = String(decoding: (try? errPipe.fileHandleForReading.readToEnd()) ?? Data(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            lock.lock()
            tunnel.process = nil
            tunnel.lastExit = stderr.isEmpty ? "exit \(process.terminationStatus)" : stderr
            let stillWanted = tunnel.wantsRunning
            lock.unlock()
            onStatusChange?(machine.id)

            guard stillWanted, !Task.isCancelled else { return }
            lock.lock(); tunnel.restarts += 1; let count = tunnel.restarts; lock.unlock()
            Log.shared.warn("tunnel", "\(machine.name): tunnel exited (\(tunnel.lastExit ?? "unknown")); reconnecting in \(backoff / 1_000_000_000)s (attempt \(count)).")
            try? await Task.sleep(nanoseconds: backoff)
            backoff = min(backoff * 2, 30_000_000_000)
        }
    }
}
