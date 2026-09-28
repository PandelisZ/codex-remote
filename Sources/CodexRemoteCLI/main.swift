import Foundation
import CodexRemoteKit

// codex-remote — the same engine the menu bar drives, on the command line.
// Everything the app can do is here, so provisioning can be scripted, tested in CI, and
// debugged without a GUI.

// Line-buffer stdout so progress and prompts appear as they happen when the output is a
// pipe or a file, not all at once when the process exits.
setvbuf(stdout, nil, _IOLBF, 0)

let arguments = Array(CommandLine.arguments.dropFirst())
let manager = MachineManager()

/// Swift block-buffers stdout when it is not a terminal, so an interactive prompt can sit
/// invisible in the buffer while the command waits for input that will never come. Anything
/// that asks a question flushes first.
func prompt(_ text: String) {
    print(text, terminator: "")
    fflush(stdout)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("codex-remote: \(message)\n".utf8))
    exit(1)
}

func usage() -> String {
    """
    codex-remote — manage remote Codex machines

    ACCOUNTS
      providers                          List supported providers and what each needs
      accounts                           List saved provider accounts
      account add --provider <kind> --label <name> [--field key=value ...]
                                         Secrets are read from the matching env var, or
                                         from stdin when you pass --secret-stdin <key>
      account rm <label-or-id>

    MACHINES
      capabilities --account <label>     Regions, sizes and images for that account
      create --account <label> --name <name>
             [--region r] [--size s] [--image i] [--workspace /path]
             [--agent codex|claude ...]   which agents to install (default: both)
             [--no-credential-sync] [--no-mcp] [--idle-shutdown <minutes>]
             [--package p ...] [--post-setup <file>]
      adopt --host <addr> [--user root] [--port 22] [--key ~/.ssh/id_ed25519] --name <name>
                                         Wire up a machine you already own
      list                               Machines, stage and health
      status <name>                      Everything known about one machine
      repair <name>                      Re-run the remote setup
      reconnect <name>                   Restart the SSH tunnel
      up <name> | down <name>            Power the instance on or off
      rename <name> <new-name>
      rm <name> [--destroy]              Remove; --destroy also deletes the server

    OPENTOFU
      tofu status                        Where the bundled OpenTofu binary is
      tofu validate [--provider <kind>]  Check every provider module's HCL against that
                                         provider's real schema. Creates nothing.

    CLAUDE CODE
      projects                           Projects Codex and Claude Code already know about
      push <name> [path] [--clone|--copy] [--forward-agent|--gh-token]
                                         Put a local project on the machine. Clones when the
                                         work is pushed, copies when it is not, and sends the
                                         untracked .env files a clone cannot carry
      mcp serve                          Run the MCP server so an agent can manage machines
      mcp config                         Print the snippet to add it to your agent
      codex-pair <name> [--open]         Show a Codex pairing code for the machine, so it
                                         appears under Connections → Control other devices.
                                         --open jumps to that pane in the Codex app
      claude-login <name>                Sign a machine in to Claude Code. Opens a browser
                                         here; the machine gets its own login.

    MCP SERVERS
      mcp list                           Which of this Mac's MCP servers can run on a
                                         machine, and why the others cannot

    CODEX DESKTOP APP
      codex-sync [--restart]             Put the machines in the Codex app's Remotes list.
                                         --restart quits and relaunches the app so the
                                         change takes effect immediately.

    DIAGNOSTICS
      doctor                             Check the local side of the setup
      logs [-n 200]                      Recent activity
      connect-command <name>             Print the raw codex --remote command

    Machines are stored in ~/.codex-remote/machines.json; tokens are in the login keychain.
    """
}

// MARK: - Argument helpers

struct Args {
    let positional: [String]
    let flags: [String: [String]]

    init(_ raw: [String]) {
        var positional: [String] = []
        var flags: [String: [String]] = [:]
        var index = 0
        while index < raw.count {
            let item = raw[index]
            if item.hasPrefix("--") {
                let key = String(item.dropFirst(2))
                if index + 1 < raw.count, !raw[index + 1].hasPrefix("--") {
                    flags[key, default: []].append(raw[index + 1])
                    index += 2
                } else {
                    flags[key, default: []].append("true")
                    index += 1
                }
            } else {
                positional.append(item)
                index += 1
            }
        }
        self.positional = positional
        self.flags = flags
    }

    func value(_ key: String) -> String? { flags[key]?.first }
    func values(_ key: String) -> [String] { flags[key] ?? [] }
    func bool(_ key: String) -> Bool { flags[key] != nil }
    func require(_ key: String) -> String {
        guard let value = value(key) else { fail("missing --\(key)") }
        return value
    }
}

