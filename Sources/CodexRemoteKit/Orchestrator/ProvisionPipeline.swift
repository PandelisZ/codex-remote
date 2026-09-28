import Foundation
import Security

/// Drives one machine from "nothing" to "a Codex agent this Mac can open".
///
/// The pipeline is entirely provider-agnostic — it takes a `ComputeProvider` and never
/// asks what kind it is. Everything after the instance exists is plain SSH, so a provider
/// only has to be able to create a Linux box with an SSH key on it.
public final class ProvisionPipeline: @unchecked Sendable {
    public struct Progress: Sendable {
        public let machineID: UUID
        public let stage: ProvisionStage
        public let message: String
    }

    private let provider: ComputeProvider
    private let credentials: CredentialStore
    private let settings: AppSettings
    private let onProgress: @Sendable (Progress) -> Void
    private let onMachineUpdate: @Sendable (Machine) -> Void
    /// Every machine Codex Remote knows about, so the SSH config can be written as a whole.
    private let allMachinesForSSH: @Sendable () -> [Machine]

    public init(provider: ComputeProvider,
                credentials: CredentialStore,
                settings: AppSettings,
                onProgress: @escaping @Sendable (Progress) -> Void,
                onMachineUpdate: @escaping @Sendable (Machine) -> Void,
                allMachines: @escaping @Sendable () -> [Machine] = { [] }) {
        self.provider = provider
        self.credentials = credentials
        self.settings = settings
        self.onProgress = onProgress
        self.onMachineUpdate = onMachineUpdate
        self.allMachinesForSSH = allMachines
    }

    /// Runs every stage. On failure the machine is left in `.failed` with the reason
    /// attached — the instance is *not* destroyed, so the user can retry or SSH in and look.
    public func run(machine startingMachine: Machine, allMachines: @escaping @Sendable () -> [Machine]) async -> Machine {
        var machine = startingMachine
        do {
            machine = try await createInstance(machine)
            machine = try await waitForBoot(machine)
            machine = try await waitForSSH(machine)
            machine = try await installBase(machine)
            machine = try await installAgents(machine)
            machine = try await syncCredentials(machine)
            machine = try await installService(machine)
            machine = try await startClaude(machine)
            machine = try await openTunnel(machine)
            machine = try await registerWithCodex(machine, allMachines: allMachines())
            machine.stage = .ready
            machine.lastError = nil
            publish(machine, readySummary(for: machine))
            return machine
        } catch {
            machine.stage = .failed
            machine.lastError = error.localizedDescription
            Log.shared.error("provision", "\(machine.name): \(error.localizedDescription)")
            publish(machine, error.localizedDescription)
            return machine
        }
    }

    /// Re-runs the remote half against an instance that already exists. Used by "Repair".
    public func repair(machine startingMachine: Machine, allMachines: @escaping @Sendable () -> [Machine]) async -> Machine {
        var machine = startingMachine
        do {
            guard machine.instanceID != nil else {
                return await run(machine: machine, allMachines: allMachines)
            }
            machine = try await refreshInstance(machine)
            machine = try await waitForSSH(machine)
            machine = try await installBase(machine)
            machine = try await installAgents(machine)
            machine = try await syncCredentials(machine)
            machine = try await installService(machine)
            machine = try await startClaude(machine)
            machine = try await openTunnel(machine)
            machine = try await registerWithCodex(machine, allMachines: allMachines())
            machine.stage = .ready
            machine.lastError = nil
            publish(machine, "Repaired and ready")
            return machine
        } catch {
            machine.stage = .failed
            machine.lastError = error.localizedDescription
            publish(machine, error.localizedDescription)
            return machine
        }
    }

    // MARK: - Stages

