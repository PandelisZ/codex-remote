import Foundation

/// Carries this Mac's MCP servers onto a machine.
///
/// Not all of them can go. The servers split cleanly in two:
///
/// * **Remote servers** — an HTTPS endpoint like `https://mcp.linear.app/mcp`. These work
///   anywhere, and with the OAuth tokens copied alongside them they are connected the
///   moment the agent starts.
/// * **Local stdio servers** — a command on this Mac. Some are portable (`npx`, `uvx`);
///   many are not, because they point at `/opt/homebrew/...`, a path under `/Users`, or
///   inside a `.app` bundle, and several exist only to drive the Mac's own screen.
///
/// Copying the second kind verbatim would give the machine a handful of servers that fail
/// to start. Codex Remote copies what will run and reports exactly what it left behind and why.
public enum MCPSync {
    public struct Server: Sendable, Hashable {
        public enum Transport: Sendable, Hashable {
            case remote(url: String, type: String)
            case stdio(command: String, args: [String], env: [String: String])
        }

        public let name: String
        public let transport: Transport
        /// Which agent's configuration it came from.
        public let source: AgentKind

        public var isRemote: Bool {
            if case .remote = transport { return true }
            return false
        }
    }

    public enum Portability: Sendable, Equatable {
        case portable
        case notPortable(reason: String)

        public var isPortable: Bool { self == .portable }
    }

    public struct Plan: Sendable {
        public let included: [Server]
        public let skipped: [(server: Server, reason: String)]

        /// True when a server being carried over launches through Node.
        ///
        /// `portableCommands` promises that `npx`, `npm` and `node` exist on the machine
        /// because the bootstrap installs them. Codex stopped needing Node when it moved to
        /// a standalone binary, and Claude Code brings its own runtime — so nothing installs
        /// it by default any more, and the promise has to be kept explicitly.
        public var needsNode: Bool {
            included.contains { server in
                guard case .stdio(let command, _, _) = server.transport else { return false }
                return ["npx", "npm", "node", "bunx", "bun"]
                    .contains((command as NSString).lastPathComponent)
            }
        }

        public var summary: String {
            var parts: [String] = []
            if !included.isEmpty {
                parts.append("\(included.count) MCP server\(included.count == 1 ? "" : "s")")
            }
            if !skipped.isEmpty {
                parts.append("\(skipped.count) skipped as Mac-only")
            }
            return parts.isEmpty ? "no MCP servers to copy" : parts.joined(separator: ", ")
        }
    }

    // MARK: - Discovery

    /// Every MCP server configured on this Mac, from both agents.
    public static func discover() -> [Server] {
        var found: [String: Server] = [:]
        for server in discoverClaudeServers() + discoverCodexServers() {
            // Same name from both agents: keep the first, they are the same server.
            found[server.name] = found[server.name] ?? server
        }
        return found.values.sorted { $0.name < $1.name }
    }

