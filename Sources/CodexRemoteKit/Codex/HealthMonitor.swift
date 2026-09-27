import Foundation

/// Polls each machine's forwarded `/healthz` so the menu bar can say "Online" with
/// something behind it. A machine is only ever reported online when this Mac has actually
/// completed an HTTP request to the remote Codex app-server through the SSH tunnel.
public actor HealthMonitor {
    public struct Probe: Sendable {
        public let machineID: UUID
        public let health: ConnectionHealth
        public let latency: TimeInterval?
        public let detail: String?
        /// Per-agent state, when it was checked on this pass. Empty means unchanged.
        public let agentStatuses: [AgentStatus]
        /// nil means "not sampled this pass", so the row keeps the last good reading
        /// instead of blanking every time a probe is skipped or throttled.
        public let metrics: SystemMetrics?
        public let activeSessions: Int?

        public init(machineID: UUID, health: ConnectionHealth, latency: TimeInterval? = nil,
                    detail: String? = nil, agentStatuses: [AgentStatus] = [],
                    metrics: SystemMetrics? = nil, activeSessions: Int? = nil) {
            self.machineID = machineID
            self.health = health
            self.latency = latency
            self.detail = detail
            self.agentStatuses = agentStatuses
            self.metrics = metrics
            self.activeSessions = activeSessions
        }
    }

    private var task: Task<Void, Never>?
    /// Claude's check is an SSH round trip rather than a loopback request, so it runs on a
    /// slower cadence than the tunnel probe.
    private var lastMetricsSample: [UUID: Date] = [:]
    private let metricsSampleInterval: TimeInterval = 30
    private var lastClaudeCheck: [UUID: Date] = [:]
    private let claudeCheckInterval: TimeInterval = 60
    private let session: URLSession
    private var interval: TimeInterval
    private var onProbe: (@Sendable (Probe) -> Void)?

    public init(interval: TimeInterval = 15) {
        self.interval = interval
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        // The tunnel is on loopback; a proxy would break it.
        configuration.connectionProxyDictionary = [:]
        session = URLSession(configuration: configuration)
    }

    public func setInterval(_ seconds: TimeInterval) { interval = max(5, seconds) }

    public func start(machines: @escaping @Sendable () -> [Machine],
                      onProbe: @escaping @Sendable (Probe) -> Void) {
        self.onProbe = onProbe
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let current = machines()
                await withTaskGroup(of: Probe.self) { group in
                    for machine in current where machine.stage == .ready || machine.stage == .failed {
                        group.addTask { await self.probe(machine) }
                    }
                    for await probe in group { onProbe(probe) }
                }
                let delay = await self.interval
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    /// One health check, per agent, against the thing that agent actually uses.
    ///
    /// For Codex that is SSH: the desktop app finds the host in `~/.ssh/config` and starts
    /// `codex app-server` on it over SSH itself. The `--listen`/tunnel pair Codex Remote also
    /// sets up is Codex's separate, experimental "remote terminal UI" mode — a machine can
    /// be perfectly usable from the Codex app with no tunnel at all, and reporting it as
    /// offline because a tunnel died (which is exactly what happened to codex-demo) points
    /// the user at a problem they do not have.
    public func probe(_ machine: Machine) async -> Probe {
        var agentStatuses: [AgentStatus] = []

        // nil when skipped, which the caller reads as "keep the last reading".
        let sample = machine.stage == .ready && shouldSampleMetrics(machine.id)
            ? await probeMetrics(machine)
            : nil
        let metrics = sample?.0
        let activeSessions = sample?.1

        if machine.runs(.claudeCode), shouldCheckClaude(machine.id) {
            agentStatuses.append(await probeClaude(machine))
        }

        if machine.runs(.codex) {
            let codex = await probeCodex(machine)
            agentStatuses.append(codex)
            if !machine.runs(.claudeCode) {
                return Probe(machineID: machine.id,
                             health: codex.isRunning ? .online : .offline,
                             detail: codex.isRunning ? nil : codex.detail,
                             agentStatuses: agentStatuses, metrics: metrics, activeSessions: activeSessions)
            }
        }

        // A machine that runs only Claude has no tunnel, so tunnel health is meaningless
        // for it — its readiness is whether Remote Control is up.
        guard machine.needsTunnel else {
            let claude = agentStatuses.first { $0.kind == .claudeCode }
                ?? machine.status(of: .claudeCode)
            return Probe(machineID: machine.id,
                         health: claude?.isRunning == true ? .online : .offline,
                         detail: claude?.isRunning == true ? nil : "Claude Remote Control is not running",
                         agentStatuses: agentStatuses, metrics: metrics, activeSessions: activeSessions)
        }

        let tunnelUp = TunnelManager.shared.isRunning(machine.id)
        let started = Date()
        var request = URLRequest(url: machine.healthURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 5

        do {
            let (_, response) = try await session.data(for: request)
            let latency = Date().timeIntervalSince(started)
            guard let http = response as? HTTPURLResponse else {
                return Probe(machineID: machine.id, health: .degraded, latency: latency,
                             detail: "health endpoint gave a non-HTTP response",
                             agentStatuses: agentStatuses, metrics: metrics, activeSessions: activeSessions)
            }
            if (200..<400).contains(http.statusCode) {
                agentStatuses.append(AgentStatus(kind: .codex, isRunning: true,
                                                 endpoint: machine.endpoint, checkedAt: Date()))
                return Probe(machineID: machine.id, health: .online, latency: latency,
                             agentStatuses: agentStatuses, metrics: metrics, activeSessions: activeSessions)
            }
            return Probe(machineID: machine.id, health: .degraded, latency: latency,
                         detail: "health endpoint returned HTTP \(http.statusCode)",
                         agentStatuses: agentStatuses, metrics: metrics, activeSessions: activeSessions)
        } catch {
            agentStatuses.append(AgentStatus(kind: .codex, isRunning: false,
                                             endpoint: machine.endpoint, checkedAt: Date()))
            if !tunnelUp {
                return Probe(machineID: machine.id, health: .offline,
                             detail: "SSH tunnel is not running", agentStatuses: agentStatuses, metrics: metrics, activeSessions: activeSessions)
            }
            return Probe(machineID: machine.id, health: .degraded,
                         detail: "tunnel is up but the app-server did not answer",
                         agentStatuses: agentStatuses, metrics: metrics, activeSessions: activeSessions)
        }
    }

    /// Sampling costs an SSH round trip, so it runs on its own slower cadence than the
    /// health poll rather than on every tick.
    private func shouldSampleMetrics(_ id: UUID) -> Bool {
        let last = lastMetricsSample[id] ?? .distantPast
        guard Date().timeIntervalSince(last) >= metricsSampleInterval else { return false }
        lastMetricsSample[id] = Date()
        return true
    }

    private func shouldCheckClaude(_ id: UUID) -> Bool {
        let last = lastClaudeCheck[id] ?? .distantPast
        guard Date().timeIntervalSince(last) >= claudeCheckInterval else { return false }
        lastClaudeCheck[id] = Date()
        return true
    }

    /// Asks the machine whether its Remote Control unit is up, and picks the session URL
    /// out of the log so the menu bar can link straight to it.
    /// What the Codex desktop app needs, checked the way it needs it: reachable over SSH
    /// by the alias in ~/.ssh/config, with `codex` on the login-shell PATH and signed in.
    /// A tunnel is deliberately not part of this — see `probe`.
    private func probeCodex(_ machine: Machine) async -> AgentStatus {
        guard let address = machine.instance?.sshAddress else {
            return AgentStatus(kind: .codex, isRunning: false,
                               detail: "no address", checkedAt: Date())
        }
        let ssh = SSHClient(host: address, user: machine.sshUser,
                            privateKeyPath: machine.privateKeyPath, port: machine.sshPort,
                            connectTimeout: 8)
        // The login shell, because that is the shell the app starts the app-server in: a
        // `codex` that only resolves in a non-login shell would pass here and fail there.
        let command = "bash -lc 'command -v codex >/dev/null || exit 3; "
            + "codex login status 2>&1' "

        guard let result = try? await ssh.run(command, timeout: 25) else {
            return AgentStatus(kind: .codex, isRunning: false,
                               detail: "could not reach the machine", checkedAt: Date())
        }
        guard result.succeeded else {
            let detail = result.exitCode == 3
                ? "codex is not on the remote PATH"
                : AgentStatus.needsSignIn
            return AgentStatus(kind: .codex, isRunning: false, detail: detail, checkedAt: Date())
        }
        guard result.stdout.contains("Logged in") else {
            return AgentStatus(kind: .codex, isRunning: false,
                               detail: AgentStatus.needsSignIn, checkedAt: Date())
        }
        return AgentStatus(kind: .codex, isRunning: true,
                           endpoint: "ssh \(machine.sshHostAlias)",
                           detail: "ready for the Codex app", checkedAt: Date())
    }

    /// One short sample of what the box is doing, for the line under its name.
    ///
    /// CPU comes from two reads of `/proc/stat` 300ms apart rather than `/proc/loadavg`:
    /// load average is a queue length, not a percentage, and on a 2-core box a load of 2
    /// would read as "200%" to anyone expecting one. Memory uses `MemAvailable`, which is
    /// what is actually reclaimable — `MemFree` alone counts the page cache as used and
    /// would show a healthy machine as nearly full.
    private func probeMetrics(_ machine: Machine) async -> (SystemMetrics, Int?)? {
        guard let address = machine.instance?.sshAddress else { return nil }
        let ssh = SSHClient(host: address, user: machine.sshUser,
                            privateKeyPath: machine.privateKeyPath, port: machine.sshPort,
                            connectTimeout: 8)
        let command = """
        read _ a b c d e f g h rest < /proc/stat
        idle1=$((d+e)); total1=$((a+b+c+d+e+f+g+h))
        sleep 0.3
        read _ a b c d e f g h rest < /proc/stat
        idle2=$((d+e)); total2=$((a+b+c+d+e+f+g+h))
        awk -v i1="$idle1" -v t1="$total1" -v i2="$idle2" -v t2="$total2" \
            'BEGIN { dt = t2 - t1; if (dt <= 0) print 0; else printf "%.1f", (1 - (i2-i1)/dt) * 100 }'
        echo
        awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{print t, a}' /proc/meminfo

        # Codex: ask the shared daemon the desktop app talks to. No socket means no daemon,
        # which means nothing is running — not an error, just zero.
        sock="$HOME/.codex/app-server-control/app-server-control.sock"
        if [ -S "$sock" ]; then
          printf '%s\\n%s\\n' \
            '{"id":1,"method":"initialize","params":{"clientInfo":{"name":"codex-remote","title":"Codex Remote","version":"1"}}}' \
            '{"id":2,"method":"thread/loaded/list","params":{}}' \
          | timeout 10 codex app-server proxy 2>/dev/null \
          | grep -o '"id": *2.*' | head -1 | grep -o '"threadId"' | wc -l
        else
          echo 0
        fi

        # Claude: its host daemon prints how many sessions it is carrying.
        sed 's/\\x1b\\[[0-9;?]*[a-zA-Z]//g' /var/log/codex-remote-claude.log 2>/dev/null \
          | grep -ao 'Capacity: [0-9]*' | tail -1 | grep -o '[0-9]*' || echo
        """
        guard let result = try? await ssh.run(command, timeout: 30), result.succeeded else { return nil }
        let lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count >= 2, let cpu = Double(lines[0]) else { return nil }
        let memory = lines[1].split(separator: " ").compactMap { Int64($0) }
        guard memory.count == 2, memory[0] > 0 else { return nil }
        // /proc/meminfo is in kibibytes.
        let total = memory[0] * 1024
        let available = memory[1] * 1024

        // Sum what each agent reports. An agent the machine does not run contributes
        // nothing, and a line that did not come back leaves the total unknown rather than
        // claiming zero — "safe to stop" must never be a guess.
        var sessions: Int?
        if machine.runs(.codex), lines.count > 2, let codex = Int(lines[2]) {
            sessions = (sessions ?? 0) + codex
        }
        if machine.runs(.claudeCode), lines.count > 3, let claude = Int(lines[3]) {
            sessions = (sessions ?? 0) + claude
        }

        let sample = SystemMetrics(cpuPercent: max(0, min(100, cpu)),
                                   memoryUsedBytes: max(0, total - available),
                                   memoryTotalBytes: total)
        return (sample, sessions)
    }

    private func probeClaude(_ machine: Machine) async -> AgentStatus {
        guard let address = machine.instance?.sshAddress else {
            return AgentStatus(kind: .claudeCode, isRunning: false,
                               detail: "no address", checkedAt: Date())
        }
        let ssh = SSHClient(host: address, user: machine.sshUser,
                            privateKeyPath: machine.privateKeyPath, port: machine.sshPort,
                            connectTimeout: 8)
        // Three answers in one round trip: is the unit up, is the machine signed in, and
        // what session is it attached to. The sign-in answer matters because "not running"
        // and "not signed in" need different things from the user, and a probe that
        // flattened them would hide the Sign in button after the first poll.
        let command = "systemctl is-active \(BootstrapScript.claudeServiceName) 2>/dev/null; "
            + "su - \(BootstrapScript.claudeUser) -c 'claude auth status' 2>/dev/null "
            + "| grep -q '\"loggedIn\": true' && echo CODEX_REMOTE_SIGNED_IN || echo CODEX_REMOTE_SIGNED_OUT; "
            + "sed 's/\\x1b\\[[0-9;?]*[a-zA-Z]//g' /var/log/codex-remote-claude.log 2>/dev/null "
            + "| grep -ao 'https://claude.ai/code/session_[A-Za-z0-9]*' | tail -1"

        guard let result = try? await ssh.run(command, timeout: 25), result.succeeded else {
            return AgentStatus(kind: .claudeCode, isRunning: false,
                               endpoint: machine.status(of: .claudeCode)?.endpoint,
                               detail: "could not reach the machine", checkedAt: Date())
        }
        let lines = result.stdout.split(separator: "\n").map(String.init)
        let isActive = lines.first?.trimmingCharacters(in: .whitespaces) == "active"
        let isSignedIn = result.stdout.contains("CODEX_REMOTE_SIGNED_IN")
        let url = lines.first { $0.hasPrefix("https://claude.ai/code/") }

        let detail: String
        if isActive { detail = "Remote Control" }
        else if !isSignedIn { detail = AgentStatus.needsSignIn }
        else { detail = "not running" }

        return AgentStatus(kind: .claudeCode, isRunning: isActive,
                           endpoint: url ?? machine.status(of: .claudeCode)?.endpoint,
                           detail: detail, checkedAt: Date())
    }
}

/// Finds a free loopback port for a new machine's tunnel, avoiding ports already claimed
/// by other machines in the registry.
public enum PortAllocator {
    public static func allocate(basePort: Int, taken: Set<Int>) -> Int {
        var candidate = basePort
        while candidate < basePort + 500 {
            if !taken.contains(candidate), isFree(candidate) { return candidate }
            candidate += 1
        }
        return basePort + Int.random(in: 500..<2000)
    }

    /// Tries to bind the port on 127.0.0.1; if the bind succeeds the port is free right now.
    public static func isFree(_ port: Int) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return true }
        defer { close(descriptor) }
        var yes: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bound == 0
    }
}
