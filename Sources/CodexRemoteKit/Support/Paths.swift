import Foundation

/// Every on-disk location Codex Remote reads or writes, in one place.
public enum Paths {
    public static var home: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    /// `~/.codex` unless CODEX_HOME overrides it (Codex honours the same variable).
    public static var codexHome: URL {
        if let override = ProcessInfo.processInfo.environment["CODEX_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return home.appendingPathComponent(".codex", isDirectory: true)
    }

    /// `~/.codex-remote`, unless CODEX_REMOTE_HOME overrides it.
    ///
    /// This used to live at `~/.codex/codex-remote`, inside Codex's own directory. That was
    /// the wrong place: `~/.codex` belongs to Codex, and a second product writing a
    /// subdirectory into it means `codex` cannot clean up after itself without taking our
    /// state, and our uninstall cannot remove its own directory without touching theirs.
    /// `migrateLegacyHome()` moves anything left at the old path.
    public static var codexRemoteHome: URL {
        if let override = ProcessInfo.processInfo.environment["CODEX_REMOTE_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return home.appendingPathComponent(".codex-remote", isDirectory: true)
    }

    /// Where it used to be. Only read, and only to move what is there.
    static var legacyHome: URL { codexHome.appendingPathComponent("codex-remote", isDirectory: true) }
    public static var machinesFile: URL { codexRemoteHome.appendingPathComponent("machines.json") }
    public static var accountsFile: URL { codexRemoteHome.appendingPathComponent("accounts.json") }
    public static var settingsFile: URL { codexRemoteHome.appendingPathComponent("settings.json") }
    public static var binDir: URL { codexRemoteHome.appendingPathComponent("bin", isDirectory: true) }
    public static var keysDir: URL { codexRemoteHome.appendingPathComponent("keys", isDirectory: true) }
    public static var logsDir: URL { codexRemoteHome.appendingPathComponent("logs", isDirectory: true) }

    public static var sshDir: URL { home.appendingPathComponent(".ssh", isDirectory: true) }
    public static var sshConfig: URL { sshDir.appendingPathComponent("config") }
    public static var sshConfigD: URL { sshDir.appendingPathComponent("config.d", isDirectory: true) }
    /// The single file Codex Remote owns inside `~/.ssh`. Nothing else in `~/.ssh` is rewritten.
    public static var sshManagedFile: URL { sshConfigD.appendingPathComponent("codex-remote") }

    public static var codexAuthFile: URL { codexHome.appendingPathComponent("auth.json") }

    /// Moves state from `~/.codex/codex-remote` if it is still there.
    ///
    /// A move rather than a copy, so there is exactly one directory afterwards and no
    /// question about which one is live — the OpenTofu install alone can be most of a
    /// gigabyte. If the destination already exists the old one is left completely alone:
    /// merging two histories silently is a worse outcome than an orphaned directory the
    /// user can delete.
    @discardableResult
    public static func migrateLegacyHome() -> Bool {
        let fm = FileManager.default
        let old = legacyHome, new = codexRemoteHome
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return false }
        do {
            try fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: old, to: new)
            Log.shared.info("paths", "Moved state from ~/.codex/codex-remote to \(new.path).")
            // A profile line still pointing at the old path now sources a missing file.
            CodexRegistrar.migrateShellIntegration()
            return true
        } catch {
            // Not fatal: the app starts fresh rather than refusing to run, and the old
            // directory is still there to move by hand.
            Log.shared.warn("paths", "Could not move state out of ~/.codex: \(error.localizedDescription)")
            return false
        }
    }

    public static func ensureDirectories() throws {
        migrateLegacyHome()
        let fm = FileManager.default
        for dir in [codexRemoteHome, binDir, keysDir, logsDir, sshConfigD] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }
    }
}
