import Foundation

/// Signs a machine in to Claude Code with its own credential.
///
/// Copying this Mac's OAuth credential does not work for Remote Control, and the reason is
/// worth writing down because it looks like it should. The copied login authenticates fine
/// for inference — the machine reports "Claude Max" — but its access token is usually
/// expired, and refreshing it consumes a single-use refresh token. Whichever install
/// refreshes first wins; the other is left holding a spent token, falls back, and Remote
/// Control disconnects with "/login". Two machines cannot share one login.
///
/// `claude auth login` offers a paste-code flow that works perfectly over SSH: it prints an
/// authorize URL, the user approves it in a browser here, and the code goes back to the
/// machine. The machine ends up with its own refresh token and nothing is shared.
///
/// The flow is deliberately split in two so no interactive SSH channel has to be held open
/// while the user is in their browser: `begin` starts the login detached behind a FIFO and
/// returns the URL; `submit` feeds the code in.
public struct ClaudeLogin: Sendable {
    public struct Pending: Sendable {
        public let authorizeURL: URL
        /// Where the machine is keeping the half-finished login.
        public let fifoPath: String
        public let logPath: String
    }

    public enum Failure: LocalizedError {
        case noURL(String)
        case timedOut
        case rejected(String)

        public var errorDescription: String? {
            switch self {
            case .noURL(let output):
                return "The machine did not offer a sign-in link.\n\(String(output.suffix(400)))"
            case .timedOut:
                return "The machine did not finish signing in. The code may have expired — start again."
            case .rejected(let detail):
                return "The machine rejected the sign-in code.\n\(String(detail.suffix(400)))"
            }
        }
    }

    private static let fifo = "/tmp/codex-remote-claude-login.fifo"
    private static let log = "/tmp/codex-remote-claude-login.log"

    /// Claude runs under its own unprivileged account, so the login has to happen there —
    /// the credential it writes must land in that account's home, not root's.
    private static func asClaude(_ command: String, user: String) -> String {
        "su - \(user) -c \(SSHClient.singleQuoted(command))"
    }

    /// Starts `claude auth login` on the machine and returns the URL to approve.
    public static func begin(on ssh: SSHClient,
                             user: String = BootstrapScript.claudeUser) async throws -> Pending {
        // A FIFO stands in for the terminal the login would normally read from, so the
        // process can wait for the code without an SSH session sitting open.
        let script = """
        set -euo pipefail
        pkill -u \(user) -f 'claude auth login' 2>/dev/null || true
        rm -f \(fifo) \(log)
        mkfifo \(fifo)
        : > \(log)
        # The login process runs as the agent account, so both files must belong to it.
        chown \(user):\(user) \(fifo) \(log)
        # `script` provides the pty; the FIFO provides stdin, held open by a sleeper so the
        # login does not see EOF and give up before the code arrives.
        #
        # Both background jobs get every descriptor closed off explicitly. A backgrounded
        # process that inherits the SSH session's stdout or stderr keeps the session open,
        # and the command that started it hangs until that process exits — ten minutes here.
        \(SSHClient.detached(asClaude("exec 3>'\(fifo)'; sleep 900", user: user)))
        \(SSHClient.detached(asClaude("script -qfec 'claude auth login' '\(log)' < '\(fifo)'", user: user)))
        for i in $(seq 1 40); do
          if grep -aq 'oauth/authorize' \(log) 2>/dev/null; then break; fi
          sleep 0.5
        done
        sed 's/\\x1b\\[[0-9;?]*[a-zA-Z]//g' \(log)
        """
        let result = try await ssh.runScript(script, timeout: 90, label: "start Claude sign-in")

        guard let url = authorizeURL(in: result.stdout) else {
            throw Failure.noURL(result.combined)
        }
        return Pending(authorizeURL: url, fifoPath: fifo, logPath: log)
    }

    /// Sends the code the user pasted from the browser, and waits for the machine to be
    /// signed in under its own credential.
    public static func submit(code: String, on ssh: SSHClient,
                              user: String = BootstrapScript.claudeUser) async throws {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.rejected("no code was given") }

