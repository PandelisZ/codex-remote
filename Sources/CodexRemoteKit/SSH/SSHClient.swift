import Foundation

public enum SSHError: LocalizedError {
    case missingTool(String)
    case unreachable(host: String, detail: String)
    case remoteFailure(command: String, exitCode: Int32, output: String)

    public var errorDescription: String? {
        switch self {
        case .missingTool(let tool):
            return "\(tool) is not installed or not on PATH."
        case .unreachable(let host, let detail):
            return "Could not reach \(host) over SSH: \(detail)"
        case .remoteFailure(let command, let code, let output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Remote command failed (exit \(code)): \(command)\n\(String(trimmed.suffix(1200)))"
        }
    }
}

/// Runs commands on a remote host through the system `ssh` binary.
///
/// Host keys: a brand-new cloud server has no entry in `known_hosts`, and there is no
/// out-of-band fingerprint to check it against, so the first connection uses
/// `StrictHostKeyChecking=accept-new` — it records the key it sees and will refuse from
/// then on if it ever changes. That is trust-on-first-use, the same posture as typing
/// "yes" at the ssh prompt, and it is written to a Codex Remote-owned known_hosts file so a
/// recycled cloud IP cannot poison the user's main one.
public struct SSHClient: Sendable {
    public let host: String
    public let user: String
    public let privateKeyPath: String
    public let port: Int
    public let connectTimeout: Int

    public init(host: String, user: String = "root", privateKeyPath: String,
                port: Int = 22, connectTimeout: Int = 10) {
        self.host = host
        self.user = user
        self.privateKeyPath = privateKeyPath
        self.port = port
        self.connectTimeout = connectTimeout
    }

    public static var knownHostsPath: String {
        Paths.codexRemoteHome.appendingPathComponent("known_hosts").path
    }

    public var baseOptions: [String] {
        [
            "-o", "IdentitiesOnly=yes",
            "-o", "IdentityAgent=none",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "UserKnownHostsFile=\(Self.knownHostsPath)",
            "-o", "ConnectTimeout=\(connectTimeout)",
            "-o", "BatchMode=yes",
            "-o", "LogLevel=ERROR",
            "-i", privateKeyPath,
        ]
    }

    private func sshArguments(_ remoteCommand: [String]) -> [String] {
        baseOptions + ["-p", String(port), "\(user)@\(host)"] + remoteCommand
    }

    /// Runs a command and returns its result without throwing on a non-zero exit.
    public func run(_ command: String, timeout: Double = 600) async throws -> CommandResult {
        guard let ssh = Shell.which("ssh") else { throw SSHError.missingTool("ssh") }
        return try await Shell.run(ssh, sshArguments([command]), timeout: timeout)
    }

    @discardableResult
    public func check(_ command: String, timeout: Double = 600) async throws -> CommandResult {
        let result = try await run(command, timeout: timeout)
        guard result.succeeded else {
            throw SSHError.remoteFailure(command: command, exitCode: result.exitCode,
                                         output: result.combined)
        }
        return result
    }

    /// Pipes a script to `bash -s` on the remote so nothing has to be quoted or uploaded.
    ///
    /// Retries when the *connection* dies rather than the script. Installing packages on a
    /// fresh cloud image restarts services — sometimes sshd itself — and the session is cut
    /// even though the work on the far side completed. Every bootstrap stage is written to
    /// be idempotent precisely so this retry is safe.
    @discardableResult
    public func runScript(_ script: String, timeout: Double = 1800,
                          label: String = "bootstrap script",
                          attempts: Int = 3) async throws -> CommandResult {
        guard let ssh = Shell.which("ssh") else { throw SSHError.missingTool("ssh") }
        var lastResult: CommandResult?

        for attempt in 1...max(1, attempts) {
            let result = try await Shell.run(ssh, sshArguments(["bash -s"]), stdin: script, timeout: timeout)
            if result.succeeded { return result }
            lastResult = result

            guard Self.isTransportFailure(result), attempt < attempts else { break }
            Log.shared.warn("ssh", "\(host): \(label) lost its connection (attempt \(attempt)); waiting for the host and retrying.")
            // Give whatever restarted time to come back before trying again.
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            try await waitUntilReachable(timeout: 180)
        }

        let result = lastResult ?? CommandResult(exitCode: -1, stdout: "", stderr: "no output")
        throw SSHError.remoteFailure(command: label, exitCode: result.exitCode, output: result.combined)
    }

