import Foundation

/// Where a machine is in the create → bootstrap → connected pipeline.
/// The menu bar renders this directly, so the ordering is the ordering the user sees.
public enum ProvisionStage: String, Codable, Sendable, CaseIterable {
    case queued
    case creatingInstance
    case waitingForBoot
    case waitingForSSH
    case installingBase
    case installingCodex
    case installingClaude
    case syncingCredentials
    case installingService
    case startingClaude
    case openingTunnel
    case registeringWithCodex
    case ready
    case failed

    public var label: String {
        switch self {
        case .queued: return "Queued"
        case .creatingInstance: return "Creating server"
        case .waitingForBoot: return "Waiting for boot"
        case .waitingForSSH: return "Waiting for SSH"
        case .installingBase: return "Installing base packages"
        case .installingCodex: return "Installing Codex"
        case .installingClaude: return "Installing Claude Code"
        case .syncingCredentials: return "Syncing Codex credentials"
        case .installingService: return "Installing app-server service"
        case .startingClaude: return "Connecting Claude to your account"
        case .openingTunnel: return "Opening SSH tunnel"
        case .registeringWithCodex: return "Registering with local Codex"
        case .ready: return "Ready"
        case .failed: return "Failed"
        }
    }

    /// Rough fraction complete, for the progress bar.
    public var progress: Double {
        guard let index = ProvisionStage.ordered.firstIndex(of: self) else { return 1 }
        return Double(index) / Double(ProvisionStage.ordered.count - 1)
    }

    static let ordered: [ProvisionStage] = [
        .queued, .creatingInstance, .waitingForBoot, .waitingForSSH, .installingBase,
        .installingCodex, .installingClaude, .syncingCredentials, .installingService,
        .startingClaude, .openingTunnel, .registeringWithCodex, .ready,
    ]
}

/// Live connectivity of the Codex app-server on the machine, as seen from this Mac.
public enum ConnectionHealth: String, Codable, Sendable {
    case unknown
    case online       // tunnel up and /healthz answered
    case degraded     // tunnel up but the app-server is not answering
    case offline      // no tunnel
}

/// How the user wants Codex Remote to treat the machine's power state.
public enum PowerIntent: String, Codable, Sendable {
    case up       // keep it running
    case down     // keep it stopped
}

/// A cheap sample of what the machine is actually doing, so the row can say something
/// about the box itself rather than repeating a local port number back at you.
public struct SystemMetrics: Codable, Sendable, Hashable {
    /// Busy percentage across all cores, 0–100, measured over a short window.
    public let cpuPercent: Double
    public let memoryUsedBytes: Int64
    public let memoryTotalBytes: Int64
    public let sampledAt: Date

    public init(cpuPercent: Double, memoryUsedBytes: Int64, memoryTotalBytes: Int64,
                sampledAt: Date = Date()) {
        self.cpuPercent = cpuPercent
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryTotalBytes = memoryTotalBytes
        self.sampledAt = sampledAt
    }

    /// e.g. `CPU 12% · RAM 1.2/16 GB`. Rounded hard: this is a glanceable line in a menu,
    /// not a monitoring tool, and spurious precision would only make it harder to read.
    public var summary: String {
        let used = Double(memoryUsedBytes) / 1_073_741_824
        let total = Double(memoryTotalBytes) / 1_073_741_824
        let usedText = used < 10 ? String(format: "%.1f", used) : String(Int(used.rounded()))
        let totalText = total < 10 ? String(format: "%.1f", total) : String(Int(total.rounded()))
        return "CPU \(Int(cpuPercent.rounded()))% · RAM \(usedText)/\(totalText) GB"
    }
}

public struct MachineSpec: Codable, Hashable, Sendable {
    /// Not under `/root`: that directory is mode 700, so the unprivileged account Claude
    /// Code runs as could not even traverse into it. `/srv/workspace` is reachable by both
    /// agents, and owned by the Claude account with setgid so either can write there.
    public static let defaultWorkspacePath = "/srv/workspace"

