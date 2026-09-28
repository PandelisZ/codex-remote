import Foundation

/// Drives the bundled OpenTofu binary.
///
/// Codex Remote ships `tofu` inside its app bundle rather than asking the user to install it —
/// the point of the app is that adding a machine is one click. If the bundled copy is
/// missing (running from `swift build`, or a stripped bundle) it downloads a verified copy
/// into `~/.codex-remote/tofu/bin` once and reuses it.
public final class TofuRunner: @unchecked Sendable {
    public static let shared = TofuRunner()

    /// Pinned so every machine is provisioned by the same engine, and so a checksum can be
    /// verified against a known release.
    public static let version = "1.12.6"

    private let lock = Lock()
    private var cachedPath: String?
    private var installTask: Task<String, Error>?

    public init() {}

    public enum Failure: LocalizedError {
        case notInstalled(String)
        case commandFailed(command: String, workdir: String, output: String)
        case badOutput(String)

        public var errorDescription: String? {
            switch self {
            case .notInstalled(let detail):
                return "OpenTofu is not available: \(detail)"
            case .commandFailed(let command, _, let output):
                return "tofu \(command) failed:\n\(TofuRunner.readable(output))"
            case .badOutput(let detail):
                return "Could not read OpenTofu's output: \(detail)"
            }
        }
    }

    // MARK: - Locating the binary

    public var home: URL { Paths.codexRemoteHome.appendingPathComponent("tofu", isDirectory: true) }
    public var binDir: URL { home.appendingPathComponent("bin", isDirectory: true) }
    /// One shared plugin cache, so the hcloud provider is downloaded once and not once per
    /// machine — each provider plugin is tens of megabytes.
    public var pluginCache: URL { home.appendingPathComponent("plugin-cache", isDirectory: true) }
    public var machinesDir: URL { home.appendingPathComponent("machines", isDirectory: true) }
    public var catalogDir: URL { home.appendingPathComponent("catalog", isDirectory: true) }