    /// Distinguishes "the link broke" from "the script returned non-zero". Only the former
    /// is worth retrying; a genuine script failure would just fail again.
    static func isTransportFailure(_ result: CommandResult) -> Bool {
        let text = result.combined.lowercased()
        let signatures = [
            "connection reset by peer",
            "broken pipe",
            "connection closed by remote host",
            "client_loop: send disconnect",
            "kex_exchange_identification",
            "connection timed out",
            "banner exchange",
        ]
        if signatures.contains(where: text.contains) { return true }
        // 255 is ssh's own "the transport failed" exit code; a remote script that exits
        // 255 by itself is vanishingly rare next to a dropped link.
        return result.exitCode == 255
    }

    /// Wraps a command so it runs fully detached on the remote.
    ///
    /// An SSH session does not end until every process holding its stdout or stderr has
    /// exited — so a backgrounded job that inherits them hangs the *client* until it
    /// finishes. That is how a ten-minute `sleep` held a sign-in command open. Anything
    /// Codex Remote backgrounds on a machine goes through here, which closes all three
    /// descriptors and detaches the process group.
    public static func detached(_ command: String) -> String {
        "setsid bash -c \(singleQuoted(command)) </dev/null >/dev/null 2>&1 &"
    }

    static func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Runs a script that also needs data on stdin — the script itself is sent as an
    /// argument so stdin stays free for the payload.
    @discardableResult
    public func runScriptWithInput(_ script: String, input: String, timeout: Double = 600,
                                   label: String = "script") async throws -> CommandResult {
        guard let ssh = Shell.which("ssh") else { throw SSHError.missingTool("ssh") }
        let encoded = Data(script.utf8).base64EncodedString()
        let remote = "bash -c 'echo \(encoded) | base64 -d > /tmp/.codex-remote-script.$$ && "
            + "bash /tmp/.codex-remote-script.$$; status=$?; rm -f /tmp/.codex-remote-script.$$; exit $status'"
        let result = try await Shell.run(ssh, sshArguments([remote]), stdin: input, timeout: timeout)
        guard result.succeeded else {
            throw SSHError.remoteFailure(command: label, exitCode: result.exitCode,
                                         output: result.combined)
        }
        return result
    }

    /// Writes `contents` to `path` on the remote with the given mode, without leaving a
    /// temp file on this Mac. Used for the app-server token and the systemd unit.
    public func writeFile(_ contents: String, to path: String, mode: String = "0600") async throws {
        guard let ssh = Shell.which("ssh") else { throw SSHError.missingTool("ssh") }
        // The remote shell reads the file body from stdin, so nothing has to be escaped
        // into the command line and secrets never appear in the remote process list.
        let remote = "bash -c 'set -euo pipefail; mkdir -p \"$(dirname \"$1\")\"; "
            + "umask 077; cat > \"$1\"; chmod \"$2\" \"$1\"' _ '\(path)' '\(mode)'"
        let result = try await Shell.run(ssh, sshArguments([remote]), stdin: contents, timeout: 120)
        guard result.succeeded else {
            throw SSHError.remoteFailure(command: "write \(path)", exitCode: result.exitCode,
                                         output: result.combined)
        }
    }

    /// True once the host accepts a key-based login. Used to poll a freshly booted server.
    public func isReachable() async -> Bool {
        guard let result = try? await run("true", timeout: Double(connectTimeout) + 10) else { return false }
        return result.succeeded
    }

    public func waitUntilReachable(timeout: TimeInterval = 300,
                                   onAttempt: ((Int) -> Void)? = nil) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var attempt = 0
        while Date() < deadline {
            attempt += 1
            onAttempt?(attempt)
            if await isReachable() { return }
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
        throw SSHError.unreachable(host: host, detail: "no key-based login after \(Int(timeout))s")
    }
}
