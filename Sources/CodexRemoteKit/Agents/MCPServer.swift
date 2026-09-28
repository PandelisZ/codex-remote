import Foundation

/// Codex Remote as an MCP server, so an agent can build and manage its own machines.
///
/// The idea is that the agent knows what it needs better than you do at the moment you are
/// setting things up: a box with a database restored into it, a particular toolchain, more
/// memory for one job. Rather than making you translate that into a form, it can ask for it.
///
/// Run with `codex-remote mcp serve`. Speaks JSON-RPC 2.0 over stdio, which is what Codex
/// and Claude Code both expect.
///
/// ## Why this is careful
///
/// These tools spend money and can destroy servers, and an agent will happily call them in
/// a loop. Three defaults follow from that, all overridable in Settings:
///
/// * **Read-only unless you say otherwise.** With writes off, an agent can look at
///   everything and change nothing.
/// * **Destroying is separate from creating.** Turning on writes does not grant the ability
///   to delete a machine, because those two mistakes are not the same size.
/// * **Nothing is implicit.** Every tool that costs money says so in its description, and
///   the ones that are refused explain what to turn on rather than failing blankly.
public actor MCPServer {
    /// The `tools/call` surface. Kept as data so the permission rules live in one table
    /// rather than scattered through the handlers.
    public struct Tool: Sendable {
        public let name: String
        public let description: String
        public let schema: [String: Any]
        public let level: Level

        public enum Level: Sendable { case read, write, destroy }
    }

    public struct Permissions: Sendable {
        public let allowWrites: Bool
        public let allowDestroy: Bool

        public init(allowWrites: Bool, allowDestroy: Bool) {
            self.allowWrites = allowWrites
            // Destroying is not implied by writing: creating the wrong machine costs a few
            // pence, deleting the right one loses work.
            self.allowDestroy = allowDestroy && allowWrites
        }

        public func permits(_ level: Tool.Level) -> Bool {
            switch level {
            case .read: return true
            case .write: return allowWrites
            case .destroy: return allowDestroy
            }
        }

        func refusal(for level: Tool.Level) -> String {
            switch level {
            case .read:
                return ""
            case .write:
                return "This tool changes machines, which is off by default. Turn on “Let agents manage machines” in Codex Remote → Settings → General."
            case .destroy:
                return "This tool destroys a machine. Turn on “Let agents destroy machines” in Codex Remote → Settings → General, which is deliberately separate from the setting that allows changes."
            }
        }
    }

    public static let protocolVersion = "2024-11-05"

    private let manager: MachineManager
    private let permissions: Permissions

    public init(manager: MachineManager, permissions: Permissions) {
        self.manager = manager
        self.permissions = permissions
    }

    // MARK: - Catalogue

    public static func tools() -> [Tool] {
        let machineName: [String: Any] = [
            "type": "string",
            "description": "The machine's name, as `list_machines` reports it.",
        ]

        return [
            Tool(name: "list_machines",
                 description: "Every machine Codex Remote manages, with its provider, region, size, health, how many agent sessions are running on it, and current CPU and memory.",
                 schema: ["type": "object", "properties": [:]],
                 level: .read),

            Tool(name: "machine_status",
                 description: "Everything known about one machine, including its SSH alias and workspace path.",
                 schema: ["type": "object",
                          "properties": ["name": machineName],
                          "required": ["name"]],
                 level: .read),

            Tool(name: "list_providers",
                 description: "The clouds available to create machines on, and which of them have an account configured.",
                 schema: ["type": "object", "properties": [:]],
                 level: .read),

            Tool(name: "list_sizes",
                 description: "Regions, machine sizes and images available on one provider account, with monthly prices. Call this before create_machine rather than guessing a size. Pass the region you intend to use: on EC2 the image ids differ per region.",
                 schema: ["type": "object",
                          "properties": ["account": ["type": "string",
                                                     "description": "Account label from list_providers."],
                                         "region": ["type": "string",
                                                    "description": "Optional. The region the machine will be created in. Images are listed for this region; on EC2 an image id from another region does not exist."]],
                          "required": ["account"]],
                 level: .read),

            Tool(name: "run_command",
                 description: "Run a shell command on a machine over SSH and return its output. This is how you install tooling, restore a database, or inspect state. Runs as root; there is no sandbox.",
                 schema: ["type": "object",
                          "properties": [
                            "name": machineName,
                            "command": ["type": "string", "description": "Shell command to run."],
                            "timeout_seconds": ["type": "integer",
                                                "description": "Default 120. Raise it for installs.",
                                                "default": 120],
                          ],
                          "required": ["name", "command"]],
                 level: .write),

            Tool(name: "list_local_projects",
                 description: "Projects the user already works on, read from Codex's and Claude Code's own records: name, path, which agent knows it, and when it was last used. Use this to offer a choice rather than asking for a path.",
                 schema: ["type": "object", "properties": [:]],
                 level: .read),

            Tool(name: "sync_project",
                 description: "Put a local project on a machine. Clones from its git remote when the work is pushed, copies it when it is not, and separately sends untracked config like .env that a clone cannot carry. Excludes node_modules and other rebuildable bulk.",
                 schema: ["type": "object",
                          "properties": [
                            "name": machineName,
                            "path": ["type": "string", "description": "Absolute path to the project on this Mac."],
                            "method": ["type": "string", "enum": ["clone", "copy"],
                                       "description": "Omit to let it choose: clone when the tree is clean and has a remote, copy otherwise."],
                          ],
                          "required": ["name", "path"]],
                 level: .write),

            Tool(name: "create_machine",
                 description: "Create a new cloud server and install the agents on it. THIS COSTS MONEY — it bills to the user's own cloud account from the moment it exists. Call list_sizes first and tell the user the price before calling this.",
                 schema: ["type": "object",
                          "properties": [
                            "account": ["type": "string", "description": "Account label from list_providers."],
                            "name": ["type": "string", "description": "Name for the machine. Becomes its hostname and how it appears in Codex and Claude."],
                            "region": ["type": "string"],
                            "size": ["type": "string"],
                            "image": ["type": "string"],
                            "agents": ["type": "array",
                                       "items": ["type": "string", "enum": ["codex", "claude"]],
                                       "description": "Defaults to both."],
                            "workspace": ["type": "string", "description": "Path the agents work in. Defaults to /srv/workspace."],
                          ],
                          "required": ["account", "name"]],
                 level: .write),

            Tool(name: "set_power",
                 description: "Stop or start a machine. A stopped machine keeps its disk and costs less, and everything Codex Remote installed comes back on boot. Check list_machines first: a machine with sessions running is in use.",
                 schema: ["type": "object",
                          "properties": [
                            "name": machineName,
                            "state": ["type": "string", "enum": ["up", "down"]],
                          ],
                          "required": ["name", "state"]],
                 level: .write),

            Tool(name: "repair_machine",
                 description: "Re-run the remote setup on a machine. Safe to repeat; it brings anything missing back.",
                 schema: ["type": "object",
                          "properties": ["name": machineName],
                          "required": ["name"]],
                 level: .write),

            Tool(name: "destroy_machine",
                 description: "Permanently delete a machine and its server. THIS CANNOT BE UNDONE and anything on the disk is lost. Confirm with the user first, in their own words, before calling this.",
                 schema: ["type": "object",
                          "properties": [
                            "name": machineName,
                            "confirm": ["type": "string",
                                        "description": "Must be the machine's exact name. A guard against a mistyped or hallucinated name."],
                          ],
                          "required": ["name", "confirm"]],
                 level: .destroy),
        ]
    }

    // MARK: - Dispatch

    public func call(_ name: String, arguments: [String: Any]) async -> (text: String, isError: Bool) {
        guard let tool = Self.tools().first(where: { $0.name == name }) else {
            return ("No tool called `\(name)`.", true)
        }
        guard permissions.permits(tool.level) else {
            return (permissions.refusal(for: tool.level), true)
        }

        do {
            switch name {
            case "list_machines":   return (try listMachines(), false)
            case "machine_status":  return (try status(arguments), false)
            case "list_providers":  return (listProviders(), false)
            case "list_local_projects": return (localProjects(), false)
            case "list_sizes":      return (try await sizes(arguments), false)
            case "run_command":     return (try await run(arguments), false)
            case "sync_project":    return (try await sync(arguments), false)
            case "create_machine":  return (try await create(arguments), false)
            case "set_power":       return (try power(arguments), false)
            case "repair_machine":  return (try await repair(arguments), false)
            case "destroy_machine": return (try await destroy(arguments), false)
            default:                return ("`\(name)` is listed but not implemented.", true)
            }
        } catch {
            return (error.localizedDescription, true)
        }
    }

    // MARK: - Tools

    private enum Problem: LocalizedError {
        case noMachine(String)
        case noAccount(String)
        case missing(String)
        case confirmationMismatch(expected: String, got: String)

        var errorDescription: String? {
            switch self {
            case .noMachine(let name):
                return "No machine called `\(name)`. Call list_machines to see what exists."
            case .noAccount(let label):
                return "No provider account called `\(label)`. Call list_providers to see what is configured."
            case .missing(let field):
                return "`\(field)` is required."
            case .confirmationMismatch(let expected, let got):
                return "The confirmation `\(got)` does not match the machine name `\(expected)`. Nothing was destroyed."
            }
        }
    }

    private func machine(named name: String) throws -> Machine {
        guard let found = manager.machines.first(where: { $0.name == name }) else {
            throw Problem.noMachine(name)
        }
        return found
    }

    private func string(_ arguments: [String: Any], _ key: String) throws -> String {
        guard let value = arguments[key] as? String, !value.isEmpty else {
            throw Problem.missing(key)
        }
        return value
    }

    private func listMachines() throws -> String {
        let machines = manager.machines
        guard !machines.isEmpty else {
            return "No machines yet. Use create_machine, or tell the user to add one from the menu bar."
        }
        let rows = machines.map { machine -> String in
            var parts = ["\(machine.name) — \(machine.spec.providerKind) \(machine.spec.size) in \(machine.spec.region)"]
            parts.append("stage: \(machine.stage.label)")
            parts.append("health: \(machine.health)")
            if let sessions = machine.activeSessions {
                parts.append(sessions == 0 ? "idle (safe to stop)" : "\(sessions) session(s) running")
            }
            if let metrics = machine.metrics { parts.append(metrics.summary) }
            parts.append("ssh: \(machine.sshHostAlias)")
            return "- " + parts.joined(separator: " · ")
        }
        return rows.joined(separator: "\n")
    }

    private func status(_ arguments: [String: Any]) throws -> String {
        let machine = try machine(named: try string(arguments, "name"))
        var lines = [
            "name: \(machine.name)",
            "provider: \(machine.spec.providerKind)",
            "region/size: \(machine.spec.region) / \(machine.spec.size)",
            "image: \(machine.spec.image)",
            "stage: \(machine.stage.label)",
            "health: \(machine.health)",
            "workspace: \(machine.spec.workspacePath)",
            "ssh: ssh \(machine.sshHostAlias)",
            "agents: \(machine.spec.agents.map(\.rawValue).sorted().joined(separator: ", "))",
        ]
        if let address = machine.instance?.sshAddress { lines.append("address: \(machine.sshUser)@\(address)") }
        if let sessions = machine.activeSessions { lines.append("active sessions: \(sessions)") }
        if let metrics = machine.metrics { lines.append("load: \(metrics.summary)") }
        if let error = machine.lastError { lines.append("last error: \(error)") }
        return lines.joined(separator: "\n")
    }

    private func listProviders() -> String {
        let accounts = manager.accounts
        let configured = accounts.map { "- \($0.label) (\($0.kind)) — ready to use" }
        let others = ProviderRegistry.shared.all
            .filter { descriptor in !accounts.contains { $0.kind == descriptor.kind } }
            .map { "- \($0.displayName) (\($0.kind)) — supported, but no account configured" }

        if configured.isEmpty {
            return (["No accounts configured yet. The user has to add one with their own cloud token; you cannot do it for them."] + others)
                .joined(separator: "\n")
        }
        return (configured + others).joined(separator: "\n")
    }

    private func account(labelled label: String) throws -> ProviderAccount {
        guard let account = manager.accounts.first(where: {
            $0.label.caseInsensitiveCompare(label) == .orderedSame || $0.id.uuidString == label
        }) else { throw Problem.noAccount(label) }
        return account
    }

    private func sizes(_ arguments: [String: Any]) async throws -> String {
        let account = try account(labelled: try string(arguments, "account"))
        let capabilities = try await manager.capabilities(
            for: account.id, region: arguments["region"] as? String)

        func mark(_ slug: String, _ recommended: String) -> String {
            slug == recommended ? "  (default)" : ""
        }
        let regions = capabilities.regions.map {
            "  \($0.slug)\(mark($0.slug, capabilities.recommendedRegion))  — \($0.name)"
        }
        // Price is the number the agent has to tell the user before creating anything, so
        // it goes in the listing rather than being something they have to go and look up.
        let sizes = capabilities.sizes.map { size -> String in
            let price = size.monthlyPrice.map { String(format: "  %@%.2f/mo", size.currency, $0) } ?? ""
            return "  \(size.slug)\(mark(size.slug, capabilities.recommendedSize))  — \(size.vcpus) vCPU · \(size.memoryGB) GB · \(size.diskGB) GB disk\(price)"
        }
        let images = capabilities.images.map {
            "  \($0.slug)\(mark($0.slug, capabilities.recommendedImage))  — \($0.name)"
        }
        return """
        Regions:
        \(regions.joined(separator: "\n"))

        Sizes:
        \(sizes.joined(separator: "\n"))

        Images:
        \(images.joined(separator: "\n"))
        """
    }

    private func run(_ arguments: [String: Any]) async throws -> String {
        let machine = try machine(named: try string(arguments, "name"))
        let command = try string(arguments, "command")
        let timeout = (arguments["timeout_seconds"] as? Int) ?? 120

        guard let address = machine.instance?.sshAddress else {
            return "\(machine.name) has no address yet; it may still be building."
        }
        let ssh = SSHClient(host: address, user: machine.sshUser,
                            privateKeyPath: machine.privateKeyPath, port: machine.sshPort)
        let result = try await ssh.run(command, timeout: TimeInterval(timeout))
        var output = result.combined.trimmingCharacters(in: .whitespacesAndNewlines)
        if output.isEmpty { output = "(no output)" }
        // The exit code is the part an agent most often needs and most often cannot see.
        return result.succeeded ? output : "exit \(result.exitCode)\n\(output)"
    }

    private func localProjects() -> String {
        let found = ProjectDiscovery.discover()
        guard !found.isEmpty else {
            return "No projects found in Codex or Claude Code yet."
        }
        let stamp = DateFormatter()
        stamp.dateStyle = .medium
        stamp.timeStyle = .none
        return found.map { project in
            let when = project.lastUsed.map { stamp.string(from: $0) } ?? "never opened"
            return "- \(project.name) — \(project.path) · \(project.sourceLabel) · \(when)"
        }.joined(separator: "\n")
    }

    private func sync(_ arguments: [String: Any]) async throws -> String {
        let machine = try machine(named: try string(arguments, "name"))
        let path = try string(arguments, "path")
        let method = (arguments["method"] as? String).flatMap(ProjectSync.Method.init(rawValue:))

        let project = await ProjectSync.inspect(path: path)
        let destination = try await manager.syncProject(machine.id, localPath: path, method: method)

        var notes = ["\(project.name) is at \(destination) on \(machine.name)."]
        if project.hasUncommittedChanges, method == .clone {
            notes.append("Its tree had uncommitted changes, which a clone does not carry.")
        }
        if !project.secrets.isEmpty {
            notes.append("Also sent: \(project.secrets.joined(separator: ", ")).")
        }
        return notes.joined(separator: " ")
    }

    private func create(_ arguments: [String: Any]) async throws -> String {
        let account = try account(labelled: try string(arguments, "account"))
        let name = try string(arguments, "name")
        // Scoped to the requested region before the image is defaulted from it: an EC2
        // image id is only valid in the region that issued it.
        let requestedRegion = arguments["region"] as? String
        let capabilities = try? await manager.capabilities(for: account.id, region: requestedRegion)

        let agents: Set<AgentKind>
        if let requested = arguments["agents"] as? [String], !requested.isEmpty {
            agents = Set(requested.compactMap { value in
                value == "claude" ? AgentKind.claudeCode : value == "codex" ? .codex : nil
            })
        } else {
            agents = [.codex, .claudeCode]
        }

        let spec = MachineSpec(
            name: name,
            accountID: account.id,
            providerKind: account.kind,
            region: requestedRegion ?? capabilities?.recommendedRegion ?? "",
            size: (arguments["size"] as? String) ?? capabilities?.recommendedSize ?? "",
            image: (arguments["image"] as? String) ?? capabilities?.recommendedImage ?? "",
            workspacePath: (arguments["workspace"] as? String) ?? manager.settings.defaultWorkspacePath,
            agents: agents)

        let machine = try await manager.createMachine(spec: spec)
        return """
        Created \(machine.name) — \(spec.providerKind) \(spec.size) in \(spec.region).
        Setup runs in the background; poll machine_status until its stage is Ready.
        Reach it with `ssh \(machine.sshHostAlias)`, and note it is now billing to the user's \(spec.providerKind) account.
        """
    }

    private func power(_ arguments: [String: Any]) throws -> String {
        let machine = try machine(named: try string(arguments, "name"))
        let state = try string(arguments, "state")
        // Worth saying rather than silently interrupting someone's work.
        if state == "down", let sessions = machine.activeSessions, sessions > 0 {
            return "\(machine.name) has \(sessions) session(s) running. Stopping it now would interrupt them — confirm with the user first, then call again."
        }
        manager.setPower(machine.id, intent: state == "up" ? .up : .down)
        return state == "up" ? "Starting \(machine.name)." : "Stopping \(machine.name). Its disk is kept and it will come back with everything running."
    }

    private func repair(_ arguments: [String: Any]) async throws -> String {
        let machine = try machine(named: try string(arguments, "name"))
        try await manager.repair(machine.id)
        return "Re-running setup on \(machine.name). Poll machine_status until its stage is Ready."
    }

    private func destroy(_ arguments: [String: Any]) async throws -> String {
        let name = try string(arguments, "name")
        let confirm = try string(arguments, "confirm")
        guard confirm == name else {
            throw Problem.confirmationMismatch(expected: name, got: confirm)
        }
        let machine = try machine(named: name)
        try await manager.removeMachine(machine.id, destroyInstance: true)
        return "Destroyed \(name) and its server. Anything on its disk is gone."
    }
}
