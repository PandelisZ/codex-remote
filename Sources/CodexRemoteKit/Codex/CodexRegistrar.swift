import Foundation

/// Wires a provisioned machine into the local Codex install.
///
/// Codex 0.157 connects a local TUI to a remote agent with
/// `codex --remote ws://HOST:PORT --remote-auth-token-env VAR -C DIR`, and its config.toml
/// has no schema for saved remotes — an unknown `[codex-remote]` table is parsed but ignored,
/// and `codex doctor` reports it as an unrecognised setting. So Codex Remote does not write into
/// config.toml. Instead it owns three things next to it:
///
///   * `~/.codex/codex-remote/machines.json` — the registry the menu bar and `codex-remote` read
///   * `~/.codex/codex-remote/bin/codex-<alias>` — a launcher per machine that opens Codex on it
///   * `~/.ssh/config.d/codex-remote` — a host entry per machine, so `ssh codex-remote-<name>` works
///
/// The bearer token is never written into any of those files; each launcher pulls it out
/// of the login keychain at run time.
public enum CodexRegistrar {
    public struct Registration: Sendable {
        public let launcherPath: String
        public let sshAlias: String
        public let endpoint: String
        public let connectCommand: String
    }

    /// Everything a machine needs on the local side. Idempotent — safe to call on every
    /// health change, rename, or app launch.
    @discardableResult
    public static func register(_ machine: Machine, allMachines: [Machine]) throws -> Registration {
        try Paths.ensureDirectories()
        try writeLauncher(for: machine)
        try writeDispatcher(machines: allMachines)
        try writeShellIntegration(machines: allMachines)
        try SSHConfigManager.sync(machines: allMachines)

        return Registration(
            launcherPath: machine.launcherPath,
            sshAlias: machine.sshHostAlias,
            endpoint: machine.endpoint,
            connectCommand: connectCommand(for: machine)
        )
    }

    public static func unregister(_ machine: Machine, remaining: [Machine]) throws {
        try? FileManager.default.removeItem(atPath: machine.launcherPath)
        try writeDispatcher(machines: remaining)
        try writeShellIntegration(machines: remaining)
        try SSHConfigManager.sync(machines: remaining)
    }

    /// The command a user could type by hand to get the same session the launcher opens.
    /// Shown in the UI and copied by "Copy connect command".
    public static func connectCommand(for machine: Machine) -> String {
        "codex --remote \(machine.endpoint) --remote-auth-token-env \(machine.tokenEnvVar) -C \(machine.spec.workspacePath)"
    }

    // MARK: - Launchers