/// Commands that bring tunnels up or provision have to own the runtime: two owners means
/// two processes binding the same loopback ports.
///
/// Commands that only edit the registry need it for a different reason — the owner keeps
/// the registry in memory and writes it back on its own schedule, so an edit made
/// underneath it is silently reverted. Two machines destroyed at the provider came back in
/// `list` that way: the CLI removed them, the running app wrote its stale copy over the
/// top, and the registry then described servers that no longer existed.
func requireRuntimeOwnership(_ command: String, because reason: Conflict = .ports) {
    guard !manager.start(as: "codex-remote \(command)") else { return }
    let holder = manager.runtimeOwner
    let name = holder?.name ?? "another Codex Remote process"
    let pid = holder.map { String($0.pid) } ?? "?"
    fail("""
    \(name) (pid \(pid)) already owns the runtime, so `\(command)` \(reason.consequence).
    Quit the Codex Remote menu bar app and run this again, or do it from the app instead.
    """)
}

enum Conflict {
    case ports, registry

    var consequence: String {
        switch self {
        case .ports: return "would fight it for the same local ports"
        case .registry: return "would be overwritten by its copy of the machine list"
        }
    }
}

/// `--agent codex --agent claude`, defaulting to both.
func requestedAgents(_ args: Args) -> Set<AgentKind> {
    let requested = args.values("agent")
    guard !requested.isEmpty else { return Set(AgentKind.allCases) }
    var agents: Set<AgentKind> = []
    for name in requested {
        switch name.lowercased() {
        case "codex": agents.insert(.codex)
        case "claude", "claude-code", "claudecode": agents.insert(.claudeCode)
        default:
            fail("unknown agent \"\(name)\". Use codex or claude.")
        }
    }
    return agents
}

func findMachine(_ needle: String) -> Machine {
    let all = manager.machines
    if let match = all.first(where: { $0.name.caseInsensitiveCompare(needle) == .orderedSame })
        ?? all.first(where: { $0.sshHostAlias == needle })
        ?? all.first(where: { $0.id.uuidString == needle }) {
        return match
    }
    fail("no machine called \"\(needle)\". Known: \(all.map(\.name).joined(separator: ", "))")
}

func findAccount(_ needle: String) -> ProviderAccount {
    let all = manager.accounts
    if let match = all.first(where: { $0.label.caseInsensitiveCompare(needle) == .orderedSame })
        ?? all.first(where: { $0.id.uuidString == needle })
        ?? all.first(where: { $0.kind.rawValue == needle }) {
        return match
    }
    fail("no account called \"\(needle)\". Known: \(all.map(\.label).joined(separator: ", "))")
}

func healthGlyph(_ machine: Machine) -> String {
    if machine.stage == .failed { return "✗" }
    if machine.stage != .ready { return "…" }
    switch machine.health {
    case .online: return "●"
    case .degraded: return "◐"
    case .offline: return "○"
    case .unknown: return "?"
    }
}

/// Streams provisioning progress to the terminal until the machine leaves a working stage.
func followProvisioning(_ id: UUID) async {
    let token = manager.observe { event in
        if case .progress(let progress) = event, progress.machineID == id {
            print("  \(progress.stage.label.padding(toLength: 28, withPad: " ", startingAt: 0)) \(progress.message)")
        }
    }
    defer { manager.removeObserver(token) }

    while manager.isProvisioning(id) {
        try? await Task.sleep(nanoseconds: 300_000_000)
    }
    guard let machine = manager.machine(id: id) else { return }
    if machine.stage == .ready {
        print("\n✓ \(machine.name) is ready.")
        if machine.runs(.codex) {
            print("  Codex:         \(URL(fileURLWithPath: machine.launcherPath).lastPathComponent)")
            print("                 \(CodexRegistrar.connectCommand(for: machine))")
        }
        if machine.runs(.claudeCode) {
            print("  Claude:        in your account — claude.ai/code, your phone, any Claude session")
            if let url = machine.claudeSessionURL { print("                 \(url)") }
        }
        print("  Shell access:  ssh \(machine.sshHostAlias)")
    } else {
        print("\n✗ \(machine.name) failed: \(machine.lastError ?? "unknown error")")
        exit(1)
    }
}

// MARK: - Commands

func runProviders() {
    for descriptor in ProviderRegistry.shared.all {
        print("\(descriptor.kind.rawValue)  —  \(descriptor.displayName)")
        print("  \(descriptor.blurb)")
        for field in descriptor.credentialFields {
            let kind = field.style == .secret ? "secret" : "plain"
            let env = field.environmentVariable.map { " (env: \($0))" } ?? ""
            let optional = field.isOptional ? " [optional]" : ""
            print("    --field \(field.key)=…   \(field.label) — \(kind)\(env)\(optional)")
        }
        if let help = descriptor.tokenHelpURL { print("    docs: \(help)") }
        print()
    }
}

