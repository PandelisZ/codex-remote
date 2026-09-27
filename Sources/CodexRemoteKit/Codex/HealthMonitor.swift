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

        public init(machineID: UUID, health: ConnectionHealth, latency: TimeInterval? = nil,
                    detail: String? = nil, agentStatuses: [AgentStatus] = []) {
            self.machineID = machineID
            self.health = health
            self.latency = latency
            self.detail = detail
            self.agentStatuses = agentStatuses
        }
    }

    private var task: Task<Void, Never>?
    /// Claude's check is an SSH round trip rather than a loopback request, so it runs on a
    /// slower cadence than the tunnel probe.
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
                             agentStatuses: agentStatuses)
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
                         agentStatuses: agentStatuses)
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
                             agentStatuses: agentStatuses)
            }
            if (200..<400).contains(http.statusCode) {
                agentStatuses.append(AgentStatus(kind: .codex, isRunning: true,
                                                 endpoint: machine.endpoint, checkedAt: Date()))
                return Probe(machineID: machine.id, health: .online, latency: latency,
                             agentStatuses: agentStatuses)
            }
            return Probe(machineID: machine.id, health: .degraded, latency: latency,
                         detail: "health endpoint returned HTTP \(http.statusCode)",
                         agentStatuses: agentStatuses)
        } catch {
            agentStatuses.append(AgentStatus(kind: .codex, isRunning: false,
                                             endpoint: machine.endpoint, checkedAt: Date()))
            if !tunnelUp {
                return Probe(machineID: machine.id, health: .offline,
                             detail: "SSH tunnel is not running", agentStatuses: agentStatuses)
            }
            return Probe(machineID: machine.id, health: .degraded,
                         detail: "tunnel is up but the app-server did not answer",
                         agentStatuses: agentStatuses)
        }
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