    private func createInstance(_ input: Machine) async throws -> Machine {
        var machine = input
        machine.stage = .creatingInstance
        publish(machine, "Registering the Codex Remote SSH key with \(provider.displayName)")

        let keyPair = try await SSHKeyManager.ensureKeyPair()
        // An adopted host already authorises one of the user's own keys; only machines
        // Codex Remote creates get Codex Remote's key installed on them.
        if let override = machine.spec.privateKeyPathOverride, !override.isEmpty {
            machine.privateKeyPath = (override as NSString).expandingTildeInPath
        } else {
            machine.privateKeyPath = keyPair.privateKeyPath
        }
        let keyID = try await provider.ensureSSHKey(name: "codex-remote-\(Host.current().localizedName ?? "mac")",
                                                    publicKey: keyPair.publicKey)

        try await checkSizeIsOfferedInRegion(machine.spec)
        publish(machine, "Creating a \(machine.spec.size) in \(machine.spec.region)")
        let request = InstanceRequest(
            name: machine.spec.name,
            region: machine.spec.region,
            size: machine.spec.size,
            image: machine.spec.image,
            sshKeyIdentifiers: keyID.isEmpty ? [] : [keyID],
            userData: BootstrapScript.cloudInit(),
            labels: ["managed-by": "codex-remote"],
            workspaceKey: machine.id.uuidString.lowercased()
        )
        let instance = try await provider.createInstance(request)
        machine.instanceID = instance.id
        machine.instance = instance
        machine.sshUser = provider.defaultSSHUser(forImage: machine.spec.image)
        publish(machine, "Created \(provider.displayName) instance \(instance.id)")
        return machine
    }

    /// Providers answer a bad region/size pairing with something unhelpful — Hetzner says
    /// "unsupported location for server type" and nothing about which locations would
    /// work. Check it up front and say what the real options are.
    private func checkSizeIsOfferedInRegion(_ spec: MachineSpec) async throws {
        guard let capabilities = try? await provider.capabilities() else { return }
        guard let size = capabilities.sizes.first(where: { $0.slug == spec.size }) else {
            let names = capabilities.sizes.prefix(8).map(\.slug).joined(separator: ", ")
            throw ProviderError.creationFailed(
                "\(provider.displayName) has no server type called \"\(spec.size)\". Try one of: \(names)…")
        }
        guard size.availableRegions.isEmpty || size.availableRegions.contains(spec.region) else {
            throw ProviderError.creationFailed(
                "\(provider.displayName) does not offer \(spec.size) in \(spec.region). "
                + "It is available in: \(size.availableRegions.sorted().joined(separator: ", ")).")
        }
        guard capabilities.regions.contains(where: { $0.slug == spec.region }) else {
            throw ProviderError.creationFailed(
                "\(provider.displayName) has no region called \"\(spec.region)\". "
                + "Try one of: \(capabilities.regions.map(\.slug).joined(separator: ", ")).")
        }
    }

    private func refreshInstance(_ input: Machine) async throws -> Machine {
        var machine = input
        guard let id = machine.instanceID else { return machine }
        guard let instance = try await provider.instance(id: id) else {
            throw ProviderError.instanceNotFound(id)
        }
        if instance.state == .stopped {
            publish(machine, "Instance is powered off; starting it")
            try await provider.power(.start, instanceID: id)
        }
        machine.instance = instance
        return try await waitForBoot(machine)
    }

    private func waitForBoot(_ input: Machine) async throws -> Machine {
        var machine = input
        guard let id = machine.instanceID else { return machine }
        machine.stage = .waitingForBoot
        publish(machine, "Waiting for the provider to report a running instance with an IP")

        let instance = try await provider.waitForRunningInstance(id: id, timeout: 420) { current in
            Log.shared.debug("provision", "\(machine.name): state=\(current.state.rawValue) ip=\(current.sshAddress ?? "—")")
        }
        machine.instance = instance
        publish(machine, "Instance is up at \(instance.sshAddress ?? "unknown")")
        return machine
    }

    private func waitForSSH(_ input: Machine) async throws -> Machine {
        var machine = input
        machine.stage = .waitingForSSH
        guard let address = machine.instance?.sshAddress else {
            throw ProviderError.creationFailed("the provider never reported a public address")
        }
        // A recycled cloud IP may still carry an old host key in Codex Remote's known_hosts;
        // clear it so accept-new can record the new one instead of failing.
        await SSHConfigManager.forgetHostKey(address: address, port: machine.sshPort)

        publish(machine, "Waiting for SSH on \(address)")
        let ssh = client(for: machine)
        try await ssh.waitUntilReachable(timeout: 300) { attempt in
            if attempt % 6 == 0 {
                Log.shared.debug("provision", "\(machine.name): still waiting for SSH (attempt \(attempt))")
            }
        }
        publish(machine, "SSH is up")

        // Write the host entry now, for every machine. It used to happen only inside the
        // Codex registration step, so a Claude-only machine was never reachable as
        // `ssh codex-remote-<name>` even though SSH is how Codex Remote talks to it.
        _ = try? SSHConfigManager.sync(machines: allMachinesForSSH() + [machine])
        return machine
    }

