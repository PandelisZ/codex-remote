import Foundation

/// Puts a project you already have onto a machine.
///
/// The gap this closes: you have a repo open in Codex or Claude Code, you make a remote
/// machine, and the machine knows nothing about it. You then hand-roll a clone, discover
/// the agent has no credentials to push, and separately notice that none of your `.env`
/// files came across because they are gitignored — which is exactly why a clone alone is
/// never enough.
///
/// Two ways over, and the right one depends on the project:
///
/// * **Clone** when the work is committed and pushed. The machine pulls from the origin
///   itself, which is faster than copying and leaves it able to fetch and push.
/// * **Copy** when it is not, or when there is no remote at all. Uncommitted work,
///   scratch directories and local-only repos only exist on your Mac.
///
/// Either way the untracked files that matter are sent separately, because the whole point
/// of a `.gitignore` is that git will not carry them.
public enum ProjectSync {
    /// What a local directory actually is, which decides how to send it.
    public struct Project: Sendable, Equatable {
        public let path: String
        public let name: String
        public let gitRemote: String?
        public let branch: String?
        /// Tracked work not yet pushed. A clone would silently lose this.
        public let hasUncommittedChanges: Bool
        /// Gitignored files that look like configuration rather than build output.
        public let secrets: [String]

        public init(path: String, name: String, gitRemote: String?, branch: String?,
                    hasUncommittedChanges: Bool, secrets: [String]) {
            self.path = path
            self.name = name
            self.gitRemote = gitRemote
            self.branch = branch
            self.hasUncommittedChanges = hasUncommittedChanges
            self.secrets = secrets
        }

        /// Cloning is only safe when there is a remote and nothing would be left behind.
        public var canClone: Bool { gitRemote != nil && !hasUncommittedChanges }

        public var recommended: Method { canClone ? .clone : .copy }
    }

    public enum Method: String, Sendable, Codable {
        case clone, copy
    }

    /// How the machine will be able to reach the user's git host.
    public enum GitAuth: String, Sendable, Codable {
        /// Forward the local SSH agent for the duration of a command. Nothing is copied to
        /// the machine, and the key never leaves this Mac — the best option when it works.
        case agentForwarding
        /// A `gh` token, written to the machine. Scoped to whatever that token can do, and
        /// it does persist there.
        case githubToken
        /// Don't set anything up.
        case none
    }

    // MARK: - Inspecting

    /// Files that are gitignored but are configuration rather than build output.
    ///
    /// Matched by name rather than by reading `.gitignore`, because the question is not
    /// "is this ignored" — node_modules is ignored too — but "would the project fail to run
    /// without it". Everything here is small and hand-written.
    static let secretNames = [
        ".env", ".env.local", ".env.development", ".env.development.local",
        ".env.production", ".env.production.local", ".env.test",
        ".envrc", ".npmrc", ".netrc",
    ]

    public static func inspect(path: String) async -> Project {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let name = url.lastPathComponent

        func git(_ arguments: [String]) async -> String? {
            guard let binary = Shell.which("git"),
                  let result = try? await Shell.run(binary, ["-C", url.path] + arguments, timeout: 20),
                  result.succeeded else { return nil }
            let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }

        let remote = await git(["remote", "get-url", "origin"])
        let branch = await git(["rev-parse", "--abbrev-ref", "HEAD"])
        let dirty = await git(["status", "--porcelain"]) != nil

        var secrets: [String] = []
        for candidate in secretNames {
            let file = url.appendingPathComponent(candidate)
            if FileManager.default.fileExists(atPath: file.path) { secrets.append(candidate) }
        }

        return Project(path: url.path, name: name, gitRemote: remote, branch: branch,
                       hasUncommittedChanges: dirty, secrets: secrets)
    }

    // MARK: - Sending

    /// Arguments for the copy. Split out so the exclusions can be tested without a machine.
    ///
    /// `--delete` is deliberately absent: this sends a project to a machine that may have
    /// build output or a database on it, and a flag that removes anything not on this Mac
    /// is not something to apply to someone's working directory by default.
    public static func rsyncArguments(project: Project, destination: String,
                                      sshCommand: String, includeGitDirectory: Bool) -> [String] {
        // Only flags openrsync accepts: macOS has shipped that rather than GNU rsync since
        // Sonoma, and it rejects `--info`, `--partial` and most long options outright.
        var arguments = ["-az"]
        arguments += ["-e", sshCommand]

        // Things that are large, machine-specific, or will be rebuilt anyway. Copying
        // node_modules from macOS to Linux actively breaks native modules.
        let excludes = [
            ".DS_Store", "node_modules", ".venv", "venv", "__pycache__",
            ".next", ".nuxt", "dist", "build", "target", ".build",
            ".gradle", ".idea", ".vscode", "*.log",
        ] + (includeGitDirectory ? [] : [".git"])
        for pattern in excludes { arguments += ["--exclude", pattern] }

        // Trailing slash: copy the contents into the destination, not the folder into it.
        arguments += [project.path.hasSuffix("/") ? project.path : project.path + "/", destination]
        return arguments
    }

    /// The remote shell rsync and git should use, pointed at this machine's key.
    public static func sshCommand(for machine: Machine, forwardAgent: Bool) -> String {
        var parts = [
            "ssh",
            "-o", "BatchMode=yes",
            "-o", "IdentitiesOnly=yes",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "UserKnownHostsFile=\(SSHClient.knownHostsPath)",
            "-i", machine.privateKeyPath,
            "-p", String(machine.sshPort),
        ]
        // Agent forwarding is what lets the machine authenticate to GitHub as you without
        // a key ever being written to it.
        if forwardAgent { parts += ["-A"] }
        return parts.joined(separator: " ")
    }

    /// Shell for the remote side of a clone, so the machine can reach a private repo.
    public static func cloneScript(project: Project, into workspace: String,
                                   auth: GitAuth) -> String {
        let directory = "\(workspace)/\(project.name)"
        let remote = project.gitRemote ?? ""
        let branch = project.branch.map { " --branch \(BootstrapScript.shellSafe($0))" } ?? ""

        let credentials: String
        switch auth {
        case .githubToken:
            credentials = """
            # The token arrives on stdin rather than in the script or in argv, so it is not
            # in the shell history, not in `ps`, and not in anything that logs the script.
            read -r CODEX_REMOTE_GH_TOKEN || true
            if [ -n "${CODEX_REMOTE_GH_TOKEN:-}" ]; then
              printf '%s' "$CODEX_REMOTE_GH_TOKEN" | gh auth login --with-token 2>/dev/null || true
              gh auth setup-git 2>/dev/null || true
              unset CODEX_REMOTE_GH_TOKEN
            fi
            """
        case .agentForwarding, .none:
            credentials = ""
        }

        return """
        \(BootstrapScript.preamble)
        \(credentials)

        mkdir -p \(BootstrapScript.shellSafe(workspace))
        if [ -d \(BootstrapScript.shellSafe(directory))/.git ]; then
          say "Updating \(project.name)"
          cd \(BootstrapScript.shellSafe(directory))
          git fetch --all --prune
          git pull --ff-only || say "Could not fast-forward; leaving the working tree as it is"
        else
          say "Cloning \(project.name)"
          git clone\(branch) \(BootstrapScript.shellSafe(remote)) \(BootstrapScript.shellSafe(directory))
        fi
        echo "PROJECT_PATH=\(directory)"
        """
    }
}