    public var name: String
    public var accountID: UUID
    public var providerKind: ProviderKind
    public var region: String
    public var size: String
    public var image: String
    /// Remote directory new Codex tasks start in.
    public var workspacePath: String
    /// Which coding agents to install. A machine can run either or both.
    public var agents: Set<AgentKind>
    /// Copy this Mac's agent credentials to the machine so the agents there can sign in.
    public var syncCodexCredentials: Bool
    /// Carry this Mac's MCP servers, plugins and their OAuth tokens onto the machine.
    /// Only servers that can actually run there are copied.
    public var syncMCPServers: Bool
    /// Extra apt packages the user wants on every machine (toolchains, etc.).
    public var extraPackages: [String]
    /// Shell run at the end of bootstrap — repo clones, language runtimes, dotfiles.
    public var postSetupScript: String?
    /// Shut the machine down after this many idle minutes. 0 disables.
    public var idleShutdownMinutes: Int
    /// Adopted hosts already trust one of the user's own keys; when set, Codex Remote uses it
    /// instead of generating and installing its own.
    public var privateKeyPathOverride: String?
    /// SSH port on the machine. Providers all hand back port 22; an adopted host may not.
    public var sshPort: Int

    public init(name: String, accountID: UUID, providerKind: ProviderKind, region: String,
                size: String, image: String, workspacePath: String = MachineSpec.defaultWorkspacePath,
                agents: Set<AgentKind> = [.codex, .claudeCode],
                syncCodexCredentials: Bool = true, syncMCPServers: Bool = true,
                extraPackages: [String] = [],
                postSetupScript: String? = nil, idleShutdownMinutes: Int = 0,
                privateKeyPathOverride: String? = nil, sshPort: Int = 22) {
        self.name = name
        self.accountID = accountID
        self.providerKind = providerKind
        self.region = region
        self.size = size
        self.image = image
        self.workspacePath = workspacePath
        self.agents = agents
        self.syncCodexCredentials = syncCodexCredentials
        self.syncMCPServers = syncMCPServers
        self.extraPackages = extraPackages
        self.postSetupScript = postSetupScript
        self.idleShutdownMinutes = idleShutdownMinutes
        self.privateKeyPathOverride = privateKeyPathOverride
        self.sshPort = sshPort
    }

    /// Decoded field by field with defaults for anything absent.
    ///
    /// Swift's synthesized `Codable` treats a missing key as an error even when the
    /// property has a default, so adding a field would make every machine saved by an
    /// older build fail to decode — and the registry would come back empty, losing the
    /// user's machines. Every new field has to be optional on the way in.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        accountID = try container.decode(UUID.self, forKey: .accountID)
        providerKind = try container.decode(ProviderKind.self, forKey: .providerKind)
        region = try container.decode(String.self, forKey: .region)
        size = try container.decode(String.self, forKey: .size)
        image = try container.decode(String.self, forKey: .image)
        // Machines created before the Claude account existed keep the workspace they were
        // built with; only new ones get the shared location.
        workspacePath = try container.decodeIfPresent(String.self, forKey: .workspacePath)
            ?? "/root/workspace"
        // Machines created before Codex Remote knew about Claude Code ran Codex.
        agents = try container.decodeIfPresent(Set<AgentKind>.self, forKey: .agents) ?? [.codex]
        syncCodexCredentials = try container.decodeIfPresent(Bool.self, forKey: .syncCodexCredentials) ?? true
        syncMCPServers = try container.decodeIfPresent(Bool.self, forKey: .syncMCPServers) ?? true
        extraPackages = try container.decodeIfPresent([String].self, forKey: .extraPackages) ?? []
        postSetupScript = try container.decodeIfPresent(String.self, forKey: .postSetupScript)
        idleShutdownMinutes = try container.decodeIfPresent(Int.self, forKey: .idleShutdownMinutes) ?? 0
        privateKeyPathOverride = try container.decodeIfPresent(String.self, forKey: .privateKeyPathOverride)
        sshPort = try container.decodeIfPresent(Int.self, forKey: .sshPort) ?? 22
    }
}

