import Foundation

/// Reads the variables the user's login shell exports.
///
/// An app launched from Finder inherits almost nothing: `launchd` gives it a bare
/// environment, so a token exported in `~/.zshrc` is invisible to it even though every
/// terminal has it. That gap is why the same command works in a shell and the app sits
/// there apparently doing nothing — and, worse, falls through to a keychain read that can
/// block on an access dialog nobody is looking at.
///
/// Only variables a provider has actually declared are taken, so this never slurps
/// unrelated secrets out of the user's shell.
public final class LoginShellEnvironment: @unchecked Sendable {
    public static let shared = LoginShellEnvironment()

    private let lock = Lock()
    private var cache: [String: String]?
    private var loading = false

    public init() {}

    /// The value of `name`, from this process's environment first and the login shell's
    /// second. Returns nil rather than waiting if the shell read has not finished.
    public func value(for name: String, allowed: Set<String>) -> String? {
        if let direct = ProcessInfo.processInfo.environment[name], !direct.isEmpty {
            return direct
        }
        guard allowed.contains(name) else { return nil }
        lock.lock()
        let cached = cache
        lock.unlock()
        return cached?[name].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// True once the shell has been read, so callers know whether a miss is real.
    public var isLoaded: Bool {
        lock.lock(); defer { lock.unlock() }
        return cache != nil
    }

    /// Loads the login shell's environment once. Cheap to call repeatedly; concurrent
    /// callers wait for the one read rather than starting their own.
    public func load(allowed: Set<String>) async {
        lock.lock()
        if cache != nil { lock.unlock(); return }
        if loading {
            lock.unlock()
            // Someone else is reading it; wait for them rather than shelling out again.
            for _ in 0..<60 {
                if isLoaded { return }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            return
        }
        loading = true
        lock.unlock()

        let values = await Self.read(allowed: allowed)
        lock.lock()
        cache = values
        loading = false
        lock.unlock()

        if !values.isEmpty {
            Log.shared.info("env", "Picked up \(values.keys.sorted().joined(separator: ", ")) from your login shell.")
        }
    }

    private static func read(allowed: Set<String>) async -> [String: String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return [:] }

        // `-l -i` so both the login and interactive files are sourced — people put tokens
        // in either. A profile that hangs must not hang the app, hence the timeout.
        guard let result = try? await Shell.run(shell, ["-lic", "printenv"], timeout: 12),
              result.succeeded else {
            Log.shared.debug("env", "Could not read the login shell environment.")
            return [:]
        }

        var found: [String: String] = [:]
        for line in result.stdout.split(separator: "\n") {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let name = String(line[line.startIndex..<separator])
            guard allowed.contains(name) else { continue }
            let value = String(line[line.index(after: separator)...])
            if !value.isEmpty { found[name] = value }
        }
        return found
    }

    /// Every environment variable any registered provider knows about.
    public static func declaredVariables(_ registry: ProviderRegistry = .shared) -> Set<String> {
        Set(registry.all.flatMap { $0.credentialFields.compactMap(\.environmentVariable) })
    }
}
