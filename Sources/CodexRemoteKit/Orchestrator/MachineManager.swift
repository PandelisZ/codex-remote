import Foundation

/// The one object that owns Codex Remote's state: provider accounts, machines, tunnels and
/// health. The menu bar and `codex-remote` are both thin shells over this, so anything the
/// UI can do is scriptable and anything scriptable shows up in the UI.
public final class MachineManager: @unchecked Sendable {
    public enum Event: Sendable {
        case machinesChanged
        case accountsChanged
        case settingsChanged
        case progress(ProvisionPipeline.Progress)
        case failed(machineID: UUID, message: String)
        case codexAppChanged(CodexAppRegistrar.SyncResult)
    }

    private let lock = Lock()
    private let machineStore: JSONStore<MachineRegistry>
    private let accountStore: JSONStore<AccountRegistry>
    private let settingsStore: JSONStore<AppSettings>
    private let credentials: CredentialStore
    private let registry: ProviderRegistry
    private let health = HealthMonitor()

    private var machineList: [Machine]
    private var accountList: [ProviderAccount]
    private var currentSettings: AppSettings
    private var observers: [UUID: @Sendable (Event) -> Void] = [:]
    private var activeProvisions: Set<UUID> = []
    /// Set when the Codex app has to be restarted before it shows the current remotes.
    /// True when this process owns the tunnels, health polling and Codex app list.
    public private(set) var ownsRuntime = false
    private var lastCodexAppSync = Date.distantPast

    public init(credentials: CredentialStore = KeychainCredentialStore(),
                registry: ProviderRegistry = .shared) {
        self.credentials = credentials
        self.registry = registry
        machineStore = JSONStore(url: Paths.machinesFile) { MachineRegistry() }
        accountStore = JSONStore(url: Paths.accountsFile) { AccountRegistry() }
        settingsStore = JSONStore(url: Paths.settingsFile) { AppSettings() }
        machineList = machineStore.load().machines
        accountList = accountStore.load().accounts
        currentSettings = settingsStore.load()
        Log.shared.attachFile()
    }

    // MARK: - Observation

    @discardableResult
    public func observe(_ handler: @escaping @Sendable (Event) -> Void) -> UUID {
        lock.lock(); defer { lock.unlock() }
        let token = UUID()
        observers[token] = handler
        return token
    }

    public func removeObserver(_ token: UUID) {
        lock.lock(); defer { lock.unlock() }
        observers[token] = nil
    }

    private func emit(_ event: Event) {
        lock.lock(); let snapshot = Array(observers.values); lock.unlock()
        for observer in snapshot { observer(event) }
    }

    // MARK: - Accessors

    public var machines: [Machine] {
        lock.lock(); defer { lock.unlock() }
        return machineList.sorted { $0.createdAt < $1.createdAt }
    }

    public var accounts: [ProviderAccount] {
        lock.lock(); defer { lock.unlock() }
        return accountList
    }

    public var settings: AppSettings {
        lock.lock(); defer { lock.unlock() }
        return currentSettings
    }

    public func machine(id: UUID) -> Machine? {
        lock.lock(); defer { lock.unlock() }
        return machineList.first { $0.id == id }
    }

    public func account(id: UUID) -> ProviderAccount? {
        lock.lock(); defer { lock.unlock() }
        return accountList.first { $0.id == id }
    }

    public func isProvisioning(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return activeProvisions.contains(id)
    }

    // MARK: - Lifecycle

