import Foundation
import AppKit

/// Puts a Codex Remote machine into the **Codex desktop app**'s Remotes list, so it shows up
/// next to the user's other remote machines and a project can be added on it.
///
/// How the desktop app works, from its own bundle:
///
///   * Its remote machines live in `~/.codex/.codex-global-state.json` under
///     `codex-managed-remote-connections`. Each entry is either `source: "discovered"`
///     (an `~/.ssh/config` alias) or `source: "codex-managed"` (host details typed into
///     the app). Both are SSH connections.
///   * To build the ssh command it uses the entry's `alias` when there is one, otherwise
///     `-i <identity> -p <sshPort> <hostname>`. Codex Remote sets an alias, so the machine
///     inherits everything from the `~/.ssh/config.d/codex-remote` block it already writes —
///     including the known-hosts file and `StrictHostKeyChecking accept-new`, without
///     which a brand-new cloud server would stop at a host-key prompt.
///   * On connect it runs `command -v codex` in a login shell on the machine, refuses to
///     continue if there is none ("Please install the Codex CLI on the remote machine"),
///     and otherwise starts `codex app-server --listen unix://` there and tunnels a
///     websocket to it over SSH. Codex Remote's bootstrap has already installed Codex at
///     `/usr/local/bin/codex`, so that step finds what it needs and the machine comes up
///     as ready rather than erroring.
///   * `remote-projects` holds `{id, hostId, remotePath, label}`, which is what "add a
///     project on that machine" writes. Codex Remote seeds the workspace it created.
///
/// The app keeps this file in memory and rewrites it wholesale, so an edit made while it
/// is running is lost at its next save. Every mutating call here therefore reports whether
/// the app has to be restarted, and `restartCodexApp()` does it properly: quit, write,
/// relaunch.
public enum CodexAppRegistrar {
    public static let bundleIdentifier = "com.openai.codex"
    /// Deep link that opens the app's Connections settings, where remotes are listed.
    public static let connectionsDeepLink = URL(string: "codex://settings/connections")!

    public struct SyncResult: Sendable {
        public let added: [String]
        public let updated: [String]
        public let removed: [String]
        public let codexAppWasRunning: Bool

        public var changedAnything: Bool { !added.isEmpty || !updated.isEmpty || !removed.isEmpty }
        /// True when the user has to restart the Codex app before the change shows up.
        public var summary: String {
            guard changedAnything else { return "Codex app already up to date." }
            var parts: [String] = []
            if !added.isEmpty { parts.append("added \(added.joined(separator: ", "))") }
            if !updated.isEmpty { parts.append("updated \(updated.joined(separator: ", "))") }
            if !removed.isEmpty { parts.append("removed \(removed.joined(separator: ", "))") }
            return "Codex app remotes: " + parts.joined(separator: "; ")
        }
    }

    public enum Failure: LocalizedError {
        /// The Codex app is open, so an edit to its state file would be overwritten.
        case codexAppRunning

        case stateFileMissing
        case stateFileUnreadable(String)
        case stateFileUnwritable(String)

        public var errorDescription: String? {
            switch self {
            case .codexAppRunning:
                return "The Codex app is open, and it overwrites its own state file — an entry added now would vanish. Quit Codex and run this again to have the project folder seeded for you. You do not have to: the machine is in ~/.ssh/config, so Codex discovers it on the next launch either way."
            case .stateFileMissing:
                return "The Codex desktop app's state file isn't there yet (\(stateFileURL.path)). Open the Codex app once, then try again."
            case .stateFileUnreadable(let detail):
                return "Could not read the Codex app's state file: \(detail)"
            case .stateFileUnwritable(let detail):
                return "Could not write the Codex app's state file: \(detail)"
            }
        }
    }

    // MARK: - Locations

    public static var stateFileURL: URL {
        Paths.codexHome.appendingPathComponent(".codex-global-state.json")
    }