func runAccountsList() {
    let accounts = manager.accounts
    if accounts.isEmpty { print("No provider accounts yet. Add one with `codex-remote account add`."); return }
    for account in accounts {
        let identity = account.verifiedIdentity.map { " — \($0.accountLabel)" } ?? ""
        print("\(account.label)  [\(account.kind)]\(identity)")
        print("  id \(account.id.uuidString)")
        for (key, value) in account.plainFields.sorted(by: { $0.key < $1.key }) {
            print("  \(key): \(value)")
        }
    }
}

func runAccountAdd(_ args: Args) async {
    let kind = ProviderKind(args.require("provider"))
    guard let descriptor = ProviderRegistry.shared.descriptor(for: kind) else {
        fail("unknown provider \"\(kind)\". Try `codex-remote providers`.")
    }
    let label = args.value("label") ?? descriptor.displayName

    var fields: [String: String] = [:]
    for pair in args.values("field") {
        guard let equals = pair.firstIndex(of: "=") else { fail("--field wants key=value, got \"\(pair)\"") }
        fields[String(pair[pair.startIndex..<equals])] = String(pair[pair.index(after: equals)...])
    }

    var secrets: [String: Secret] = [:]
    var plain: [String: String] = [:]
    for field in descriptor.credentialFields {
        var raw = fields[field.key]
        if raw == nil, args.value("secret-stdin") == field.key {
            raw = readLine(strippingNewline: true)
        }
        if raw == nil, let env = field.environmentVariable {
            raw = ProcessInfo.processInfo.environment[env]
        }
        guard let value = raw, !value.isEmpty else {
            if field.isOptional { continue }
            fail("\(descriptor.displayName) needs \(field.label). Pass --field \(field.key)=… "
                 + (field.environmentVariable.map { "or set \($0)." } ?? "."))
        }
        if field.style == .secret { secrets[field.key] = Secret(value) } else { plain[field.key] = value }
    }

    do {
        let account = try await manager.addAccount(kind: kind, label: label,
                                                   secrets: secrets, plainFields: plain)
        print("✓ Added \(account.label) [\(kind)] — \(account.verifiedIdentity?.accountLabel ?? "verified")")
        if let detail = account.verifiedIdentity?.detail { print("  \(detail)") }
    } catch {
        fail(error.localizedDescription)
    }
}

func runCapabilities(_ args: Args) async {
    let account = findAccount(args.require("account"))
    do {
        let capabilities = try await manager.capabilities(for: account.id)
        print("Regions (\(capabilities.regions.count)), default \(capabilities.recommendedRegion):")
        for region in capabilities.regions.prefix(30) {
            print("  \(region.slug.padding(toLength: 16, withPad: " ", startingAt: 0)) \(region.name)")
        }
        print("\nSizes (\(capabilities.sizes.count)), default \(capabilities.recommendedSize):")
        for size in capabilities.sizes.prefix(25) {
            print("  \(size.slug.padding(toLength: 16, withPad: " ", startingAt: 0)) \(size.summary)")
        }
        print("\nImages (\(capabilities.images.count)), default \(capabilities.recommendedImage):")
        for image in capabilities.images.prefix(15) {
            print("  \(image.slug.padding(toLength: 24, withPad: " ", startingAt: 0)) \(image.name)")
        }
    } catch {
        fail(error.localizedDescription)
    }
}

func runCreate(_ args: Args) async {
    let account = findAccount(args.require("account"))
    let name = args.require("name")

    var region = args.value("region")
    var size = args.value("size")
    var image = args.value("image")
    if region == nil || size == nil || image == nil {
        do {
            // Scoped to --region when it was given: an EC2 image id only exists in one
            // region, so defaulting the image from the account's home region and then
            // creating elsewhere fails at apply time with "couldn't find resource".
            let capabilities = try await manager.capabilities(for: account.id, region: region)
            region = region ?? capabilities.recommendedRegion
            size = size ?? capabilities.recommendedSize
            image = image ?? capabilities.recommendedImage
        } catch {
            fail("could not read \(account.kind) capabilities: \(error.localizedDescription)")
        }
    }

    var postSetup: String?
    if let path = args.value("post-setup") {
        postSetup = try? String(contentsOfFile: (path as NSString).expandingTildeInPath, encoding: .utf8)
        if postSetup == nil { fail("could not read post-setup file at \(path)") }
    }

    let spec = MachineSpec(
        name: name,
        accountID: account.id,
        providerKind: account.kind,
        region: region!,
        size: size!,
        image: image!,
        workspacePath: args.value("workspace") ?? manager.settings.defaultWorkspacePath,
        agents: requestedAgents(args),
        syncCodexCredentials: !args.bool("no-credential-sync"),
        syncMCPServers: !args.bool("no-mcp"),
        extraPackages: args.values("package"),
        postSetupScript: postSetup,
        idleShutdownMinutes: Int(args.value("idle-shutdown") ?? "0") ?? 0
    )

    do {
        let machine = try manager.createMachine(spec: spec)
        print("Provisioning \(machine.name) on \(account.kind) (\(spec.size) in \(spec.region))…\n")
        await followProvisioning(machine.id)
    } catch {
        fail(error.localizedDescription)
    }
}