/// Everything Codex Remote knows about one managed machine. Persisted to
/// `~/.codex-remote/machines.json`; the app-server bearer token is in the keychain.
public struct Machine: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var spec: MachineSpec
    /// Provider-side id, absent until the instance has been created.
    public var instanceID: String?

    /// True when Codex Remote created the server, and so is the one that should delete it.
    ///
    /// This is the difference between the two kinds of machine here. One Codex Remote built
    /// from nothing and bills to the user's cloud account for as long as it exists; the
    /// other the user already had, and Codex Remote is only a guest on. Removing the first
    /// without deleting it leaves a server running that no longer appears anywhere in the
    /// app — which is how a test machine quietly bills for a month. Deleting the second
    /// would destroy something that was never ours.
    ///
    /// Deliberately not keyed on `instanceID`: a provision that failed before the cloud
    /// returned one can still have left a key pair and a security group behind, recorded in
    /// OpenTofu's state, and those are ours to clean up too.
    public var ownsServer: Bool { spec.providerKind != .existingHost }
    public var instance: Instance?
    public var stage: ProvisionStage
    public var health: ConnectionHealth
    public var powerIntent: PowerIntent
    /// Port on 127.0.0.1 that the SSH tunnel forwards to the machine's app-server.
    public var localPort: Int
    /// Port the app-server listens on inside the machine.
    public var remotePort: Int
    public var sshHostAlias: String
    public var sshUser: String
    public var sshPort: Int
    public var privateKeyPath: String
    /// What each installed agent is doing, as last observed.
    public var agentStatuses: [AgentStatus]
    public var metrics: SystemMetrics?
    /// How many agent sessions are live on the machine right now. nil means "not sampled
    /// yet" and is deliberately different from 0, which means "nothing is running, so this
    /// is safe to stop".
    public var activeSessions: Int?
    public var lastError: String?
    public var lastHealthyAt: Date?
    public var createdAt: Date
    public var codexVersion: String?

    public init(id: UUID = UUID(), spec: MachineSpec, instanceID: String? = nil,
                instance: Instance? = nil, stage: ProvisionStage = .queued,
                health: ConnectionHealth = .unknown, powerIntent: PowerIntent = .up,
                localPort: Int, remotePort: Int = 1456, sshHostAlias: String,
                sshUser: String = "root", sshPort: Int = 22, privateKeyPath: String,
                agentStatuses: [AgentStatus] = [], metrics: SystemMetrics? = nil,
                activeSessions: Int? = nil,
                lastError: String? = nil, lastHealthyAt: Date? = nil,
                createdAt: Date = Date(), codexVersion: String? = nil) {
        self.id = id
        self.spec = spec
        self.instanceID = instanceID
        self.instance = instance
        self.stage = stage
        self.health = health
        self.powerIntent = powerIntent
        self.localPort = localPort
        self.remotePort = remotePort
        self.sshHostAlias = sshHostAlias
        self.sshUser = sshUser
        self.sshPort = sshPort
        self.privateKeyPath = privateKeyPath
        self.agentStatuses = agentStatuses
        self.metrics = metrics
        self.activeSessions = activeSessions
        self.lastError = lastError
        self.lastHealthyAt = lastHealthyAt
        self.createdAt = createdAt
        self.codexVersion = codexVersion
    }

    /// See `MachineSpec.init(from:)` — new fields must not invalidate a saved registry.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        spec = try container.decode(MachineSpec.self, forKey: .spec)
        instanceID = try container.decodeIfPresent(String.self, forKey: .instanceID)
        instance = try container.decodeIfPresent(Instance.self, forKey: .instance)
        stage = try container.decodeIfPresent(ProvisionStage.self, forKey: .stage) ?? .queued
        health = try container.decodeIfPresent(ConnectionHealth.self, forKey: .health) ?? .unknown
        powerIntent = try container.decodeIfPresent(PowerIntent.self, forKey: .powerIntent) ?? .up
        localPort = try container.decodeIfPresent(Int.self, forKey: .localPort) ?? 14560
        remotePort = try container.decodeIfPresent(Int.self, forKey: .remotePort) ?? 1456
        sshHostAlias = try container.decode(String.self, forKey: .sshHostAlias)
        sshUser = try container.decodeIfPresent(String.self, forKey: .sshUser) ?? "root"
        sshPort = try container.decodeIfPresent(Int.self, forKey: .sshPort) ?? 22
        privateKeyPath = try container.decode(String.self, forKey: .privateKeyPath)
        agentStatuses = try container.decodeIfPresent([AgentStatus].self, forKey: .agentStatuses) ?? []
        metrics = try container.decodeIfPresent(SystemMetrics.self, forKey: .metrics)
        activeSessions = try container.decodeIfPresent(Int.self, forKey: .activeSessions)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        lastHealthyAt = try container.decodeIfPresent(Date.self, forKey: .lastHealthyAt)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        codexVersion = try container.decodeIfPresent(String.self, forKey: .codexVersion)
    }

    public var name: String { spec.name }
    public var endpoint: String { "ws://127.0.0.1:\(localPort)" }
    public var healthURL: URL { URL(string: "http://127.0.0.1:\(localPort)/healthz")! }
    public var tokenKeychainAccount: String { "machine.\(id.uuidString).appserver-token" }
    /// Env var name the Codex CLI is told to read the bearer token from.
    public var tokenEnvVar: String { "CODEX_REMOTE_TOKEN_\(sshHostAlias.replacingOccurrences(of: "-", with: "_").uppercased())" }
    /// The alias already carries the product prefix, so building the launcher name from
    /// it produced `codex-codex-remote-<name>`. Use the bare slug.
    public var launcherSlug: String {
        let prefix = "codex-remote-"
        return sshHostAlias.hasPrefix(prefix) ? String(sshHostAlias.dropFirst(prefix.count)) : sshHostAlias
    }

    public var launcherPath: String {
        Paths.binDir.appendingPathComponent("codex-attach-\(launcherSlug)").path
    }

    public var isReady: Bool {
        guard stage == .ready else { return false }
        // A machine that only runs Claude has no tunnel to be healthy on; it is ready when
        // its Remote Control session is up.
        if runs(.codex) { return health == .online }
        return status(of: .claudeCode)?.isRunning ?? false
    }

    public func runs(_ agent: AgentKind) -> Bool { spec.agents.contains(agent) }

    public func status(of agent: AgentKind) -> AgentStatus? {
        agentStatuses.first { $0.kind == agent }
    }

    /// Codex needs a loopback port forwarded to it; a Claude-only machine does not.
    public var needsTunnel: Bool { runs(.codex) }

    /// The claude.ai session this machine's Remote Control is attached to, if any.
    public var claudeSessionURL: String? { status(of: .claudeCode)?.endpoint }

    /// One-line status for the menu bar row, covering whichever agents are installed.
    public var statusText: String {
        if stage == .failed { return lastError.map { "Failed — \($0)" } ?? "Failed" }
        if stage != .ready { return stage.label }

        var parts: [String] = []
        // What the box is doing beats a local port number you already know: the endpoint
        // is the same loopback address every time, and says nothing about the machine.
        if health == .online, let activeSessions {
            parts.append(activeSessions == 0 ? "idle"
                         : "\(activeSessions) session\(activeSessions == 1 ? "" : "s")")
        }
        if health == .online, let metrics { parts.append(metrics.summary) }

        if runs(.codex) {
            switch health {
            case .online: break
            case .degraded: parts.append("Codex not answering")
            case .offline: parts.append(powerIntent == .down ? "Paused" : "Codex offline")
            case .unknown: parts.append("Codex checking…")
            }
        }
        if runs(.claudeCode) {
            let claude = status(of: .claudeCode)
            if claude?.isRunning == true {
                parts.append("Claude in your account")
            } else if claude?.needsSignIn == true {
                parts.append("Claude needs signing in")
            } else if powerIntent == .down {
                if !runs(.codex) { parts.append("Paused") }
            } else {
                parts.append("Claude not running")
            }
        }
        return parts.isEmpty ? "Ready" : parts.joined(separator: " · ")
    }
}