    public static var isCodexAppInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }

    public static var isCodexAppRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    public static var stateFileExists: Bool {
        FileManager.default.fileExists(atPath: stateFileURL.path)
    }

    /// Stable per-machine host id. Derived from the machine's own UUID so Codex Remote can find
    /// and update exactly its own entries and never touches one the user added by hand.
    public static func hostID(for machine: Machine) -> String {
        "remote-ssh-codex-managed:\(machine.id.uuidString.lowercased())"
    }

    // MARK: - Sync

    /// Brings the Codex app's remote list in line with Codex Remote's machines: every ready
    /// machine is present with current details, and Codex Remote-owned entries for machines that
    /// no longer exist are dropped. Entries Codex Remote did not create are left untouched.
    @discardableResult
    public static func sync(machines: [Machine], seedProjects: Bool = true) throws -> SyncResult {
        guard stateFileExists else { throw Failure.stateFileMissing }
        let wasRunning = isCodexAppRunning

        // The app keeps this state in memory and writes the whole file back on its own
        // schedule, so an edit made underneath a running app is silently overwritten —
        // the entry appears to have been added and is simply gone. Don't pretend.
        //
        // Nothing is lost by declining: the machine's `Host codex-remote-<name>` block is in
        // ~/.ssh/config, which is the documented way Codex finds remote hosts, so it is
        // discovered on the next launch regardless. Writing here only saves the user
        // picking the project folder themselves.
        if wasRunning {
            throw Failure.codexAppRunning
        }

        var state = try readState()
        var connections = (state["codex-managed-remote-connections"] as? [[String: Any]]) ?? []
        var projects = (state["remote-projects"] as? [[String: Any]]) ?? []
        var autoConnect = (state["remote-connection-auto-connect-by-host-id"] as? [String: Any]) ?? [:]

        // Only machines that actually have an address and finished setup are worth
        // offering: the app errors out on anything it cannot SSH into.
        let eligible = machines.filter { $0.instance?.sshAddress != nil && $0.stage == .ready }
        let wantedByHostID = Dictionary(uniqueKeysWithValues: eligible.map { (hostID(for: $0), $0) })

        var added: [String] = [], updated: [String] = [], removed: [String] = []

        // Drop every Codex Remote-owned entry that no longer corresponds to a ready machine.
        // Ownership is decided by the entry's own shape rather than by membership in the
        // current machine list — otherwise a machine deleted from Codex Remote would leave its
        // entry behind forever, because its id is no longer there to match on.
        var staleHostIDs: Set<String> = []
        connections.removeAll { entry in
            guard let hostID = entry["hostId"] as? String, isCodexRemoteOwned(entry) else { return false }
            guard wantedByHostID[hostID] == nil else { return false }
            removed.append(entry["displayName"] as? String ?? hostID)
            staleHostIDs.insert(hostID)
            return true
        }
        projects.removeAll { project in
            guard let hostID = project["hostId"] as? String else { return false }
            return staleHostIDs.contains(hostID)
        }
        for hostID in staleHostIDs { autoConnect.removeValue(forKey: hostID) }

        for machine in eligible.sorted(by: { $0.createdAt < $1.createdAt }) {
            let hostID = hostID(for: machine)
            let entry = connectionEntry(for: machine, existing: connections.first {
                ($0["hostId"] as? String) == hostID
            })

            if let index = connections.firstIndex(where: { ($0["hostId"] as? String) == hostID }) {
                if !NSDictionary(dictionary: connections[index]).isEqual(to: entry) {
                    connections[index] = entry
                    updated.append(machine.name)
                }
            } else {
                connections.append(entry)
                added.append(machine.name)
            }

            autoConnect[hostID] = true

            if seedProjects, !projects.contains(where: {
                ($0["hostId"] as? String) == hostID
                    && ($0["remotePath"] as? String) == machine.spec.workspacePath
            }) {
                projects.append([
                    "id": UUID().uuidString.lowercased(),
                    "hostId": hostID,
                    "remotePath": machine.spec.workspacePath,
                    "label": defaultProjectLabel(for: machine),
                ])
            }
        }

        guard !added.isEmpty || !updated.isEmpty || !removed.isEmpty else {
            return SyncResult(added: [], updated: [], removed: [], codexAppWasRunning: wasRunning)
        }

        state["codex-managed-remote-connections"] = connections
        state["remote-projects"] = projects
        state["remote-connection-auto-connect-by-host-id"] = autoConnect
        applyAgentModes(&state, hostIDs: wantedByHostID.keys.map { $0 })

        try writeState(state)
        let result = SyncResult(added: added, updated: updated, removed: removed,
                                codexAppWasRunning: wasRunning)
        Log.shared.info("codex-app", result.summary)
        return result
    }

    /// Removes every Codex Remote-created entry, for "stop managing these in the Codex app".
    @discardableResult
    public static func removeAll(machines: [Machine]) throws -> SyncResult {
        try sync(machines: machines.map { var copy = $0; copy.stage = .queued; return copy },
                 seedProjects: false)
    }

    /// An entry Codex Remote created: its host id is one Codex Remote mints and its alias is one of
    /// Codex Remote's SSH aliases. Anything else in the list belongs to the user.
    static func isCodexRemoteOwned(_ entry: [String: Any]) -> Bool {
        guard let hostID = entry["hostId"] as? String,
              hostID.hasPrefix("remote-ssh-codex-managed:"),
              let alias = entry["alias"] as? String else { return false }
        return alias.hasPrefix("codex-remote-")
    }

    private static func connectionEntry(for machine: Machine, existing: [String: Any]?) -> [String: Any] {
        [
            "hostId": hostID(for: machine),
            // Keep the id the app already assigned, so its own analytics/threads stay attached.
            "connectionAnalyticsId": existing?["connectionAnalyticsId"] as? String
                ?? UUID().uuidString.lowercased(),
            "displayName": machine.name,
            "source": "codex-managed",
            // With an alias set, the app runs plain `ssh <alias>` and picks up everything
            // from the Codex Remote block in ~/.ssh/config — port, key, known-hosts policy.
            "alias": machine.sshHostAlias,
            "hostname": "\(machine.sshUser)@\(machine.instance?.sshAddress ?? "")",
            "sshPort": machine.sshPort == 22 ? NSNull() : machine.sshPort,
            "identity": machine.privateKeyPath,
        ]
    }

    private static func defaultProjectLabel(for machine: Machine) -> String {
        let last = (machine.spec.workspacePath as NSString).lastPathComponent
        return last.isEmpty || last == "/" ? machine.name : last
    }

    /// The app stores per-host agent mode inside its persisted-atom blob. Seeding it means
    /// the machine is usable straight away instead of asking on first connect.
    private static func applyAgentModes(_ state: inout [String: Any], hostIDs: [String]) {
        guard !hostIDs.isEmpty else { return }
        var atoms = (state["electron-persisted-atom-state"] as? [String: Any]) ?? [:]
        var modes = (atoms["agent-mode-by-host-id"] as? [String: Any]) ?? [:]
        for hostID in hostIDs where modes[hostID] == nil {
            modes[hostID] = "auto"
        }
        atoms["agent-mode-by-host-id"] = modes
        state["electron-persisted-atom-state"] = atoms
    }

    // MARK: - File handling

    static func readState() throws -> [String: Any] {
        do {
            let data = try Data(contentsOf: stateFileURL)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw Failure.stateFileUnreadable("top level is not an object")
            }
            return object
        } catch let error as Failure {
            throw error
        } catch {
            throw Failure.stateFileUnreadable(error.localizedDescription)
        }
    }

    static func writeState(_ state: [String: Any]) throws {
        do {
            // Keep one copy of whatever was there before Codex Remote first touched it.
            let backup = stateFileURL.deletingLastPathComponent()
                .appendingPathComponent(".codex-global-state.json.codex-remote-backup")
            if !FileManager.default.fileExists(atPath: backup.path) {
                try? FileManager.default.copyItem(at: stateFileURL, to: backup)
            }
            let data = try JSONSerialization.data(withJSONObject: state,
                                                  options: [.sortedKeys, .withoutEscapingSlashes])
            let temp = stateFileURL.deletingLastPathComponent()
                .appendingPathComponent(".codex-global-state.json.codex-remote-\(UUID().uuidString).tmp")
            try data.write(to: temp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(stateFileURL, withItemAt: temp)
        } catch {
            throw Failure.stateFileUnwritable(error.localizedDescription)
        }
    }

    // MARK: - Restarting the app

    /// Quits the Codex app, applies the sync with nothing to race against, then relaunches
    /// it. This is the only way an edit sticks while the app is open, because it holds the
    /// whole state file in memory and rewrites it on its own schedule.
    @discardableResult
    public static func restartCodexApp(applying machines: [Machine],
                                       timeout: TimeInterval = 25) async throws -> SyncResult {
        let wasRunning = isCodexAppRunning
        var quit = !wasRunning

        if wasRunning {
            quit = await quitCodexApp(timeout: timeout)
            if quit {
                // It flushes its state on the way out; let that land before reading.
                try? await Task.sleep(nanoseconds: 800_000_000)
            } else {
                Log.shared.warn("codex-app", "The Codex app would not quit — it may be showing a prompt. Writing anyway; the user has to restart it.")
            }
        }

        let result = try sync(machines: machines)

        if quit, wasRunning,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            Log.shared.info("codex-app", "Relaunched the Codex app.")
        }

        // Only claim the change is live if the app really did go away and come back.
        return SyncResult(added: result.added, updated: result.updated,
                          removed: result.removed, codexAppWasRunning: !quit)
    }

    /// Asks the Codex app to quit, escalating from the Cocoa quit request to a scripted
    /// `quit`, which some Electron builds honour when the first is ignored. Never forces:
    /// a hard kill could cost the user unsaved work in a thread.
    private static func quitCodexApp(timeout: TimeInterval) async -> Bool {
        func stillRunning() -> Bool { isCodexAppRunning }

        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier) {
            app.terminate()
        }
        if await waitForExit(seconds: min(timeout, 8)) { return true }

        if let osascript = Shell.which("osascript") {
            _ = try? await Shell.run(osascript,
                                     ["-e", "tell application id \"\(bundleIdentifier)\" to quit"],
                                     timeout: 15)
            if await waitForExit(seconds: max(timeout - 8, 8)) { return true }
        }
        return !stillRunning()
    }

    private static func waitForExit(seconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if !isCodexAppRunning { return true }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return !isCodexAppRunning
    }

    /// Opens the Codex app on its Connections page, so the user lands where the machines are.
    @MainActor
    public static func openConnectionsSettings() {
        NSWorkspace.shared.open(connectionsDeepLink)
    }

    /// What Codex Remote currently has in the Codex app, for `doctor` and the settings pane.
    public static func registeredMachineNames() -> [String] {
        guard let state = try? readState(),
              let connections = state["codex-managed-remote-connections"] as? [[String: Any]] else {
            return []
        }
        return connections.compactMap { entry -> String? in
            guard isCodexRemoteOwned(entry) else { return nil }
            return entry["displayName"] as? String ?? (entry["alias"] as? String)
        }
    }
}