    private func installBase(_ input: Machine) async throws -> Machine {
        var machine = input
        machine.stage = .installingBase
        publish(machine, "Installing base packages (this is the slow part)")
        let ssh = client(for: machine)
        let result = try await ssh.runScript(BootstrapScript.basePackages(plan(for: machine)),
                                             timeout: 1800, label: "base packages")
        relay(machine, result)
        return machine
    }

    /// Installs whichever agents this machine is meant to run.
    private func installAgents(_ input: Machine) async throws -> Machine {
        var machine = input
        let ssh = client(for: machine)

        // Node is no longer part of any agent's install — Codex is a standalone binary and
        // Claude Code brings its own runtime — so it goes on only when an MCP server that is
        // being carried over actually launches through it. On a stock Ubuntu image that one
        // apt call was 87 seconds, which is most of a provision, spent on nothing.
        if machine.spec.syncMCPServers, MCPSync.plan().needsNode {
            publish(machine, "Installing Node.js for the MCP servers that need it")
            let result = try await ssh.runScript(BootstrapScript.installNode(),
                                                 timeout: 1800, label: "Node install")
            relay(machine, result)
        }

        if machine.runs(.codex) {
            machine.stage = .installingCodex
            publish(machine, "Installing the Codex CLI")
            let result = try await ssh.runScript(BootstrapScript.installCodex(plan(for: machine)),
                                                 timeout: 1800, label: "Codex install")
            relay(machine, result)
            if let version = value(named: "CODEX_VERSION", in: result.stdout) {
                machine.codexVersion = version
                publish(machine, "Remote Codex: \(version)")
            }
        }

        if machine.runs(.claudeCode) {
            machine.stage = .installingClaude
            publish(machine, "Installing Claude Code")
            let result = try await ssh.runScript(BootstrapScript.installClaudeCode(plan(for: machine)),
                                                 timeout: 1800, label: "Claude Code install")
            relay(machine, result)
            if let version = value(named: "CLAUDE_VERSION", in: result.stdout) {
                publish(machine, "Remote Claude Code: \(version)")
            }
        }
        return machine
    }

    private func value(named key: String, in output: String) -> String? {
        output.split(separator: "\n")
            .first { $0.hasPrefix("\(key)=") }
            .map { String($0.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces) }
    }

    private func syncCredentials(_ input: Machine) async throws -> Machine {
        var machine = input
        let ssh = client(for: machine)
        let home = machine.sshUser == "root" ? "/root" : "/home/\(machine.sshUser)"
        machine.stage = .syncingCredentials

        if machine.runs(.codex) {
            let codexHome = "\(home)/.codex"
            if machine.spec.syncCodexCredentials {
                publish(machine, "Copying this Mac's Codex credentials")
                try await CodexRegistrar.syncCredentials(to: ssh, codexHome: codexHome)
            } else {
                publish(machine, "Skipping Codex credentials — sign in on the machine with `codex login`")
            }

            var config = CodexRegistrar.remoteConfig(workspacePath: machine.spec.workspacePath)
            if machine.spec.syncMCPServers {
                let plan = MCPSync.plan()
                if !plan.included.isEmpty {
                    config += "\n" + MCPSync.codexConfigTOML(plan.included)
                }
                reportMCPPlan(plan, on: machine)
            }
            try await ssh.writeFile(config, to: "\(codexHome)/config.toml", mode: "0600")
        }

        if machine.runs(.claudeCode) {
            // Claude Code is *not* given a copy of this Mac's login. It authenticates for
            // inference, but its access token is usually expired and refreshing it consumes
            // a single-use refresh token — whichever install refreshes first wins, and the
            // other falls back and loses Remote Control. The machine signs in for itself
            // instead; `startClaude` says so when it has not yet.
            let plan = plan(for: machine)
            let settings = try MCPSync.claudeSettingsJSON(
                machine.spec.syncMCPServers ? MCPSync.plan().included : [],
                workspacePath: plan.claudeWorkspace,
                includePlugins: machine.spec.syncMCPServers)
            try await ssh.writeFile(settings, to: "\(plan.claudeHome)/.claude/settings.json",
                                    mode: "0600")
            // Written as root over SSH, so hand it to the account that has to read it.
            _ = try? await ssh.run("chown -R \(plan.claudeUser):\(plan.claudeUser) "
                                   + "\(plan.claudeHome)/.claude", timeout: 60)
        }
        return machine
    }