    /// Call once at launch: restores tunnels for machines that should be up and starts
    /// health polling.
    /// Call once at launch. `name` shows up in the error another process gets when it
    /// tries to take over. Returns false when someone else already owns the runtime, in
    /// which case this process stays read-only.
    @discardableResult
    public func start(as name: String = "codex-remote") -> Bool {
        // A GUI launch inherits almost no environment, so pick up any provider tokens the
        // user exports from their shell before anything asks for credentials.
        Task { await LoginShellEnvironment.shared.load(allowed: LoginShellEnvironment.declaredVariables(registry)) }

        ownsRuntime = RuntimeLock.shared.acquire(name: name)
        guard ownsRuntime else {
            let holder = RuntimeLock.shared.currentHolder()
            Log.shared.info("lock", "\(holder?.name ?? "another process") already owns the runtime; staying read-only.")
            return false
        }
        Task { [weak self] in
            guard let self else { return }
            for machine in machines where machine.stage == .ready && machine.powerIntent == .up {
                TunnelManager.shared.start(machine)
            }
            TunnelManager.shared.setStatusObserver { [weak self] _ in
                self?.emit(.machinesChanged)
            }
            await health.setInterval(TimeInterval(settings.healthPollSeconds))
            await health.start(machines: { [weak self] in self?.machines ?? [] },
                               onProbe: { [weak self] probe in self?.apply(probe) })
            reconcileCodexApp()
            try? CodexRegistrar.writeDispatcher(machines: machines)
            try? CodexRegistrar.writeShellIntegration(machines: machines)
            // Keep ~/.ssh/config.d/codex-remote correct for every machine on every launch. It
            // used to be written only as part of Codex registration, so a Claude-only
            // machine never got a host entry and `ssh codex-remote-<name>` did not resolve.
            _ = try? SSHConfigManager.sync(machines: machines)
        }
        return true
    }

    /// The process that currently owns tunnels and health, if it is not this one.
    public var runtimeOwner: RuntimeLock.Holder? {
        ownsRuntime ? nil : RuntimeLock.shared.currentHolder()
    }

    public func shutdown() {
        Task { await health.stop() }
        TunnelManager.shared.stopAll()
        RuntimeLock.shared.release()
    }

    /// True when the Codex app's file no longer lists every ready machine — which happens
    /// whenever the running app rewrites the file from its own in-memory copy.
    private func codexAppNeedsResync() -> Bool {
        guard settings.registerWithCodexApp, CodexAppRegistrar.isCodexAppInstalled,
              CodexAppRegistrar.stateFileExists else { return false }
        let expected = Set(machines.filter { $0.stage == .ready }.map(\.name))
        return expected != Set(CodexAppRegistrar.registeredMachineNames())
    }

    /// Re-applies Codex Remote's entries if the Codex app dropped them. Cheap — it only writes
    /// when something is actually missing.
    public func reconcileCodexApp() {
        guard ownsRuntime, codexAppNeedsResync() else { return }
        // The Codex app rewrites this file from its own in-memory copy whenever it saves,
        // which wipes Codex Remote's entries. Restoring them on every health tick would be
        // a write fight, so back off — `sync` declines outright while the app is running,
        // and the machine is discovered from ~/.ssh/config regardless.
        guard Date().timeIntervalSince(lastCodexAppSync) > 300 else { return }
        lastCodexAppSync = Date()
        do {
            if let result = try syncCodexApp(), result.changedAnything {
                emit(.codexAppChanged(result))
            }
        } catch {
            Log.shared.warn("codex-app", error.localizedDescription)
        }
    }

    private func apply(_ probe: HealthMonitor.Probe) {
        var changed = false
        lock.lock()
        if let index = machineList.firstIndex(where: { $0.id == probe.machineID }) {
            if machineList[index].health != probe.health {
                machineList[index].health = probe.health
                changed = true
            }
            if probe.health == .online { machineList[index].lastHealthyAt = Date() }
            // nil means the sample was skipped this pass, so the last reading stands.
            if let metrics = probe.metrics, machineList[index].metrics != metrics {
                machineList[index].metrics = metrics
                changed = true
            }
            if probe.metrics != nil, machineList[index].activeSessions != probe.activeSessions {
                machineList[index].activeSessions = probe.activeSessions
                changed = true
            }
            for status in probe.agentStatuses {
                let existing = machineList[index].agentStatuses.first { $0.kind == status.kind }
                if existing != status {
                    machineList[index].agentStatuses = machineList[index].agentStatuses
                        .filter { $0.kind != status.kind } + [status]
                    changed = true
                }
            }
        }
        let snapshot = machineList
        lock.unlock()
        if changed {
            try? machineStore.save(MachineRegistry(machines: snapshot))
            emit(.machinesChanged)
        }
        reconcileCodexApp()
    }

    // MARK: - Accounts