func runAdopt(_ args: Args) async {
    let host = args.require("host")
    let name = args.value("name") ?? host
    let user = args.value("user") ?? "root"
    let port = Int(args.value("port") ?? "22") ?? 22
    let key = args.value("key")

    // Reuse an existing account for the same host if there is one, so repeated adopts of
    // the same box do not pile up duplicates.
    let existing = manager.accounts.first {
        $0.kind == .existingHost
            && $0.plainFields["address"] == host
            && ($0.plainFields["user"] ?? "root") == user
            && ($0.plainFields["port"] ?? "22") == String(port)
    }

    let account: ProviderAccount
    if let existing {
        account = existing
    } else {
        var plain = ["address": host, "user": user, "port": String(port)]
        if let key { plain["privateKeyPath"] = (key as NSString).expandingTildeInPath }
        do {
            account = try await manager.addAccount(kind: .existingHost, label: "\(user)@\(host)",
                                                   secrets: [:], plainFields: plain)
        } catch {
            fail(error.localizedDescription)
        }
    }

    var postSetup: String?
    if let path = args.value("post-setup") {
        postSetup = try? String(contentsOfFile: (path as NSString).expandingTildeInPath, encoding: .utf8)
    }

    let spec = MachineSpec(
        name: name,
        accountID: account.id,
        providerKind: .existingHost,
        region: "self-hosted",
        size: "existing",
        image: "existing",
        workspacePath: args.value("workspace") ?? manager.settings.defaultWorkspacePath,
        agents: requestedAgents(args),
        syncCodexCredentials: !args.bool("no-credential-sync"),
        syncMCPServers: !args.bool("no-mcp"),
        extraPackages: args.values("package"),
        postSetupScript: postSetup,
        idleShutdownMinutes: 0,
        privateKeyPathOverride: key.map { ($0 as NSString).expandingTildeInPath },
        sshPort: port
    )

    do {
        let machine = try manager.createMachine(spec: spec)
        print("Setting up \(user)@\(host) as \"\(machine.name)\"…\n")
        await followProvisioning(machine.id)
    } catch {
        fail(error.localizedDescription)
    }
}

func runList() {
    let machines = manager.machines
    if machines.isEmpty {
        print("No machines yet. `codex-remote create --account <label> --name <name>` or `codex-remote adopt --host <addr>`.")
        return
    }
    print("  NAME                 PROVIDER        ENDPOINT                 STATUS")
    for machine in machines {
        let name = machine.name.padding(toLength: 20, withPad: " ", startingAt: 0)
        let provider = machine.spec.providerKind.rawValue.padding(toLength: 15, withPad: " ", startingAt: 0)
        let endpoint = machine.endpoint.padding(toLength: 24, withPad: " ", startingAt: 0)
        print("\(healthGlyph(machine)) \(name) \(provider) \(endpoint) \(machine.statusText)")
    }
}

func runStatus(_ name: String) async {
    let machine = findMachine(name)
    let tunnel = TunnelManager.shared.status(for: machine.id)
    print("""
    \(machine.name)
      id            \(machine.id.uuidString)
      provider      \(machine.spec.providerKind) (account \(machine.spec.accountID.uuidString))
      instance      \(machine.instanceID ?? "—")  \(machine.instance?.state.rawValue ?? "")
      address       \(machine.instance?.sshAddress ?? "—")
      region/size   \(machine.spec.region) / \(machine.spec.size)
      stage         \(machine.stage.label)
      health        \(machine.health.rawValue)\(machine.lastHealthyAt.map { " (last OK \(relative($0)))" } ?? "")
      tunnel        \(tunnel.isRunning ? "running" : "stopped"), \(tunnel.restarts) restart(s)\(tunnel.lastExit.map { ", last exit: \($0)" } ?? "")
      endpoint      \(machine.endpoint)
      workspace     \(machine.spec.workspacePath)
      agents        \(agentSummary(machine))
      remote codex  \(machine.codexVersion ?? "—")
      ssh           ssh \(machine.sshHostAlias)
      launcher      \(machine.launcherPath)
      connect       \(CodexRegistrar.connectCommand(for: machine))
    """)
    if let error = machine.lastError { print("  last error    \(error)") }
}