    static func discoverClaudeServers() -> [Server] {
        var servers: [Server] = []

        func absorb(_ object: [String: Any]) {
            for (name, value) in object {
                guard let config = value as? [String: Any],
                      let server = parseJSONServer(name: name, config: config, source: .claudeCode)
                else { continue }
                servers.append(server)
            }
        }

        // Global settings.
        if let data = try? Data(contentsOf: Paths.home.appendingPathComponent(".claude/settings.json")),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let mcp = object["mcpServers"] as? [String: Any] {
            absorb(mcp)
        }
        // Global plus per-project entries in ~/.claude.json.
        if let data = try? Data(contentsOf: Paths.home.appendingPathComponent(".claude.json")),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let mcp = object["mcpServers"] as? [String: Any] { absorb(mcp) }
            if let projects = object["projects"] as? [String: Any] {
                for value in projects.values {
                    if let project = value as? [String: Any],
                       let mcp = project["mcpServers"] as? [String: Any] { absorb(mcp) }
                }
            }
        }
        return servers
    }

    static func parseJSONServer(name: String, config: [String: Any], source: AgentKind) -> Server? {
        if let url = config["url"] as? String, !url.isEmpty {
            let type = config["type"] as? String ?? "http"
            return Server(name: name, transport: .remote(url: url, type: type), source: source)
        }
        guard let command = config["command"] as? String, !command.isEmpty else { return nil }
        return Server(name: name,
                      transport: .stdio(command: command,
                                        args: config["args"] as? [String] ?? [],
                                        env: config["env"] as? [String: String] ?? [:]),
                      source: source)
    }

    /// Codex keeps its servers as `[mcp_servers.name]` tables in `config.toml`.
    static func discoverCodexServers() -> [Server] {
        guard let text = try? String(contentsOf: Paths.codexHome.appendingPathComponent("config.toml"),
                                     encoding: .utf8) else { return [] }
        return parseCodexTOML(text)
    }

    /// A deliberately small TOML reader: only the `[mcp_servers.*]` tables are needed, and
    /// only the handful of keys that describe how to launch a server.
    static func parseCodexTOML(_ text: String) -> [Server] {
        var servers: [String: (command: String, args: [String], env: [String: String], url: String?)] = [:]
        var currentServer: String?
        var inEnvTable = false

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inEnvTable = false
                currentServer = nil
                let header = line.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                guard header.hasPrefix("mcp_servers.") else { continue }
                var name = String(header.dropFirst("mcp_servers.".count))
                if name.hasSuffix(".env") {
                    name = String(name.dropLast(4))
                    inEnvTable = true
                }
                name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                guard !name.isEmpty, !name.contains(".") else { continue }
                currentServer = name
                if servers[name] == nil { servers[name] = ("", [], [:], nil) }
                continue
            }

            guard let name = currentServer,
                  let equals = line.firstIndex(of: "="),
                  !line.hasPrefix("#") else { continue }
            let key = String(line[line.startIndex..<equals]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)

            if inEnvTable {
                servers[name]?.env[key.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))] =
                    unquote(value)
                continue
            }
            switch key {
            case "command": servers[name]?.command = unquote(value)
            case "url": servers[name]?.url = unquote(value)
            case "args": servers[name]?.args = parseTOMLArray(value)
            default: break
            }
        }

        return servers.compactMap { name, entry in
            if let url = entry.url, !url.isEmpty {
                return Server(name: name, transport: .remote(url: url, type: "http"), source: .codex)
            }
            guard !entry.command.isEmpty else { return nil }
            return Server(name: name,
                          transport: .stdio(command: entry.command, args: entry.args, env: entry.env),
                          source: .codex)
        }.sorted { $0.name < $1.name }
    }

    private static func unquote(_ value: String) -> String {
        var text = value
        if let comment = text.range(of: " #"), !text.hasPrefix("\"") { text = String(text[..<comment.lowerBound]) }
        text = text.trimmingCharacters(in: .whitespaces)
        if text.count >= 2, (text.hasPrefix("\"") && text.hasSuffix("\"")) || (text.hasPrefix("'") && text.hasSuffix("'")) {
            text = String(text.dropFirst().dropLast())
        }
        return text.replacingOccurrences(of: "\\\"", with: "\"")
    }

    private static func parseTOMLArray(_ value: String) -> [String] {
        guard value.hasPrefix("["), value.hasSuffix("]") else { return [] }
        let inner = String(value.dropFirst().dropLast())
        guard !inner.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return inner.split(separator: ",").map { unquote(String($0).trimmingCharacters(in: .whitespaces)) }
    }

    // MARK: - Portability

    /// Launchers that exist on a stock Linux machine, or that the bootstrap installs.
    private static let portableCommands: Set<String> = [
        "npx", "npm", "node", "bunx", "bun", "uvx", "uv", "python", "python3", "pipx", "docker",
        "bash", "sh",
    ]

    public static func portability(of server: Server) -> Portability {
        switch server.transport {
        case .remote:
            return .portable

        case .stdio(let command, let args, _):
            let executable = (command as NSString).lastPathComponent
            let isPortableLauncher = portableCommands.contains(executable)

            if command.contains(".app/") {
                return .notPortable(reason: "runs inside a macOS app bundle")
            }
            if command.hasPrefix("/"), !isPortableLauncher {
                return .notPortable(reason: "a macOS-only path (\(command))")
            }
            if !isPortableLauncher {
                return .notPortable(reason: "`\(executable)` is not installed on the machine")
            }
            // A portable launcher is only portable if what it is pointed at is too — a
            // plain `node` still cannot run a script that lives under /Users on this Mac.
            if let offending = args.first(where: { $0.hasPrefix("/Users/") || $0.contains(".app/")
                                                   || $0.hasPrefix("/opt/homebrew/")
                                                   || $0.hasPrefix("/Applications/") }) {
                return .notPortable(reason: "it runs a file that only exists on this Mac (\(offending))")
            }
            return .portable
        }
    }

    /// Decides what travels. `includeLocalServers` off keeps it to remote endpoints only,
    /// which is the safest choice and covers every OAuth-connected server.
    public static func plan(servers: [Server] = discover(),
                            includeLocalServers: Bool = true) -> Plan {
        var included: [Server] = []
        var skipped: [(Server, String)] = []

        for server in servers {
            if !includeLocalServers, !server.isRemote {
                skipped.append((server, "local servers are switched off for this machine"))
                continue
            }
            switch portability(of: server) {
            case .portable:
                included.append(server)
            case .notPortable(let reason):
                skipped.append((server, reason))
            }
        }
        return Plan(included: included, skipped: skipped)
    }

    // MARK: - Rendering

    /// The plugins this Mac has enabled, and where they came from.
    ///
    /// Most connected MCP servers are not in `mcpServers` at all — a plugin registers them.
    /// Carrying the plugin list and its marketplaces across is what makes the machine end
    /// up with the same set of servers, and the copied OAuth tokens are what make them
    /// already signed in.
    public static func claudePlugins() -> (enabled: [String: Any], marketplaces: [String: Any]) {
        guard let data = try? Data(contentsOf: Paths.home.appendingPathComponent(".claude/settings.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return ([:], [:]) }
        return (object["enabledPlugins"] as? [String: Any] ?? [:],
                object["extraKnownMarketplaces"] as? [String: Any] ?? [:])
    }

    /// `mcpServers` for the machine's `~/.claude/settings.json`.
    public static func claudeSettingsJSON(_ servers: [Server], workspacePath: String,
                                          includePlugins: Bool = true) throws -> String {
        var mcp: [String: Any] = [:]
        for server in servers {
            switch server.transport {
            case .remote(let url, let type):
                mcp[server.name] = ["type": type, "url": url]
            case .stdio(let command, let args, let env):
                var entry: [String: Any] = ["command": portableCommand(command), "args": args]
                if !env.isEmpty { entry["env"] = env }
                mcp[server.name] = entry
            }
        }
        var settings: [String: Any] = ["theme": "dark"]
        if !mcp.isEmpty { settings["mcpServers"] = mcp }
        if includePlugins {
            let plugins = claudePlugins()
            if !plugins.enabled.isEmpty { settings["enabledPlugins"] = plugins.enabled }
            if !plugins.marketplaces.isEmpty { settings["extraKnownMarketplaces"] = plugins.marketplaces }
        }
        _ = workspacePath
        let data = try JSONSerialization.data(withJSONObject: settings,
                                              options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// `[mcp_servers.*]` tables for the machine's `~/.codex/config.toml`.
    public static func codexConfigTOML(_ servers: [Server]) -> String {
        var lines: [String] = []
        for server in servers {
            lines.append("")
            lines.append("[mcp_servers.\(tomlKey(server.name))]")
            switch server.transport {
            case .remote(let url, _):
                lines.append("url = \(tomlString(url))")
            case .stdio(let command, let args, let env):
                lines.append("command = \(tomlString(portableCommand(command)))")
                if !args.isEmpty {
                    lines.append("args = [\(args.map(tomlString).joined(separator: ", "))]")
                }
                if !env.isEmpty {
                    lines.append("")
                    lines.append("[mcp_servers.\(tomlKey(server.name)).env]")
                    for (key, value) in env.sorted(by: { $0.key < $1.key }) {
                        lines.append("\(tomlKey(key)) = \(tomlString(value))")
                    }
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// `/opt/homebrew/bin/node` on this Mac is plain `node` on the machine.
    private static func portableCommand(_ command: String) -> String {
        let executable = (command as NSString).lastPathComponent
        return portableCommands.contains(executable) ? executable : command
    }

    private static func tomlKey(_ key: String) -> String {
        let plain = key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        return plain ? key : tomlString(key)
    }

    private static func tomlString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