public struct MachineRegistry: Codable, Sendable {
    public var version: Int
    public var machines: [Machine]

    public init(version: Int = 1, machines: [Machine] = []) {
        self.version = version
        self.machines = machines
    }

    /// One unreadable machine must not take the whole registry with it. Each entry is
    /// decoded on its own, and a broken one is dropped with a warning rather than throwing
    /// — otherwise a single malformed record empties the list.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1

        var list = try container.nestedUnkeyedContainer(forKey: .machines)
        var decoded: [Machine] = []
        var failures = 0
        while !list.isAtEnd {
            do {
                decoded.append(try list.decode(Machine.self))
            } catch {
                failures += 1
                // Consume the element so the loop can continue past it.
                _ = try? list.decode(AnyCodableSkip.self)
            }
        }
        if failures > 0 {
            Log.shared.warn("store", "Skipped \(failures) unreadable machine record(s); the rest were kept.")
        }
        machines = decoded
    }
}

/// Swallows one element of unknown shape so a decoding loop can step over it.
private struct AnyCodableSkip: Decodable {
    init(from decoder: Decoder) throws { _ = try? decoder.singleValueContainer() }
}

public struct AccountRegistry: Codable, Sendable {
    public var version: Int
    public var accounts: [ProviderAccount]

    public init(version: Int = 1, accounts: [ProviderAccount] = []) {
        self.version = version
        self.accounts = accounts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        accounts = try container.decodeIfPresent([ProviderAccount].self, forKey: .accounts) ?? []
    }
}