        let script = submitScript(code: trimmed, user: user)
        let result = try await ssh.run(script, timeout: 150)
        guard result.stdout.contains("CODEX_REMOTE_LOGIN_OK") else {
            throw result.combined.isEmpty ? Failure.timedOut : Failure.rejected(result.combined)
        }
        // Tidy up: the FIFO and the log both name a one-time code.
        _ = try? await ssh.run("rm -f \(fifo) \(log)", timeout: 30)
    }

    /// Split out so the quoting and the privilege drop can be checked without a machine.
    static func submitScript(code trimmed: String, user: String) -> String {
        """
        set -euo pipefail
        # Written as the agent, not as root: /tmp is sticky and world-writable, and
        # `fs.protected_fifos` refuses an open-for-write on a FIFO someone else owns
        # there — a restriction root does not get to override.
        \(asClaude("printf '%s\\n' \(shellQuoted(trimmed)) > \(fifo)", user: user))
        for i in $(seq 1 60); do
          if \(asClaude("claude auth status", user: user)) 2>/dev/null | grep -q '"loggedIn": true'; then
            echo CODEX_REMOTE_LOGIN_OK
            exit 0
          fi
          sleep 1
        done
        sed 's/\\x1b\\[[0-9;?]*[a-zA-Z]//g' \(log) | tail -20
        exit 1
        """
    }

    /// Whether the machine already has its own working login.
    public static func isSignedIn(on ssh: SSHClient,
                                  user: String = BootstrapScript.claudeUser) async -> Bool {
        guard let result = try? await ssh.run(
            "\(asClaude("claude auth status", user: user)) 2>/dev/null", timeout: 40),
              result.succeeded else { return false }
        return result.stdout.contains("\"loggedIn\": true")
    }

    /// Adds this Mac's connected MCP logins to a machine that already has its own Claude
    /// login, leaving that login untouched.
    ///
    /// The merge preserves key order: Claude Code only reads the file when `claudeAiOauth`
    /// comes first, and writing it any other way silently signs the machine out.
    public static func mergeMCPTokens(_ mcpJSON: String, on ssh: SSHClient,
                                      home: String,
                                      user: String = BootstrapScript.claudeUser) async throws {
        let script = """
        set -euo pipefail
        python3 - "$@" <<'CODEX_REMOTE_MERGE_EOF'
        import json, sys, collections, os
        path = os.path.expanduser("\(home)/.claude/.credentials.json")
        try:
            current = json.load(open(path))
        except Exception:
            current = {}
        incoming = json.loads(sys.stdin.read())
        merged = collections.OrderedDict()
        # This machine's own login stays, and stays first.
        if "claudeAiOauth" in current:
            merged["claudeAiOauth"] = current["claudeAiOauth"]
        mcp = dict(current.get("mcpOAuth", {}))
        mcp.update(incoming.get("mcpOAuth", {}))
        if mcp:
            merged["mcpOAuth"] = mcp
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as handle:
            json.dump(merged, handle)
        os.chmod(path, 0o600)
        print("merged %d MCP logins" % len(mcp))
        CODEX_REMOTE_MERGE_EOF
        chown \(user):\(user) "\(home)/.claude/.credentials.json"
        """
        guard let sshBinary = Shell.which("ssh") else { throw SSHError.missingTool("ssh") }
        _ = sshBinary
        let result = try await ssh.runScriptWithInput(script, input: mcpJSON, timeout: 120,
                                                      label: "merge MCP logins")
        Log.shared.info("claude", result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Pulls the authorize URL out of the login's terminal output.
    ///
    /// Claude Code prints it as an OSC-8 hyperlink, which puts the URL in twice — once as
    /// the link target and once as the visible text — with only escape bytes between them.
    /// A naive "up to whitespace" match swallows both and yields a URL with the whole thing
    /// duplicated onto the end of `state`, which the browser rejects.
    static func authorizeURL(in output: String) -> URL? {
        // Only the hyperlink markers themselves are removed. A greedy "ESC ] … terminator"
        // strip would swallow the URL too, because the terminator is the *next* escape and
        // both copies of the URL sit between them.
        var cleaned = output
        for marker in ["\u{1B}]8;;", "\u{07}", "\u{1B}\\"] {
            cleaned = cleaned.replacingOccurrences(of: marker, with: " ")
        }
        cleaned = cleaned.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[a-zA-Z]",
                                               with: "", options: .regularExpression)

        guard let range = cleaned.range(of: "https://[^\\s]*oauth/authorize[^\\s]*",
                                        options: .regularExpression) else { return nil }
        var candidate = String(cleaned[range]).trimmingCharacters(in: .whitespacesAndNewlines)

        // The link target and the visible text are the same URL printed twice; if they
        // ended up adjacent, keep the first.
        if let second = candidate.range(of: "https://", range:
            candidate.index(candidate.startIndex, offsetBy: 1)..<candidate.endIndex) {
            candidate = String(candidate[candidate.startIndex..<second.lowerBound])
        }
        return URL(string: candidate)
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