/// Which agents are installed and what each is doing, as one indented block.
func agentSummary(_ machine: Machine) -> String {
    let installed = machine.spec.agents.map(\.displayName).sorted().joined(separator: ", ")
    let lines = machine.agentStatuses
        .sorted { $0.kind.rawValue < $1.kind.rawValue }
        .map { status -> String in
            let name = status.kind.displayName.padding(toLength: 12, withPad: " ", startingAt: 0)
            let state = status.isRunning ? "running" : "not running"
            return "\n      · \(name) \(state)" + (status.endpoint.map { " — \($0)" } ?? "")
        }
    return installed + lines.joined()
}

func relative(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: Date())
}

func runDoctor() async {
    var problems = 0
    func check(_ label: String, _ ok: Bool, _ detail: String) {
        print("\(ok ? "✓" : "✗") \(label.padding(toLength: 28, withPad: " ", startingAt: 0)) \(detail)")
        if !ok { problems += 1 }
    }

    check("ssh", Shell.which("ssh") != nil, Shell.which("ssh") ?? "not found on PATH")
    check("ssh-keygen", Shell.which("ssh-keygen") != nil, Shell.which("ssh-keygen") ?? "not found on PATH")
    let codex = Shell.which("codex")
    check("codex CLI", codex != nil, codex ?? "not found — install it to open remote sessions")
    if let codex {
        let version = try? await Shell.run(codex, ["--version"], timeout: 20)
        print("  \(version?.combined.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")")
    }
    check("Codex Remote SSH key", FileManager.default.fileExists(atPath: SSHKeyManager.defaultPrivateKeyURL.path),
          SSHKeyManager.defaultPrivateKeyURL.path)
    check("Codex credentials", CodexRegistrar.localCodexAuthExists,
          CodexRegistrar.localCodexAuthExists ? Paths.codexAuthFile.path : "run `codex login` so machines can inherit it")
    check("~/.ssh include", (try? String(contentsOf: Paths.sshConfig, encoding: .utf8))?.contains("config.d/codex-remote") == true,
          Paths.sshManagedFile.path)
    check("shell integration", CodexRegistrar.shellIntegrationInstalled(),
          CodexRegistrar.shellIntegrationInstalled()
            ? "sourced from your shell profile"
            : "add: [ -f \"$HOME/.codex-remote/shell.sh\" ] && . \"$HOME/.codex-remote/shell.sh\"")

    check("Codex desktop app", CodexAppRegistrar.isCodexAppInstalled,
          CodexAppRegistrar.isCodexAppInstalled
            ? (CodexAppRegistrar.isCodexAppRunning ? "installed, running" : "installed, not running")
            : "not installed — machines are still usable from the CLI")
    if CodexAppRegistrar.isCodexAppInstalled {
        let registered = CodexAppRegistrar.registeredMachineNames()
        let expected = manager.machines.filter { $0.stage == .ready }.map(\.name).sorted()
        check("Codex app remotes", Set(registered) == Set(expected),
              registered.isEmpty
                ? "none registered — run `codex-remote codex-sync`"
                : registered.sorted().joined(separator: ", "))
    }

    print("\nAccounts: \(manager.accounts.count)   Machines: \(manager.machines.count)")
    for machine in manager.machines {
        let tunnel = TunnelManager.shared.status(for: machine.id)
        print("  \(healthGlyph(machine)) \(machine.name) — \(machine.statusText)\(tunnel.isRunning ? "" : " (no tunnel)")")
    }
    if problems > 0 { exit(1) }
}

// MARK: - Dispatch

guard let command = arguments.first else {
    print(usage())
    exit(0)
}
let args = Args(Array(arguments.dropFirst()))