    /// Saves an account and its secrets, then proves the credentials work before keeping
    /// them — a bad token should fail in the settings sheet, not halfway through a provision.
    @discardableResult
    public func addAccount(kind: ProviderKind, label: String,
                           secrets: [String: Secret],
                           plainFields: [String: String] = [:]) async throws -> ProviderAccount {
        guard let descriptor = registry.descriptor(for: kind) else {
            throw ProviderError.unsupported("provider \(kind)", provider: kind.rawValue)
        }
        await ensureShellEnvironmentLoaded()
        var account = ProviderAccount(kind: kind, label: label, plainFields: plainFields)
        for (key, value) in secrets where !value.isEmpty {
            try credentials.write(value, for: account.keychainAccount(for: key))
        }
        do {
            let provider = try registry.provider(for: account, credentials: credentials)
            account.verifiedIdentity = try await provider.verify()
        } catch {
            for key in secrets.keys {
                try? credentials.remove(account.keychainAccount(for: key))
            }
            throw error
        }
        _ = descriptor

        lock.lock()
        accountList.append(account)
        let snapshot = accountList
        lock.unlock()
        try accountStore.save(AccountRegistry(accounts: snapshot))
        emit(.accountsChanged)
        Log.shared.info("accounts", "Added \(kind) account \"\(label)\" (\(account.verifiedIdentity?.accountLabel ?? "verified")).")
        return account
    }

    public func removeAccount(id: UUID) throws {
        lock.lock()
        guard let index = accountList.firstIndex(where: { $0.id == id }) else { lock.unlock(); return }
        let account = accountList.remove(at: index)
        let inUse = machineList.contains { $0.spec.accountID == id }
        let snapshot = accountList
        lock.unlock()

        if inUse {
            lock.lock(); accountList.insert(account, at: index); lock.unlock()
            throw ProviderError.unsupported(
                "removing an account that still has machines — delete its machines first",
                provider: account.kind.rawValue)
        }
        if let descriptor = registry.descriptor(for: account.kind) {
            for field in descriptor.credentialFields {
                try? credentials.remove(account.keychainAccount(for: field.key))
            }
        }
        try accountStore.save(AccountRegistry(accounts: snapshot))
        emit(.accountsChanged)
    }

    public func provider(for account: ProviderAccount) throws -> ComputeProvider {
        try registry.provider(for: account, credentials: credentials)
    }

    /// Makes sure any token the user exports from their shell has been picked up before
    /// credentials are resolved. Without this a GUI launch falls through to the keychain,
    /// which can sit on an access dialog nobody is looking at.
    private func ensureShellEnvironmentLoaded() async {
        await LoginShellEnvironment.shared.load(
            allowed: LoginShellEnvironment.declaredVariables(registry))
    }

    public func capabilities(for accountID: UUID) async throws -> ProviderCapabilities {
        guard let account = account(id: accountID) else {
            throw ProviderError.unsupported("unknown account", provider: "codex-remote")
        }
        await ensureShellEnvironmentLoaded()
        return try await provider(for: account).capabilities()
    }

    // MARK: - Settings

    public func updateSettings(_ transform: (inout AppSettings) -> Void) {
        lock.lock()
        transform(&currentSettings)
        let snapshot = currentSettings
        lock.unlock()
        try? settingsStore.save(snapshot)
        Task { await health.setInterval(TimeInterval(snapshot.healthPollSeconds)) }
        emit(.settingsChanged)
    }

    // MARK: - Machines

    /// Creates the registry entry and kicks off provisioning. Returns as soon as the
    /// machine is queued so the UI can show it immediately.
    @discardableResult
    public func createMachine(spec inputSpec: MachineSpec) throws -> Machine {
        var spec = inputSpec
        spec.name = uniqueName(from: spec.name)

        guard let account = account(id: spec.accountID) else {
            throw ProviderError.unsupported("unknown account", provider: "codex-remote")
        }
        // An "existing machine" account carries the key that already works on that host.
        if spec.privateKeyPathOverride == nil,
           let keyPath = account.plainFields["privateKeyPath"], !keyPath.isEmpty {
            spec.privateKeyPathOverride = keyPath
        }
        if spec.sshPort == 22, let port = account.plainFields["port"].flatMap(Int.init) {
            spec.sshPort = port
        }

        let taken = Set(machines.map(\.localPort))
        let port = PortAllocator.allocate(basePort: settings.basePort, taken: taken)
        let machine = Machine(
            spec: spec,
            localPort: port,
            sshHostAlias: SSHConfigManager.hostAlias(for: spec.name),
            sshPort: spec.sshPort,
            privateKeyPath: SSHKeyManager.defaultPrivateKeyURL.path
        )

        lock.lock()
        machineList.append(machine)
        let snapshot = machineList
        lock.unlock()
        try machineStore.save(MachineRegistry(machines: snapshot))
        emit(.machinesChanged)

        provision(machine.id, repairOnly: false)
        return machine
    }

