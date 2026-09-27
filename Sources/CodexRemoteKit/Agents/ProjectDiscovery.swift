import Foundation

/// Finds the projects you already work on, so sending one to a machine is a pick rather
/// than a path you have to remember and type.
///
/// Both agents already keep this list. Codex records `local-projects` in its global state,
/// each with a name, its root paths and when it was last touched. Claude Code keys
/// `~/.claude.json` by absolute path, and dates them by the mtime of the per-project
/// directory under `~/.claude/projects`. Reading what is already there beats asking the
/// user to describe something both tools can see.
///
/// Read-only, and tolerant of everything: either file may be absent, mid-write, or in a
/// shape a later version changed. A project that cannot be parsed is skipped rather than
/// failing the list, because a partial list is still useful and an empty one is not.
public enum ProjectDiscovery {
    public struct Found: Sendable, Equatable, Identifiable {
        public var id: String { path }
        public let path: String
        public let name: String
        public let sources: Set<Source>
        public let lastUsed: Date?

        public init(path: String, name: String, sources: Set<Source>, lastUsed: Date?) {
            self.path = path
            self.name = name
            self.sources = sources
            self.lastUsed = lastUsed
        }

        public var sourceLabel: String {
            sources.contains(.codex) && sources.contains(.claude) ? "Codex and Claude Code"
                : sources.contains(.codex) ? "Codex" : "Claude Code"
        }
    }

    public enum Source: String, Sendable, Hashable { case codex, claude }

    /// Most recently used first. Paths that no longer exist are dropped — a stale entry in
    /// someone's agent history is not a project you can send.
    public static func discover(limit: Int = 40) -> [Found] {
        var byPath: [String: (name: String, sources: Set<Source>, date: Date?)] = [:]

        func record(path rawPath: String, name: String, source: Source, date: Date?) {
            let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
            guard isSendable(path) else { return }
            if var existing = byPath[path] {
                existing.sources.insert(source)
                // Whichever agent touched it last is the better answer.
                if let date, existing.date.map({ date > $0 }) ?? true { existing.date = date }
                byPath[path] = existing
            } else {
                byPath[path] = (name, [source], date)
            }
        }

        for project in codexProjects() {
            record(path: project.path, name: project.name, source: .codex, date: project.date)
        }
        for project in claudeProjects() {
            record(path: project.path, name: project.name, source: .claude, date: project.date)
        }

        return byPath
            .map { Found(path: $0.key, name: $0.value.name, sources: $0.value.sources,
                         lastUsed: $0.value.date) }
            .sorted { left, right in
                switch (left.lastUsed, right.lastUsed) {
                case let (l?, r?): return l > r
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
                }
            }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - What counts

    /// Not everything an agent has opened is a project worth sending.
    static func isSendable(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }

        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        // The home directory and the filesystem root get opened by accident and would be
        // catastrophic to rsync.
        if path == home || path == "/" { return false }

        // A worktree is a view of a repo that already appears in the list under its own
        // path; sending one would copy a detached checkout.
        if path.contains("/.claude/worktrees/") || path.contains("/.git/worktrees/") { return false }

        // Somewhere under a temp or cache directory is scratch, not a project.
        for fragment in ["/Library/Caches/", "/private/tmp/", "/var/folders/", "/node_modules/"]
        where path.contains(fragment) { return false }

        return true
    }

    // MARK: - Codex

    struct Raw { let path: String; let name: String; let date: Date? }

    static func codexProjects() -> [Raw] {
        let url = Paths.codexHome.appendingPathComponent(".codex-global-state.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = root["local-projects"] as? [String: Any] else { return [] }

        return projects.values.compactMap { value in
            guard let project = value as? [String: Any],
                  let roots = project["rootPaths"] as? [String],
                  let path = roots.first else { return nil }
            let name = (project["name"] as? String) ?? URL(fileURLWithPath: path).lastPathComponent
            // Milliseconds since the epoch.
            let updated = (project["updatedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
            return Raw(path: path, name: name, date: updated)
        }
    }

    // MARK: - Claude Code

    static func claudeProjects() -> [Raw] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let data = try? Data(contentsOf: home.appendingPathComponent(".claude.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = root["projects"] as? [String: Any] else { return [] }

        // `~/.claude.json` carries no dates, so recency comes from the per-project
        // directory Claude Code writes beside it.
        let sessions = home.appendingPathComponent(".claude/projects")
        return projects.keys.map { path in
            Raw(path: path,
                name: URL(fileURLWithPath: path).lastPathComponent,
                date: modified(sessions.appendingPathComponent(slug(for: path))))
        }
    }

    /// Claude Code names a project's directory after its path with the separators replaced.
    static func slug(for path: String) -> String {
        String(path.map { $0 == "/" || $0 == "." || $0 == "_" ? "-" : $0 })
    }

    private static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