switch command {
case "-h", "--help", "help":
    print(usage())

case "providers":
    runProviders()

case "accounts":
    runAccountsList()

case "account":
    if ["add", "rm", "remove"].contains(args.positional.first ?? "") {
        requireRuntimeOwnership("account", because: .registry)
    }
    switch args.positional.first {
    case "add": await runAccountAdd(Args(Array(arguments.dropFirst(2))))
    case "rm", "remove":
        guard args.positional.count >= 2 else { fail("usage: codex-remote account rm <label-or-id>") }
        let account = findAccount(args.positional[1])
        do { try manager.removeAccount(id: account.id); print("✓ Removed \(account.label)") }
        catch { fail(error.localizedDescription) }
    default:
        fail("usage: codex-remote account add|rm …")
    }

case "capabilities":
    await runCapabilities(args)

case "create":
    requireRuntimeOwnership("create")
    await runCreate(args)

case "adopt":
    requireRuntimeOwnership("adopt")
    await runAdopt(args)

case "list", "ls":
    // Read-only: if the app owns the runtime, just read its registry rather than
    // starting a second set of tunnels.
    _ = manager.start(as: "codex-remote list")
    try? await Task.sleep(nanoseconds: 400_000_000)
    runList()
    if let holder = manager.runtimeOwner {
        print("\n(\(holder.name) owns the live tunnels; health above is as it recorded them.)")
    }

case "status":
    guard let name = args.positional.first else { fail("usage: codex-remote status <name>") }
    await runStatus(name)

case "repair":
    requireRuntimeOwnership("repair")
    guard let name = args.positional.first else { fail("usage: codex-remote repair <name>") }
    let machine = findMachine(name)
    print("Repairing \(machine.name)…\n")
    manager.repair(machine.id)
    await followProvisioning(machine.id)

case "reconnect":
    requireRuntimeOwnership("reconnect")
    guard let name = args.positional.first else { fail("usage: codex-remote reconnect <name>") }
    let machine = findMachine(name)
    manager.reconnect(machine.id)
    try? await Task.sleep(nanoseconds: 4_000_000_000)
    await runStatus(machine.name)

case "up", "down":
    requireRuntimeOwnership(command)
    guard let name = args.positional.first else { fail("usage: codex-remote \(command) <name>") }
    let machine = findMachine(name)
    manager.setPower(machine.id, intent: command == "up" ? .up : .down)
    print("\(command == "up" ? "Powering on" : "Shutting down") \(machine.name)…")
    try? await Task.sleep(nanoseconds: command == "up" ? 20_000_000_000 : 5_000_000_000)
    await runStatus(machine.name)

case "rename":
    requireRuntimeOwnership("rename", because: .registry)
    guard args.positional.count >= 2 else { fail("usage: codex-remote rename <name> <new-name>") }
    let machine = findMachine(args.positional[0])
    do { try manager.rename(machine.id, to: args.positional[1]); print("✓ Renamed") }
    catch { fail(error.localizedDescription) }

case "rm", "remove":
    requireRuntimeOwnership("rm", because: .registry)
    guard let name = args.positional.first else { fail("usage: codex-remote rm <name> [--destroy]") }
    let machine = findMachine(name)
    let destroy = args.bool("destroy")
    if destroy {
        prompt("This permanently deletes the \(machine.spec.providerKind) server \(machine.instanceID ?? "?") — type the machine name to confirm: ")
        guard readLine(strippingNewline: true) == machine.name else { fail("aborted") }
    }
    do {
        try await manager.removeMachine(machine.id, destroyInstance: destroy)
        print("✓ Removed \(machine.name)\(destroy ? " and destroyed its server" : " (server left running)")")
    } catch {
        fail(error.localizedDescription)
    }

case "connect-command":
    guard let name = args.positional.first else { fail("usage: codex-remote connect-command <name>") }
    print(CodexRegistrar.connectCommand(for: findMachine(name)))

case "logs":
    let limit = Int(args.value("n") ?? "200") ?? 200
    for line in Log.shared.recent(limit: limit) {
        print("\(line.level.rawValue.uppercased().padding(toLength: 5, withPad: " ", startingAt: 0)) [\(line.scope)] \(line.message)")
    }

case "tofu":
    switch args.positional.first {
    case "status", nil:
        if let path = TofuRunner.shared.existingBinary() {
            let version = try? await Shell.run(path, ["version"], timeout: 30)
            print("✓ OpenTofu at \(path)")
            print("  \(version?.stdout.split(separator: "\n").first.map(String.init) ?? "")")
        } else {
            print("OpenTofu is not on this machine yet; it is downloaded on first use.")
            print("Pinned version: \(TofuRunner.version)")
        }
        print("  plugin cache: \(TofuRunner.shared.pluginCache.path)")
        print("  workspaces:   \(TofuRunner.shared.machinesDir.path)")
        let workspaces = (try? FileManager.default.contentsOfDirectory(
            atPath: TofuRunner.shared.machinesDir.path)) ?? []
        for workspace in workspaces.sorted() {
            let machine = manager.machines.first { $0.id.uuidString.lowercased() == workspace }
            print("    \(machine?.name ?? workspace)")
        }

    case "validate":
        let selected: [TofuModule]
        if let only = args.value("provider") {
            guard let module = TofuRegistration.module(for: ProviderKind(only)) else {
                fail("no OpenTofu module for \"\(only)\". Known: "
                     + TofuRegistration.modules.map { $0.kind.rawValue }.joined(separator: ", "))
            }
            selected = [module]
        } else {
            selected = TofuRegistration.modules
        }
        print("Validating \(selected.count) provider module(s) against their real schemas.")
        print("This downloads each provider plugin once and creates nothing.\n")
        let reports = await TofuValidator.validateAll(modules: selected) { message in
            print("  … \(message)")
        }
        print("")
        var failures = 0
        for report in reports {
            if report.passed {
                print("  ✓ \(report.displayName) — \(report.target)")
            } else {
                failures += 1
                print("  ✗ \(report.displayName) — \(report.target)")
                for line in (report.detail ?? "").split(separator: "\n").prefix(8) {
                    print("      \(line)")
                }
            }
        }
        print("")
        if failures == 0 {
            print("All \(reports.count) module configurations are valid.")
        } else {
            fail("\(failures) of \(reports.count) module configurations failed validation.")
        }

    default:
        fail("usage: codex-remote tofu status|validate")
    }

case "claude-login":
    guard let name = args.positional.first else { fail("usage: codex-remote claude-login <name>") }
    let machine = findMachine(name)
    guard machine.runs(.claudeCode) else {
        fail("\(machine.name) is not set up to run Claude Code.")
    }
    do {
        print("Starting sign-in on \(machine.name)…")
        let pending = try await manager.beginClaudeSignIn(machine.id)
        print("\nOpen this in your browser and approve it:\n")
        print("  \(pending.authorizeURL.absoluteString)\n")
        if let open = Shell.which("open") {
            _ = try? await Shell.run(open, [pending.authorizeURL.absoluteString], timeout: 20)
        }
        print("Then paste the code it gives you here.")
        prompt("code > ")
        guard let code = readLine(strippingNewline: true), !code.isEmpty else {
            fail("no code entered; the sign-in was left unfinished.")
        }
        print("\nSending it to \(machine.name)…")
        try await manager.completeClaudeSignIn(machine.id, code: code)
        print("✓ \(machine.name) is signed in. Bringing Remote Control up…\n")
        await followProvisioning(machine.id)
    } catch {
        fail(error.localizedDescription)
    }

case "codex-pair":
    guard let name = args.positional.first else { fail("usage: codex-remote codex-pair <name>") }
    let machine = findMachine(name)
    guard machine.runs(.codex) else {
        fail("\(machine.name) is not set up to run Codex.")
    }
    do {
        print("Turning on remote control on \(machine.name)…")
        print("(first time on a machine this installs the daemon, so give it a moment)")
        let pairing = try await manager.beginCodexPairing(machine.id)
        print("\n  Pairing code:  \(pairing.manualCode)\n")
        if let expiresAt = pairing.expiresAt {
            let seconds = Int(expiresAt.timeIntervalSinceNow.rounded(.down))
            print("  Expires in \(seconds / 60)m \(seconds % 60)s — `codex-remote codex-pair \(machine.name)` mints another.")
        }
        print("""

        In Codex: Settings → Connections → Control other devices → Add, then paste it.

        Codex Remote does not submit this for you on purpose: a paired device can run code under
        your account, and Codex checks an MFA requirement before pairing. That prompt is
        the point.
        """)
        if let pbcopy = Shell.which("pbcopy") {
            _ = try? await Shell.run(pbcopy, [], stdin: pairing.manualCode, timeout: 10)
            print("\nCopied to the clipboard.")
        }
        if args.bool("open"), let open = Shell.which("open") {
            _ = try? await Shell.run(open, [CodexRemoteControl.connectionsDeepLink.absoluteString],
                                     timeout: 20)
        }
    } catch {
        fail(error.localizedDescription)
    }

case "projects":
    let found = ProjectDiscovery.discover()
    if found.isEmpty {
        print("No projects found in Codex or Claude Code yet.")
    } else {
        print("Projects you already work on:\n")
        let stamp = DateFormatter()
        stamp.dateStyle = .medium
        stamp.timeStyle = .none
        for project in found {
            let when = project.lastUsed.map { stamp.string(from: $0) } ?? "—"
            print("  \(project.name.padding(toLength: max(22, project.name.count + 1), withPad: " ", startingAt: 0))\(when.padding(toLength: 16, withPad: " ", startingAt: 0))\(project.sourceLabel)")
            print("    \(project.path)")
        }
        print("\nSend one with: codex-remote push <machine> <path>")
    }

case "push":
    guard args.positional.count >= 1 else {
        fail("usage: codex-remote push <machine> [path] [--clone|--copy] [--forward-agent|--gh-token]")
    }
    let machine = findMachine(args.positional[0])
    let path: String
    if args.positional.count >= 2 {
        path = args.positional[1]
    } else {
        // No path given. The current directory is only the right guess when it is itself
        // a project; otherwise offer what Codex and Claude Code already know about.
        let cwd = FileManager.default.currentDirectoryPath
        let found = ProjectDiscovery.discover(limit: 12)
        if found.contains(where: { $0.path == cwd }) || found.isEmpty {
            path = cwd
        } else {
            print("Which project?\n")
            for (index, project) in found.enumerated() {
                print("  \(index + 1). \(project.name)  —  \(project.path)")
            }
            print("  0. this directory  —  \(cwd)\n")
            prompt("number > ")
            guard let answer = readLine(strippingNewline: true), let choice = Int(answer) else {
                fail("nothing picked.")
            }
            if choice == 0 { path = cwd }
            else if choice >= 1 && choice <= found.count { path = found[choice - 1].path }
            else { fail("there is no \(choice) in that list.") }
        }
    }
    do {
        let project = await ProjectSync.inspect(path: path)
        let method: ProjectSync.Method? = args.bool("clone") ? .clone
            : args.bool("copy") ? .copy : nil
        let auth: ProjectSync.GitAuth = args.bool("gh-token") ? .githubToken
            : args.bool("forward-agent") ? .agentForwarding : .none

        print("Sending \(project.name) to \(machine.name)…")
        if project.hasUncommittedChanges, method == .clone {
            print("  Note: this tree has uncommitted changes, and a clone will not carry them.")
        }
        if !project.secrets.isEmpty {
            print("  Untracked config it will also send: \(project.secrets.joined(separator: ", "))")
        }
        let destination = try await manager.syncProject(machine.id, localPath: path,
                                                        method: method, auth: auth) { message in
            print("  \(message)")
        }
        print("\n✓ \(project.name) is at \(destination) on \(machine.name).")
        print("  Open it with: ssh \(machine.sshHostAlias) -t 'cd \(destination) && bash -l'")
    } catch {
        fail(error.localizedDescription)
    }

case "mcp" where args.positional.first == "serve":
    // Nothing but JSON-RPC may go to stdout from here on; the transport writes every
    // diagnostic to stderr for that reason.
    let permissions = MCPServer.Permissions(allowWrites: manager.settings.mcpAllowWrites,
                                            allowDestroy: manager.settings.mcpAllowDestroy)
    let server = MCPServer(manager: manager, permissions: permissions)
    await MCPTransport(server: server).serve()

case "mcp" where args.positional.first == "config":
    // The snippet to paste into an agent's MCP config.
    let binary = CommandLine.arguments.first.map {
        URL(fileURLWithPath: $0).standardizedFileURL.path
    } ?? "codex-remote"
    print("""
    Add this to your agent's MCP servers:

    {
      "mcpServers": {
        "codex-remote": {
          "command": "\(binary)",
          "args": ["mcp", "serve"]
        }
      }
    }

    Claude Code:  claude mcp add codex-remote -- \(binary) mcp serve
    Codex:        add it to the [mcp_servers] table in ~/.codex/config.toml

    Agents can read machine state with no further setup. Creating, changing and running
    commands need "Let agents manage machines" in Settings; destroying needs its own
    setting beyond that.
    """)

case "mcp":
    let servers = MCPSync.discover()
    let plan = MCPSync.plan(servers: servers,
                            includeLocalServers: !args.bool("remote-only"))
    print("Found \(servers.count) MCP server(s) on this Mac.\n")
    if !plan.included.isEmpty {
        print("Will be copied to new machines:")
        for server in plan.included {
            let where_: String
            switch server.transport {
            case .remote(let url, _): where_ = url
            case .stdio(let command, let args, _):
                where_ = ([command] + args).joined(separator: " ")
            }
            print("  ✓ \(server.name.padding(toLength: 22, withPad: " ", startingAt: 0)) \(where_)")
        }
        print("")
    }
    if !plan.skipped.isEmpty {
        print("Left on this Mac:")
        for (server, reason) in plan.skipped {
            print("  · \(server.name.padding(toLength: 22, withPad: " ", startingAt: 0)) \(reason)")
        }
        print("")
    }
    print(plan.summary)

case "codex-sync":
    guard CodexAppRegistrar.isCodexAppInstalled else {
        fail("the Codex desktop app is not installed on this Mac.")
    }
    guard CodexAppRegistrar.stateFileExists else {
        fail("the Codex app has no state file yet — open it once, then run this again.")
    }
    do {
        if args.bool("restart") {
            let result = try await manager.restartCodexApp()
            print("✓ \(result.summary)")
            print("  Codex will pick the list up at its next launch.")
        } else {
            guard let result = try manager.syncCodexApp() else {
                fail("Codex app registration is switched off in settings.")
            }
            print("✓ \(result.summary)")
        }
        let names = CodexAppRegistrar.registeredMachineNames()
        if !names.isEmpty { print("  In the Codex app: \(names.joined(separator: ", "))") }
    } catch {
        fail(error.localizedDescription)
    }

case "doctor":
    await runDoctor()

default:
    fail("unknown command \"\(command)\". Try `codex-remote help`.")
}