    /// Re-runs the remote setup against an existing instance.
    public func repair(_ id: UUID) {
        provision(id, repairOnly: true)
    }

    private func provision(_ id: UUID, repairOnly: Bool) {
        lock.lock()
        guard !activeProvisions.contains(id), let machine = machineList.first(where: { $0.id == id }) else {
            lock.unlock(); return
        }
        activeProvisions.insert(id)
        lock.unlock()
        emit(.machinesChanged)

        Task { [weak self] in
            guard let self else { return }
            defer {
                lock.lock(); activeProvisions.remove(id); lock.unlock()
                emit(.machinesChanged)
            }
            await ensureShellEnvironmentLoaded()
            guard let account = account(id: machine.spec.accountID) else {
                update(id) { $0.stage = .failed; $0.lastError = "Its provider account is gone." }
                return
            }
            let provider: ComputeProvider
            do {
                provider = try self.provider(for: account)
            } catch {
                update(id) { $0.stage = .failed; $0.lastError = error.localizedDescription }
                emit(.failed(machineID: id, message: error.localizedDescription))
                return
            }

            let pipeline = ProvisionPipeline(
                provider: provider,
                credentials: credentials,
                settings: settings,
                onProgress: { [weak self] progress in self?.emit(.progress(progress)) },
                onMachineUpdate: { [weak self] updated in self?.merge(updated) },
                allMachines: { [weak self] in
                    (self?.machines ?? []).filter { $0.id != id }
                }
            )
            let result = repairOnly
                ? await pipeline.repair(machine: machine, allMachines: { [weak self] in self?.machines ?? [] })
                : await pipeline.run(machine: machine, allMachines: { [weak self] in self?.machines ?? [] })
            merge(result)
            if result.stage == .failed {
                emit(.failed(machineID: id, message: result.lastError ?? "Provisioning failed."))
            }
        }
    }

    /// Powers the instance on or off at the provider and brings the tunnel with it.
    public func setPower(_ id: UUID, intent: PowerIntent) {
        guard let machine = machine(id: id), let instanceID = machine.instanceID,
              let account = account(id: machine.spec.accountID) else { return }
        update(id) { $0.powerIntent = intent }

        Task { [weak self] in
            guard let self else { return }
            await ensureShellEnvironmentLoaded()
            do {
                let provider = try self.provider(for: account)
                switch intent {
                case .down:
                    TunnelManager.shared.stop(id)
                    update(id) { $0.health = .offline }
                    try await provider.power(.stop, instanceID: instanceID)
                    Log.shared.info("power", "\(machine.name): shutdown requested.")
                case .up:
                    try await provider.power(.start, instanceID: instanceID)
                    Log.shared.info("power", "\(machine.name): power on requested; waiting for the IP.")
                    // The address can change across a stop/start on some providers, so
                    // re-read it before reconnecting the tunnel.
                    let running = try await provider.waitForRunningInstance(id: instanceID, timeout: 300)
                    update(id) { $0.instance = running }
                    if let refreshed = self.machine(id: id) {
                        _ = try? SSHConfigManager.sync(machines: self.machines)
                        TunnelManager.shared.start(refreshed)
                    }
                }
            } catch {
                Log.shared.error("power", "\(machine.name): \(error.localizedDescription)")
                update(id) { $0.lastError = error.localizedDescription }
            }
        }
    }

    public func reconnect(_ id: UUID) {
        guard let machine = machine(id: id) else { return }
        TunnelManager.shared.stop(id)
        TunnelManager.shared.start(machine)
        Task { [weak self] in
            guard let self else { return }
            let probe = await health.probe(machine)
            apply(probe)
        }
    }

