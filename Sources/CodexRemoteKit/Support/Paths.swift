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

    /// Codex Remote keeps its state inside the Codex home so the two travel together.
    public static var codexRemoteHome: URL { codexHome.appendingPathComponent("codex-remote", isDirectory: true) }
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

    public static func ensureDirectories() throws {
        let fm = FileManager.default
        for dir in [codexRemoteHome, binDir, keysDir, logsDir, sshConfigD] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }
    }
}