    static func writeLauncher(for machine: Machine) throws {
        let url = URL(fileURLWithPath: machine.launcherPath)
        try launcherScript(for: machine).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    /// The launcher's text, separated from writing it so it can be inspected and tested.
    public static func launcherScript(for machine: Machine) -> String {
        """
        #!/usr/bin/env bash
        # Managed by Codex Remote — regenerated whenever the machine changes. Do not edit.
        #
        # Opens a Codex session against "\(machine.name)" (\(machine.spec.providerKind)).
        # The websocket endpoint is a local SSH forward that Codex Remote keeps open; the remote
        # Codex app-server only ever listens on the machine's own loopback interface.
        set -euo pipefail

        PORT=\(machine.localPort)
        ALIAS=\(machine.sshHostAlias)

        if ! nc -z 127.0.0.1 "$PORT" >/dev/null 2>&1; then
          echo "codex-remote: nothing is listening on 127.0.0.1:$PORT." >&2
          echo "codex-remote: open Codex Remote in the menu bar and bring \\"\(machine.name)\\" online, or run:" >&2
          echo "          ssh -N -L 127.0.0.1:$PORT:127.0.0.1:\(machine.remotePort) $ALIAS" >&2
          exit 1
        fi

        # The bearer token lives in the login keychain, not in this file.
        token="$(security find-generic-password -s io.codexremote.credentials -a '\(machine.tokenKeychainAccount)' -w 2>/dev/null || true)"
        if [ -z "$token" ]; then
          echo "codex-remote: no app-server token in the keychain for \(machine.name)." >&2
          echo "codex-remote: re-provision the machine from Codex Remote to reissue one." >&2
          exit 1
        fi
        export \(machine.tokenEnvVar)="$token"

        exec codex \\
          --remote "ws://127.0.0.1:$PORT" \\
          --remote-auth-token-env \(machine.tokenEnvVar) \\
          -C '\(machine.spec.workspacePath)' \\
          "$@"

        """
    }

    /// `codex-attach` with no argument lists the machines; with one it forwards to that
    /// machine's launcher.
    static func writeDispatcher(machines: [Machine]) throws {
        let rows = machines
            .sorted { $0.name < $1.name }
            .map { "  printf '  %-22s %-10s %s\\n' '\($0.sshHostAlias)' '\($0.spec.providerKind)' '\($0.endpoint)'" }
            .joined(separator: "\n")

        let script = """
        #!/usr/bin/env bash
        # Managed by Codex Remote. Do not edit.
        set -euo pipefail
        BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

        list() {
          echo "Codex Remote machines:"
        \(rows.isEmpty ? "  echo '  (none yet — add one from the Codex Remote menu bar item)'" : rows)
          echo
          echo "Open one with: codex-attach <alias>"
        }

        if [ $# -eq 0 ]; then list; exit 0; fi
        target="$1"; shift
        case "$target" in
          -h|--help|list) list; exit 0 ;;
        esac
        launcher="$BIN_DIR/codex-$target"
        if [ ! -x "$launcher" ]; then
          launcher="$BIN_DIR/codex-attach-$target"
        fi
        if [ ! -x "$launcher" ]; then
          echo "codex-remote: no machine called '$target'." >&2
          list >&2
          exit 1
        fi
        exec "$launcher" "$@"
        """
        let url = Paths.binDir.appendingPathComponent("codex-attach")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    /// A file the user can `source` from their shell profile to get the launchers on PATH
    /// plus a completion-friendly `codex-remote` function.
    static func writeShellIntegration(machines: [Machine]) throws {
        let aliases = machines.sorted { $0.name < $1.name }
            .map { "#   \($0.sshHostAlias)  →  \($0.endpoint)  (\($0.spec.providerKind))" }
            .joined(separator: "\n")

        let script = """
        # Codex Remote shell integration — source this from ~/.zshrc or ~/.bashrc:
        #   [ -f "$HOME/.codex/codex-remote/shell.sh" ] && . "$HOME/.codex/codex-remote/shell.sh"
        #
        # Current machines:
        \(aliases.isEmpty ? "#   (none)" : aliases)

        export PATH="$HOME/.codex/codex-remote/bin:$PATH"

        # `codex-remote` with no argument lists machines; `codex-remote <alias>` opens Codex on it.
        codex-remote() { command codex-attach "$@"; }
        """
        let url = Paths.codexRemoteHome.appendingPathComponent("shell.sh")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    }

    /// True once the user's shell profile sources our integration file.
    public static func shellIntegrationInstalled() -> Bool {
        let profiles = [".zshrc", ".bashrc", ".bash_profile", ".profile"]
        for profile in profiles {
            let url = Paths.home.appendingPathComponent(profile)
            if let text = try? String(contentsOf: url, encoding: .utf8),
               text.contains(".codex/codex-remote/shell.sh") {
                return true
            }
        }
        return false
    }

    /// Adds the `source` line to the user's shell profile, inside a marked block.
    public static func installShellIntegration(profile: String = ".zshrc") throws {
        let url = Paths.home.appendingPathComponent(profile)
        try ManagedBlock.write(
            body: "[ -f \"$HOME/.codex/codex-remote/shell.sh\" ] && . \"$HOME/.codex/codex-remote/shell.sh\"",
            to: url,
            permissions: 0o644
        )
        Log.shared.info("codex", "Added Codex Remote to ~/\(profile).")
    }

    // MARK: - Credential sync

    public static var localCodexAuthExists: Bool {
        FileManager.default.fileExists(atPath: Paths.codexAuthFile.path)
    }

    /// Copies this Mac's `~/.codex/auth.json` to the machine so Codex there can reach the
    /// model API. Without it the remote agent starts but every turn fails to authenticate.
    public static func syncCredentials(to ssh: SSHClient, codexHome: String = "/root/.codex") async throws {
        guard localCodexAuthExists else {
            throw CodexRegistrarError.noLocalAuth
        }
        let contents = try String(contentsOf: Paths.codexAuthFile, encoding: .utf8)
        try await ssh.writeFile(contents, to: "\(codexHome)/auth.json", mode: "0600")
        Log.shared.info("codex", "Copied ~/.codex/auth.json to the machine.")
    }

    /// A minimal remote config.toml. Deliberately small: it sets only what a headless
    /// worker needs and does not mirror the user's local settings, which reference local
    /// paths, plugins and MCP servers that do not exist on the machine.
    public static func remoteConfig(workspacePath: String) -> String {
        """
        # Managed by Codex Remote.
        approval_policy = "never"
        sandbox_mode = "workspace-write"

        [sandbox_workspace_write]
        network_access = true

        [projects."\(workspacePath)"]
        trust_level = "trusted"
        """
    }
}

public enum CodexRegistrarError: LocalizedError {
    case noLocalAuth

    public var errorDescription: String? {
        switch self {
        case .noLocalAuth:
            return "This Mac has no ~/.codex/auth.json, so there is nothing to copy to the machine. Run `codex login` first, or turn off credential sync for this machine and sign in on the machine itself."
        }
    }
}