    /// Where tofu already is, without installing anything.
    public func existingBinary() -> String? {
        lock.lock()
        if let cachedPath, FileManager.default.isExecutableFile(atPath: cachedPath) {
            lock.unlock()
            return cachedPath
        }
        lock.unlock()

        var candidates: [String] = []
        // Inside the app bundle, next to the executable.
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("tofu").path)
        }
        // Beside the built binaries, for `swift build` runs and the test suite.
        let executableDir = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
            .deletingLastPathComponent()
        candidates.append(executableDir.appendingPathComponent("tofu").path)
        candidates.append(executableDir.appendingPathComponent("vendor/tofu").path)
        candidates.append(binDir.appendingPathComponent("tofu").path)
        if let onPath = Shell.which("tofu") { candidates.append(onPath) }

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            lock.lock(); cachedPath = candidate; lock.unlock()
            return candidate
        }
        return nil
    }

    /// The path to tofu, downloading it first if this build has no bundled copy.
    /// Concurrent callers share one download.
    public func binary(onProgress: (@Sendable (String) -> Void)? = nil) async throws -> String {
        if let existing = existingBinary() { return existing }

        let task: Task<String, Error> = lock.withLock {
            if let installTask { return installTask }
            let created = Task<String, Error> { [weak self] in
                guard let self else { throw Failure.notInstalled("runner went away") }
                return try await self.install(onProgress: onProgress)
            }
            installTask = created
            return created
        }
        defer { lock.withLock { installTask = nil } }
        return try await task.value
    }

    /// Downloads the pinned release and verifies it against the checksums OpenTofu
    /// publishes alongside it. A binary that provisions infrastructure is not something to
    /// take on trust from an unverified download.
    private func install(onProgress: (@Sendable (String) -> Void)?) async throws -> String {
        try Paths.ensureDirectories()
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)

        let arch: String
        #if arch(arm64)
        arch = "arm64"
        #else
        arch = "amd64"
        #endif
        let version = Self.version
        let archive = "tofu_\(version)_darwin_\(arch).tar.gz"
        let base = "https://github.com/opentofu/opentofu/releases/download/v\(version)"

        onProgress?("Downloading OpenTofu \(version)")
        Log.shared.info("tofu", "Downloading OpenTofu \(version) for darwin/\(arch).")

        let scratch = home.appendingPathComponent("download", isDirectory: true)
        try? FileManager.default.removeItem(at: scratch)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let archiveURL = scratch.appendingPathComponent(archive)
        try await download(URL(string: "\(base)/\(archive)")!, to: archiveURL)

        let sumsURL = scratch.appendingPathComponent("SHA256SUMS")
        try await download(URL(string: "\(base)/tofu_\(version)_SHA256SUMS")!, to: sumsURL)

        let sums = try String(contentsOf: sumsURL, encoding: .utf8)
        guard let line = sums.split(separator: "\n").first(where: { $0.hasSuffix(" \(archive)") || $0.hasSuffix("  \(archive)") }),
              let expected = line.split(separator: " ").first.map(String.init) else {
            throw Failure.notInstalled("OpenTofu published no checksum for \(archive)")
        }
        let actual = try Self.sha256(of: archiveURL)
        guard expected.lowercased() == actual.lowercased() else {
            throw Failure.notInstalled("""
            the OpenTofu download did not match its published checksum, so it was discarded.
              expected \(expected)
              got      \(actual)
            """)
        }

        onProgress?("Unpacking OpenTofu")
        guard let tar = Shell.which("tar") else { throw Failure.notInstalled("tar is missing") }
        _ = try await Shell.check(tar, ["-xzf", archiveURL.path, "-C", scratch.path, "tofu"], timeout: 180)

        let destination = binDir.appendingPathComponent("tofu")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: scratch.appendingPathComponent("tofu"), to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)

        lock.withLock { cachedPath = destination.path }
        Log.shared.info("tofu", "Installed OpenTofu at \(destination.path).")
        return destination.path
    }

    private func download(_ url: URL, to destination: URL) async throws {
        let (temp, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.notInstalled("HTTP \(http.statusCode) fetching \(url.lastPathComponent)")
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temp, to: destination)
    }

    static func sha256(of url: URL) throws -> String {
        // Hashed in chunks: the archive is tens of megabytes and need not be resident.
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256Streaming()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(chunk)
        }
        return hasher.finalizeHex()
    }

    // MARK: - Running commands

    public struct Invocation: Sendable {
        public let arguments: [String]
        public let workdir: URL
        public let environment: [String: String]
        public let timeout: Double

        public init(_ arguments: [String], workdir: URL,
                    environment: [String: String] = [:], timeout: Double = 900) {
            self.arguments = arguments
            self.workdir = workdir
            self.environment = environment
            self.timeout = timeout
        }
    }

    @discardableResult
    public func run(_ invocation: Invocation,
                    onProgress: (@Sendable (String) -> Void)? = nil) async throws -> CommandResult {
        let tofu = try await binary(onProgress: onProgress)
        try FileManager.default.createDirectory(at: invocation.workdir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pluginCache, withIntermediateDirectories: true)

        var environment = invocation.environment
        // Share one plugin download across every machine and catalog workspace.
        environment["TF_PLUGIN_CACHE_DIR"] = pluginCache.path
        environment["TF_IN_AUTOMATION"] = "1"
        environment["TF_INPUT"] = "0"
        environment["CHECKPOINT_DISABLE"] = "1"
        // Keep tofu's own CLI config out of the user's ~/.terraformrc — but only once the
        // file exists. Pointing TF_CLI_CONFIG_FILE at a missing path makes tofu print a
        // warning block on *stdout*, ahead of the JSON that `output -json` produces.
        let cliConfig = home.appendingPathComponent("tofurc")
        if !FileManager.default.fileExists(atPath: cliConfig.path) {
            try? """
            # Written by Codex Remote so OpenTofu does not pick up a ~/.terraformrc meant for
            # something else. Codex Remote keeps its provider plugins in its own cache.
            disable_checkpoint = true
            """.write(to: cliConfig, atomically: true, encoding: .utf8)
        }
        if FileManager.default.fileExists(atPath: cliConfig.path) {
            environment["TF_CLI_CONFIG_FILE"] = cliConfig.path
        }

        let redacted = invocation.arguments.joined(separator: " ")
        Log.shared.debug("tofu", "\(redacted) (in \(invocation.workdir.lastPathComponent))")

        var result = try await Shell.run(tofu, invocation.arguments,
                                         environment: environment,
                                         currentDirectory: invocation.workdir,
                                         timeout: invocation.timeout)

        // A workspace whose provider plugins no longer match its lock file is a dead end:
        // every later command fails the same way, including the destroy that would clean it
        // up, so the machine cannot be removed from the app at all. It happens for ordinary
        // reasons — the shared plugin cache is pruned, a provider is upgraded under a
        // workspace that has sat untouched, a partial download. `init` is exactly the
        // command that repairs it, it is safe to repeat, and re-running it costs seconds.
        //
        // So rather than surfacing the error, repair and retry once. Not for `init` itself,
        // which would recurse.
        if !result.succeeded,
           invocation.arguments.first != "init",
           Self.isRecoverableProviderFailure(result.combined) {
            Log.shared.warn("tofu", "\(invocation.workdir.lastPathComponent): provider plugins are out of step with the lock file; re-initialising and retrying.")
            onProgress?("Repairing the OpenTofu providers")
            let repair = try? await Shell.run(
                tofu, ["init", "-no-color", "-input=false", "-upgrade"],
                environment: environment, currentDirectory: invocation.workdir, timeout: 600)
            if repair?.succeeded == true {
                result = try await Shell.run(tofu, invocation.arguments,
                                             environment: environment,
                                             currentDirectory: invocation.workdir,
                                             timeout: invocation.timeout)
            }
        }

        guard result.succeeded else {
            throw Failure.commandFailed(command: invocation.arguments.first ?? "",
                                        workdir: invocation.workdir.path,
                                        output: result.combined)
        }
        return result
    }

    /// Failures that `tofu init` fixes, as opposed to ones the user has to act on.
    ///
    /// Kept deliberately narrow. Retrying a credential error or a quota error would just
    /// fail twice as slowly, and retrying something genuinely destructive is worse than
    /// reporting it.
    static func isRecoverableProviderFailure(_ output: String) -> Bool {
        let text = output.lowercased()
        let signatures = [
            "required plugins are not installed",
            "please run \"tofu init\"",
            "please run \"terraform init\"",
            "provider requirements cannot be satisfied",
            "missing or corrupted provider plugins",
            "inconsistent dependency lock file",
            "module not installed",
            "initialization required",
        ]
        return signatures.contains { text.contains($0) }
    }

    /// `tofu init`. Safe to repeat; with the shared plugin cache the second call is quick.
    public func initialize(workdir: URL, environment: [String: String] = [:],
                           onProgress: (@Sendable (String) -> Void)? = nil) async throws {
        onProgress?("Preparing the OpenTofu provider")
        try await run(Invocation(["init", "-no-color", "-input=false", "-upgrade=false"],
                                 workdir: workdir, environment: environment, timeout: 600),
                      onProgress: onProgress)
    }

    /// `tofu apply -auto-approve`, streaming each step to the caller.
    public func apply(workdir: URL, environment: [String: String] = [:],
                      timeout: Double = 1800,
                      onProgress: (@Sendable (String) -> Void)? = nil) async throws {
        try await run(Invocation(["apply", "-no-color", "-input=false", "-auto-approve"],
                                 workdir: workdir, environment: environment, timeout: timeout),
                      onProgress: onProgress)
    }

    public func destroy(workdir: URL, environment: [String: String] = [:],
                        timeout: Double = 1800,
                        onProgress: (@Sendable (String) -> Void)? = nil) async throws {
        try await run(Invocation(["destroy", "-no-color", "-input=false", "-auto-approve"],
                                 workdir: workdir, environment: environment, timeout: timeout),
                      onProgress: onProgress)
    }

    public func refresh(workdir: URL, environment: [String: String] = [:]) async throws {
        try await run(Invocation(["apply", "-no-color", "-input=false", "-auto-approve", "-refresh-only"],
                                 workdir: workdir, environment: environment, timeout: 600))
    }

    /// `tofu output -json`, flattened to the plain values.
    public func outputs(workdir: URL, environment: [String: String] = [:]) async throws -> [String: Any] {
        let result = try await run(Invocation(["output", "-json", "-no-color"],
                                              workdir: workdir, environment: environment, timeout: 120))
        // tofu occasionally prefixes stdout with a warning block, so take the JSON object
        // rather than assuming the whole stream is one.
        guard let json = Self.firstJSONObject(in: result.stdout),
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw Failure.badOutput("""
            `tofu output -json` did not produce a JSON object.
            \(String(result.combined.prefix(400)))
            """)
        }
        return object.compactMapValues { ($0 as? [String: Any])?["value"] }
    }

    /// The first top-level `{…}` in a stream that may be preceded by warnings.
    static func firstJSONObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if escaped {
                escaped = false
            } else if character == "\\", inString {
                escaped = true
            } else if character == "\"" {
                inString.toggle()
            } else if !inString {
                if character == "{" { depth += 1 }
                if character == "}" {
                    depth -= 1
                    if depth == 0 { return String(text[start...index]) }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    public func hasState(workdir: URL) -> Bool {
        FileManager.default.fileExists(atPath: workdir.appendingPathComponent("terraform.tfstate").path)
    }

    /// OpenTofu's failure output is long and front-loaded with banners; the useful part is
    /// the `Error:` blocks. Keep those and drop the rest.
    static func readable(_ output: String) -> String {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var kept: [String] = []
        var capturing = false
        for line in lines {
            if line.hasPrefix("Error:") || line.hasPrefix("│ Error:") { capturing = true }
            if capturing { kept.append(line.replacingOccurrences(of: "│", with: "").trimmingCharacters(in: .whitespaces)) }
            if capturing, line.trimmingCharacters(in: .whitespaces).isEmpty, kept.count > 3 { capturing = false }
        }
        let text = kept.isEmpty ? output : kept.joined(separator: "\n")
        return String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1500))
    }
}