    /// Removes the machine from Codex Remote. `destroyInstance` also deletes the server at the
    /// provider — the caller is responsible for confirming that with the user first.
    public func removeMachine(_ id: UUID, destroyInstance: Bool) async throws {
        guard let machine = machine(id: id) else { return }
        TunnelManager.shared.stop(id)

        if destroyInstance, let instanceID = machine.instanceID,
           let account = account(id: machine.spec.accountID) {
            let provider = try self.provider(for: account)
            try await provider.destroyInstance(id: instanceID)
            Log.shared.info("machines", "Destroyed \(account.kind) instance \(instanceID) for \(machine.name).")
        } else if let address = machine.instance?.sshAddress {
            // Keeping the server: take the Codex Remote service back off it so it is left clean.
            let ssh = SSHClient(host: address, user: machine.sshUser,
                                privateKeyPath: machine.privateKeyPath, port: machine.sshPort)
            _ = try? await ssh.runScript(BootstrapScript.uninstall(), timeout: 120)
        }

        try? credentials.remove(machine.tokenKeychainAccount)
        if let address = machine.instance?.sshAddress {
            await SSHConfigManager.forgetHostKey(address: address, port: machine.sshPort)
        }

        lock.lock()
        machineList.removeAll { $0.id == id }
        let snapshot = machineList
        lock.unlock()
        try machineStore.save(MachineRegistry(machines: snapshot))
        try? CodexRegistrar.unregister(machine, remaining: snapshot)
        _ = try? syncCodexApp()
        emit(.machinesChanged)
    }

    // MARK: - Claude Code sign-in

    /// Starts the browser sign-in on a machine and returns the URL to approve.
    // MARK: - Codex remote control

    /// Turns on Codex's dial-out remote control and returns a fresh pairing code.
    ///
    /// The code is minted here rather than at provision time because it is short-lived —
    /// one generated during setup would be stale long before anyone looked at it.
    public func beginCodexPairing(_ id: UUID) async throws -> CodexRemoteControl.PairingCode {
        guard let machine = machine(id: id) else {
            throw ProviderError.unsupported("pairing on an unknown machine", provider: "codex-remote")
        }
        let ssh = try sshClient(for: id, doing: "pairing")
        // Only the service user and paths matter for the unit; the provisioning plan's
        // package list and version pins have nothing to do with remote control.
        let plan = BootstrapPlan(workspacePath: machine.spec.workspacePath,
                                 remotePort: machine.remotePort,
                                 serviceUser: machine.sshUser,
                                 hostname: machine.name)
        _ = try await CodexRemoteControl.enable(on: ssh, plan: plan)
        return try await CodexRemoteControl.pair(on: ssh)
    }

    /// A new code for the same machine, for when the one on screen has run out.
    public func refreshCodexPairing(_ id: UUID) async throws -> CodexRemoteControl.PairingCode {
        try await CodexRemoteControl.pair(on: sshClient(for: id, doing: "pairing"))
    }

    public func disableCodexRemoteControl(_ id: UUID) async throws {
        try await CodexRemoteControl.disable(on: sshClient(for: id, doing: "remote control"))
    }

    private func sshClient(for id: UUID, doing what: String) throws -> SSHClient {
        guard let machine = machine(id: id), let address = machine.instance?.sshAddress else {
            throw ProviderError.unsupported("\(what) on a machine with no address", provider: "codex-remote")
        }
        return SSHClient(host: address, user: machine.sshUser,
                         privateKeyPath: machine.privateKeyPath, port: machine.sshPort)
    }

    public func beginClaudeSignIn(_ id: UUID) async throws -> ClaudeLogin.Pending {
        guard let machine = machine(id: id), let address = machine.instance?.sshAddress else {
            throw ProviderError.unsupported("signing in to a machine with no address", provider: "codex-remote")
        }
        return try await ClaudeLogin.begin(on: SSHClient(host: address, user: machine.sshUser,
                                                         privateKeyPath: machine.privateKeyPath,
                                                         port: machine.sshPort))
    }

    /// Sends the code back, then brings Remote Control up.
    public func completeClaudeSignIn(_ id: UUID, code: String) async throws {
        guard let machine = machine(id: id), let address = machine.instance?.sshAddress else {
            throw ProviderError.unsupported("signing in to a machine with no address", provider: "codex-remote")
        }
        let ssh = SSHClient(host: address, user: machine.sshUser,
                            privateKeyPath: machine.privateKeyPath, port: machine.sshPort)
        try await ClaudeLogin.submit(code: code, on: ssh)
        Log.shared.info("claude", "\(machine.name) signed in to Claude Code.")

        // The machine now owns a login, so this Mac's connected MCP servers can join it
        // without disturbing that login.
        if machine.spec.syncMCPServers,
           let credentials = try? await ClaudeCredentials.portableCredentials(includeMCPTokens: true),
           credentials.mcpTokenCount > 0 {
            try? await ClaudeLogin.mergeMCPTokens(
                credentials.json, on: ssh,
                home: "/home/\(BootstrapScript.claudeUser)")
        }

        // Bring Remote Control up now that it can actually connect.
        repair(id)
    }