    /// Says plainly which MCP servers travelled and which could not, rather than leaving
    /// the user to discover a missing server on the machine later.
    private func reportMCPPlan(_ plan: MCPSync.Plan, on machine: Machine) {
        if !plan.included.isEmpty {
            publish(machine, "MCP servers copied: \(plan.included.map(\.name).joined(separator: ", "))")
        }
        if !plan.skipped.isEmpty {
            let names = plan.skipped.map { "\($0.server.name) (\($0.reason))" }
            publish(machine, "Left on this Mac: \(names.joined(separator: "; "))")
        }
    }

    private func installService(_ input: Machine) async throws -> Machine {
        var machine = input
        machine.stage = .installingService
        let ssh = client(for: machine)

        if machine.runs(.codex) {
            publish(machine, "Issuing an app-server token and installing the Codex service")

            // A fresh 256-bit token per machine, kept in the login keychain on this side and
            // in a root-only file on the other. It never appears in a config file, a launcher
            // script, a log line, or a command line.
            let token = Self.generateToken()
            try credentials.write(token, for: machine.tokenKeychainAccount)
            try await ssh.writeFile(token.raw, to: "/etc/codex-remote/appserver.token", mode: "0600")

            let result = try await ssh.runScript(BootstrapScript.installService(plan(for: machine)),
                                                 timeout: 600, label: "app-server service")
            relay(machine, result)
            machine.agentStatuses = machine.agentStatuses.filter { $0.kind != .codex } + [
                AgentStatus(kind: .codex, isRunning: true, endpoint: machine.endpoint, checkedAt: Date()),
            ]
        }

        // Extra packages and the user's setup script are handed to a systemd unit and left
        // to run. They were inline, which kept the machine out of Ready for as long as they
        // took — a minute for a few packages, far longer for a script that builds a
        // toolchain — while Codex and Claude had been usable the whole time.
        if let deferred = BootstrapScript.deferredSetup(plan(for: machine)) {
            let result = try await ssh.runScript(deferred, timeout: 120, label: "deferred setup")
            relay(machine, result)
            publish(machine, "Extra packages and your setup script are running in the "
                    + "background — `codex-remote status \(machine.name)` reports when they finish")
        }
        return machine
    }

    /// Starts Claude Code's Remote Control session. Unlike Codex there is no tunnel: the
    /// agent dials out to Anthropic, and the machine turns up in the user's account.
    ///
    /// A machine that has not signed in yet is not a failure — the rest of it works, and
    /// signing in is a one-off browser step the user does when convenient. It is reported
    /// and left for `signIn`.
    private func startClaude(_ input: Machine) async throws -> Machine {
        var machine = input
        guard machine.runs(.claudeCode) else { return machine }

        machine.stage = .startingClaude
        let ssh = client(for: machine)

        guard await ClaudeLogin.isSignedIn(on: ssh) else {
            machine.agentStatuses = machine.agentStatuses.filter { $0.kind != .claudeCode } + [
                AgentStatus(kind: .claudeCode, isRunning: false,
                            detail: AgentStatus.needsSignIn, checkedAt: Date()),
            ]
            publish(machine, "Claude Code is installed but not signed in — "
                    + "run `codex-remote claude-login \(machine.name)`, or use Sign in to Claude in the menu bar.")
            return machine
        }

        publish(machine, "Connecting Claude Code to your account")
        let result = try await ssh.runScript(
            // The session is named what the user named the machine, so it reads the same
            // in Codex Remote, in the Codex app, and in the Claude session list.
            BootstrapScript.installClaudeService(plan(for: machine),
                                                 sessionName: machine.name),
            timeout: 600, label: "Claude Remote Control service")
        relay(machine, result)

        let sessionURL = value(named: "CLAUDE_SESSION_URL", in: result.stdout)
        machine.agentStatuses = machine.agentStatuses.filter { $0.kind != .claudeCode } + [
            AgentStatus(kind: .claudeCode, isRunning: true, endpoint: sessionURL,
                        detail: "Remote Control", checkedAt: Date()),
        ]
        publish(machine, sessionURL.map { "Claude is live at \($0)" }
                ?? "Claude Remote Control is live in your account")
        return machine
    }