public struct AppSettings: Codable, Sendable {
    /// See `MachineSpec.init(from:)`. Settings are persisted too, and a synthesized decoder
    /// would throw on any field added later — losing every preference the user had set.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        basePort = try container.decodeIfPresent(Int.self, forKey: .basePort) ?? defaults.basePort
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? defaults.launchAtLogin
        codexVersionPin = try container.decodeIfPresent(String.self, forKey: .codexVersionPin)
        defaultWorkspacePath = try container.decodeIfPresent(String.self, forKey: .defaultWorkspacePath)
            ?? defaults.defaultWorkspacePath
        autoReconnectTunnels = try container.decodeIfPresent(Bool.self, forKey: .autoReconnectTunnels)
            ?? defaults.autoReconnectTunnels
        healthPollSeconds = try container.decodeIfPresent(Int.self, forKey: .healthPollSeconds)
            ?? defaults.healthPollSeconds
        registerWithCodexApp = try container.decodeIfPresent(Bool.self, forKey: .registerWithCodexApp)
            ?? defaults.registerWithCodexApp
        autoRestartCodexApp = try container.decodeIfPresent(Bool.self, forKey: .autoRestartCodexApp)
            ?? defaults.autoRestartCodexApp
        providerRegistryURL = try container.decodeIfPresent(String.self, forKey: .providerRegistryURL)
            ?? defaults.providerRegistryURL
        mcpAllowWrites = try container.decodeIfPresent(Bool.self, forKey: .mcpAllowWrites)
            ?? defaults.mcpAllowWrites
        mcpAllowDestroy = try container.decodeIfPresent(Bool.self, forKey: .mcpAllowDestroy)
            ?? defaults.mcpAllowDestroy
    }

    public var basePort: Int
    public var launchAtLogin: Bool
    public var codexVersionPin: String?
    public var defaultWorkspacePath: String
    public var autoReconnectTunnels: Bool
    public var healthPollSeconds: Int
    /// Add every ready machine to the Codex desktop app's Remotes list.
    /// Where the catalogue of clouds comes from. Clouds are data — OpenTofu HCL plus the
    /// environment their credentials map onto — so they are fetched rather than compiled
    /// in, and pointing this at your own registry gives you your own catalogue. Format:
    /// `docs/registry.md`.
    public var providerRegistryURL: String
    /// Let an agent create, change and run commands on machines through the MCP server.
    /// Off by default: these tools spend money, and an agent will call them in a loop.
    public var mcpAllowWrites: Bool
    /// Let an agent destroy a machine. Deliberately separate from `mcpAllowWrites` —
    /// creating the wrong machine costs pence, deleting the right one loses work.
    public var mcpAllowDestroy: Bool
    /// Add every ready machine to the Codex desktop app's Remotes list.
    public var registerWithCodexApp: Bool
    /// Quit and relaunch the Codex app automatically when its remote list changes.
    /// Off by default: it closes an app the user may be working in.
    public var autoRestartCodexApp: Bool

    public init(basePort: Int = 14560, launchAtLogin: Bool = false,
                codexVersionPin: String? = nil,
                defaultWorkspacePath: String = MachineSpec.defaultWorkspacePath,
                autoReconnectTunnels: Bool = true,
                healthPollSeconds: Int = 15,
                registerWithCodexApp: Bool = true,
                autoRestartCodexApp: Bool = false,
                providerRegistryURL: String = RemoteProviderRegistry.officialURL.absoluteString,
                mcpAllowWrites: Bool = false, mcpAllowDestroy: Bool = false) {
        self.basePort = basePort
        self.launchAtLogin = launchAtLogin
        self.codexVersionPin = codexVersionPin
        self.defaultWorkspacePath = defaultWorkspacePath
        self.autoReconnectTunnels = autoReconnectTunnels
        self.healthPollSeconds = healthPollSeconds
        self.registerWithCodexApp = registerWithCodexApp
        self.autoRestartCodexApp = autoRestartCodexApp
        self.providerRegistryURL = providerRegistryURL
        self.mcpAllowWrites = mcpAllowWrites
        self.mcpAllowDestroy = mcpAllowDestroy
    }
}
