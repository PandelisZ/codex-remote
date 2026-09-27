import Foundation

/// Keeps `~/.ssh/config` in step with the machine registry so every managed machine is
/// reachable as `ssh codex-remote-<name>` from any terminal, not just from Codex Remote.
///
/// The host blocks go in `~/.ssh/config` itself, inside a marked block that `teardown()`
/// removes cleanly. They used to live in `~/.ssh/config.d/codex-remote` behind an `Include`,
/// which OpenSSH resolves happily — but the Codex desktop app discovers remote hosts by
/// parsing `~/.ssh/config` with the `ssh-config` npm package, which treats `Include` as an
/// opaque directive and does not expand it. A machine behind an Include is therefore
/// invisible to Codex, so the entries have to be written where it will actually look.
///
/// The block is kept at the TOP of the file on purpose: OpenSSH takes the first value it
/// sees for each option, and a user with a trailing `Host *` would otherwise override it.
public enum SSHConfigManager {
    public static func hostAlias(for name: String) -> String {
        let slug = name.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }
            .joined()
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return "codex-remote-\(slug.isEmpty ? "machine" : slug)"
    }

    /// Rewrites the Codex Remote host file from the given machines and makes sure `~/.ssh/config`
    /// includes it. Returns true if anything on disk changed.
    @discardableResult
    public static func sync(machines: [Machine]) throws -> Bool {
        try Paths.ensureDirectories()
        let url = Paths.sshConfig
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""

        // Anything left over from when the entries lived behind an Include.
        try? FileManager.default.removeItem(at: Paths.sshManagedFile)

        let updated = placeAtTop(body: renderHostFile(machines: machines), in: existing)
        guard updated != existing else { return false }

        try FileManager.default.createDirectory(at: Paths.sshDir, withIntermediateDirectories: true)
        try updated.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return true
    }

    /// `ManagedBlock.apply` appends when there is no block yet; these entries have to lead
    /// the file instead, so a `Host *` further down cannot win on first-match.
    static func placeAtTop(body: String, in text: String) -> String {
        let withoutBlock = ManagedBlock.remove(from: text)
        let rest = withoutBlock.drop(while: \.isNewline)
        return ManagedBlock.render(body) + (rest.isEmpty ? "" : "\n" + rest)
    }

    public static func renderHostFile(machines: [Machine]) -> String {
        var lines = [
            "# Managed by Codex Remote. Edits are overwritten.",
            "# Generated \(ISO8601DateFormatter().string(from: Date())).",
            "",
        ]
        for machine in machines.sorted(by: { $0.sshHostAlias < $1.sshHostAlias }) {
            guard let address = machine.instance?.sshAddress else { continue }
            lines.append(contentsOf: [
                "Host \(machine.sshHostAlias)",
                "    HostName \(address)",
                "    User \(machine.sshUser)",
                "    Port \(machine.sshPort)",
                "    IdentityFile \(machine.privateKeyPath)",
                "    IdentitiesOnly yes",
                "    IdentityAgent none",
                "    UserKnownHostsFile \(SSHClient.knownHostsPath)",
                "    StrictHostKeyChecking accept-new",
                "    ServerAliveInterval 20",
                "    ServerAliveCountMax 3",
                // Reuse one TCP connection for the tunnel and any ad-hoc `ssh codex-remote-x`,
                // which makes repeated commands during bootstrap much faster.
                "    ControlMaster auto",
                "    ControlPath \(controlPathTemplate)",
                "    ControlPersist 120",
                "",
            ])
        }
        return lines.joined(separator: "\n")
    }

    public static var controlPathTemplate: String {
        // Kept short: the socket path must fit in sockaddr_un (104 bytes on macOS).
        "/tmp/.codex-remote-%C"
    }

    /// Drops one host's key from Codex Remote's known_hosts, so a destroyed-and-recreated IP
    /// does not trip the host key check on the next machine.
    public static func forgetHostKey(address: String, port: Int = 22) async {
        guard let keygen = Shell.which("ssh-keygen") else { return }
        // OpenSSH stores a non-default port as "[host]:port", so remove both spellings.
        let targets = port == 22 ? [address] : [address, "[\(address)]:\(port)"]
        for target in targets {
            _ = try? await Shell.run(keygen, ["-f", SSHClient.knownHostsPath, "-R", target], timeout: 30)
        }
    }

    /// Removes everything Codex Remote put in the SSH config. Called by "Remove all machines".
    public static func teardown() throws {
        try? FileManager.default.removeItem(at: Paths.sshManagedFile)
        let url = Paths.sshConfig
        guard let existing = try? String(contentsOf: url, encoding: .utf8) else { return }
        let cleaned = ManagedBlock.remove(from: existing)
        if cleaned != existing {
            try cleaned.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