    private func openTunnel(_ input: Machine) async throws -> Machine {
        var machine = input
        // A Claude-only machine has nothing listening on loopback to forward.
        guard machine.needsTunnel else { return machine }
        machine.stage = .openingTunnel
        publish(machine, "Opening the SSH tunnel on 127.0.0.1:\(machine.localPort)")

        TunnelManager.shared.stop(machine.id)
        TunnelManager.shared.start(machine)

        let monitor = HealthMonitor()
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            let probe = await monitor.probe(machine)
            if probe.health == .online {
                machine.health = .online
                machine.lastHealthyAt = Date()
                publish(machine, "Codex app-server is answering through the tunnel")
                return machine
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        throw ProviderError.timeout("the tunnel came up but \(machine.healthURL) never answered")
    }

    private func registerWithCodex(_ input: Machine, allMachines: [Machine]) async throws -> Machine {
        var machine = input
        guard machine.runs(.codex) else { return machine }
        machine.stage = .registeringWithCodex
        publish(machine, "Registering with local Codex")

        var roster = allMachines.filter { $0.id != machine.id }
        roster.append(machine)
        let registration = try CodexRegistrar.register(machine, allMachines: roster)
        publish(machine, "Registered: `\(URL(fileURLWithPath: registration.launcherPath).lastPathComponent)` and `ssh \(registration.sshAlias)`")

        // The machine has to be marked ready before it counts as eligible for the
        // desktop app's remote list, so flip the stage first and register second.
        machine.stage = .ready
        if settings.registerWithCodexApp, CodexAppRegistrar.isCodexAppInstalled {
            var readyRoster = roster
            if let index = readyRoster.firstIndex(where: { $0.id == machine.id }) {
                readyRoster[index] = machine
            }
            do {
                let result = try CodexAppRegistrar.sync(machines: readyRoster)
                if result.changedAnything {
                    publish(machine, "Added to the Codex app's Connections.")
                }
            } catch CodexAppRegistrar.Failure.codexAppRunning {
                // Not a failure. The host block is in ~/.ssh/config, which is how Codex
                // finds remote hosts, so it shows up on the app's next launch — only the
                // pre-seeded project folder is missed.
                publish(machine, "Restart the Codex app and \(machine.sshHostAlias) will be there under Connections.")
            } catch {
                // Never fail a provision over this: the machine still works from the CLI.
                publish(machine, "Machine is up, but it could not be added to the Codex app: \(error.localizedDescription)")
            }
        }
        machine.stage = .registeringWithCodex
        return machine
    }

    // MARK: - Helpers

    /// What to tell the user when a machine comes up, in terms of the agents it actually
    /// runs — a Claude-only machine has no `codex --remote` command to offer.
    private func readySummary(for machine: Machine) -> String {
        var parts: [String] = []
        if machine.runs(.codex) { parts.append(CodexRegistrar.connectCommand(for: machine)) }
        if machine.runs(.claudeCode) {
            parts.append(machine.claudeSessionURL.map { "Claude at \($0)" }
                         ?? "Claude in your account")
        }
        return parts.isEmpty ? "Ready" : "Ready — " + parts.joined(separator: " · ")
    }

    private func plan(for machine: Machine) -> BootstrapPlan {
        BootstrapPlan(
            workspacePath: machine.spec.workspacePath,
            remotePort: machine.remotePort,
            codexVersion: settings.codexVersionPin,
            extraPackages: machine.spec.extraPackages,
            postSetupScript: machine.spec.postSetupScript,
            idleShutdownMinutes: machine.spec.idleShutdownMinutes,
            serviceUser: machine.sshUser,
            hostname: machine.name
        )
    }

    private func client(for machine: Machine) -> SSHClient {
        SSHClient(host: machine.instance?.sshAddress ?? "",
                  user: machine.sshUser,
                  privateKeyPath: machine.privateKeyPath,
                  port: machine.sshPort)
    }

    /// Surfaces the `::codex-remote::` markers the bootstrap script emits as UI progress lines.
    private func relay(_ machine: Machine, _ result: CommandResult) {
        for line in result.stdout.split(separator: "\n") where line.hasPrefix("::codex-remote:: ") {
            publish(machine, String(line.dropFirst("::codex-remote:: ".count)))
        }
    }

    private func publish(_ machine: Machine, _ message: String) {
        Log.shared.info("provision", "\(machine.name): \(message)")
        onProgress(Progress(machineID: machine.id, stage: machine.stage, message: message))
        onMachineUpdate(machine)
    }

    static func generateToken() -> Secret {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Secret(bytes.map { String(format: "%02x", $0) }.joined())
    }
}