    public func claudeNeedsSignIn(_ id: UUID) -> Bool {
        machine(id: id)?.status(of: .claudeCode)?.needsSignIn ?? false
    }

    // MARK: - Codex desktop app

    /// Reconciles the Codex app's Remotes list with the current machines. Returns nil when
    /// the integration is switched off or the app is not installed.
    @discardableResult
    public func syncCodexApp() throws -> CodexAppRegistrar.SyncResult? {
        guard settings.registerWithCodexApp, CodexAppRegistrar.isCodexAppInstalled else { return nil }
        return try CodexAppRegistrar.sync(machines: machines)
    }


    /// Quits the Codex app, writes the remote list, and brings it back — the only way an
    /// edit survives while the app is open, since it rewrites the whole file from memory.
    @discardableResult
    public func restartCodexApp() async throws -> CodexAppRegistrar.SyncResult {
        try await CodexAppRegistrar.restartCodexApp(applying: machines)
    }

    public func rename(_ id: UUID, to newName: String) throws {
        let name = uniqueName(from: newName, excluding: id)
        guard let old = machine(id: id) else { return }
        update(id) {
            $0.spec.name = name
            $0.sshHostAlias = SSHConfigManager.hostAlias(for: name)
        }
        try? CodexRegistrar.unregister(old, remaining: machines)
        if let updated = machine(id: id) {
            try CodexRegistrar.register(updated, allMachines: machines)
            if TunnelManager.shared.isRunning(id) {
                TunnelManager.shared.stop(id)
                TunnelManager.shared.start(updated)
            }
        }
    }

    /// Brings the registry back in line with what the provider actually has — catches
    /// servers deleted or stopped from the provider's own console.
    public func refreshFromProviders() async {
        for machine in machines {
            guard let instanceID = machine.instanceID,
                  let account = account(id: machine.spec.accountID),
                  let provider = try? self.provider(for: account) else { continue }
            do {
                if let instance = try await provider.instance(id: instanceID) {
                    update(machine.id) { $0.instance = instance }
                } else {
                    update(machine.id) {
                        $0.stage = .failed
                        $0.health = .offline
                        $0.lastError = "The server no longer exists at \(account.kind). It was probably deleted outside Codex Remote."
                    }
                    TunnelManager.shared.stop(machine.id)
                }
            } catch {
                Log.shared.warn("refresh", "\(machine.name): \(error.localizedDescription)")
            }
        }
        _ = try? SSHConfigManager.sync(machines: machines)
    }

    // MARK: - Mutation helpers

    private func update(_ id: UUID, _ transform: (inout Machine) -> Void) {
        lock.lock()
        guard let index = machineList.firstIndex(where: { $0.id == id }) else { lock.unlock(); return }
        transform(&machineList[index])
        let snapshot = machineList
        lock.unlock()
        try? machineStore.save(MachineRegistry(machines: snapshot))
        emit(.machinesChanged)
    }

    private func merge(_ machine: Machine) {
        lock.lock()
        if let index = machineList.firstIndex(where: { $0.id == machine.id }) {
            machineList[index] = machine
        } else {
            machineList.append(machine)
        }
        let snapshot = machineList
        lock.unlock()
        try? machineStore.save(MachineRegistry(machines: snapshot))
        emit(.machinesChanged)
    }

    /// Machine names become SSH aliases and file names, so they have to be unique.
    private func uniqueName(from requested: String, excluding: UUID? = nil) -> String {
        let cleaned = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? "machine" : cleaned
        let existing = Set(machines.filter { $0.id != excluding }.map { $0.name.lowercased() })
        if !existing.contains(base.lowercased()) { return base }
        var index = 2
        while existing.contains("\(base)-\(index)".lowercased()) { index += 1 }
        return "\(base)-\(index)"
    }
}
