import Foundation
import SwiftUI
import ServiceManagement
import CodexRemoteKit

/// The SwiftUI-facing view of `MachineManager`. It owns no logic of its own — it
/// republishes the manager's state on the main actor and forwards user intent back down.
@MainActor
final class AppState: ObservableObject {
    @Published private(set) var machines: [Machine] = []
    @Published private(set) var accounts: [ProviderAccount] = []
    @Published private(set) var settings = AppSettings()
    @Published private(set) var activity: [LogLine] = []
    @Published private(set) var provisioningIDs: Set<UUID> = []
    @Published var lastProgress: [UUID: String] = [:]
    @Published var banner: Banner?
    /// The Codex app has Codex Remote's machines on disk but is showing an older list, because
    /// it keeps that file in memory and only re-reads it at launch.
    /// The machine the sign-in window is for. It is a window rather than a sheet because
    /// signing in means leaving for a browser and coming back, and a menu bar popover —
    /// along with anything presented from it — closes as soon as focus moves.
    @Published var claudeSignInTarget: Machine?
    @Published var codexPairingTarget: Machine?
    /// Bumped on each copy so the button can acknowledge it.
    @Published var setupPromptCopiedAt = Date.distantPast

    struct Banner: Identifiable, Equatable {
        enum Kind: Equatable { case info, warning, error }
        let id = UUID()
        let kind: Kind
        let message: String
    }

    let manager = MachineManager()
    private var observerToken: UUID?
    private var logToken: UUID?

    init() {
        refresh()
        observerToken = manager.observe { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        logToken = Log.shared.observe { [weak self] line in
            Task { @MainActor in
                guard let self else { return }
                self.activity.append(line)
                if self.activity.count > 400 { self.activity.removeFirst(self.activity.count - 400) }
            }
        }
        activity = Log.shared.recent(limit: 200)
        if !manager.start(as: "Codex Remote menu bar app"), let holder = manager.runtimeOwner {
            banner = Banner(kind: .warning,
                            message: "\(holder.name) (pid \(holder.pid)) is already managing the tunnels, so this window is read-only. Quit that first.")
        }
    }

    private func handle(_ event: MachineManager.Event) {
        switch event {
        case .machinesChanged, .accountsChanged, .settingsChanged:
            refresh()
        case .progress(let progress):
            lastProgress[progress.machineID] = progress.message
            refresh()
        case .failed(_, let message):
            banner = Banner(kind: .error, message: message)
        case .codexAppChanged(let result):
            if result.changedAnything {
                banner = Banner(kind: .info, message: result.summary)
            }
        }
    }

    // MARK: - Claude Code sign-in

    func beginCodexPairing(_ machine: Machine) async throws -> CodexRemoteControl.PairingCode {
        try await manager.beginCodexPairing(machine.id)
    }

    func refreshCodexPairing(_ machine: Machine) async throws -> CodexRemoteControl.PairingCode {
        try await manager.refreshCodexPairing(machine.id)
    }

    func beginClaudeSignIn(_ machine: Machine) async throws -> ClaudeLogin.Pending {
        try await manager.beginClaudeSignIn(machine.id)
    }

    func completeClaudeSignIn(_ machine: Machine, code: String) async throws {
        try await manager.completeClaudeSignIn(machine.id, code: code)
    }

    /// Machines that have Claude installed but are waiting on their one-off sign-in.
    var machinesNeedingClaudeSignIn: [Machine] {
        machines.filter { $0.status(of: .claudeCode)?.needsSignIn == true }
    }

    // MARK: - Codex desktop app

    var codexAppInstalled: Bool { CodexAppRegistrar.isCodexAppInstalled }

    /// False when another process (a `codex-remote` run) holds the runtime lock.
    var ownsRuntime: Bool { manager.ownsRuntime }

    /// Machine names currently listed in the Codex app's own state file.
    var codexAppMachines: [String] { CodexAppRegistrar.registeredMachineNames() }

    func syncCodexApp() {
        do {
            guard let result = try manager.syncCodexApp() else {
                banner = Banner(kind: .warning,
                                message: "Codex app registration is turned off in Settings.")
                return
            }
            banner = Banner(kind: .info, message: result.summary)
        } catch {
            banner = Banner(kind: .error, message: error.localizedDescription)
        }
    }

    /// Opens the Codex app on its Connections page. The list there is what the machines
    /// show up in, once the app has been restarted.
    func openCodexConnections() {
        CodexAppRegistrar.openConnectionsSettings()
    }

    /// Best effort: ask the Codex app to quit so it re-reads the remote list, then bring it
    /// back. The app is free to refuse, and currently does, so this reports honestly
    /// instead of claiming success.
    func restartCodexApp() {
        Task {
            do {
                let result = try await manager.restartCodexApp()
                banner = Banner(kind: .info, message: "Codex app restarted. \(result.summary)")
            } catch {
                banner = Banner(kind: .error, message: error.localizedDescription)
            }
        }
    }

    func refresh() {
        machines = manager.machines
        accounts = manager.accounts
        settings = manager.settings
        provisioningIDs = Set(machines.map(\.id).filter { manager.isProvisioning($0) })
    }

    // MARK: - Derived state for the menu bar

    var onlineCount: Int { machines.filter { $0.isReady }.count }
    var hasFailures: Bool { machines.contains { $0.stage == .failed } }
    var isBusy: Bool { !provisioningIDs.isEmpty }

    /// What the menu bar icon should be. It carries real information: how many machines
    /// are actually answering right now.
    var menuBarSymbol: String {
        if hasFailures { return "exclamationmark.triangle.fill" }
        if isBusy { return "arrow.triangle.2.circlepath" }
        if machines.isEmpty { return "server.rack" }
        return onlineCount > 0 ? "server.rack" : "moon.zzz"
    }

    /// What VoiceOver reads for the menu bar item, since the glyph and the count are
    /// decorative on their own.
    var menuBarAccessibilityLabel: String {
        if machines.isEmpty { return "Codex Remote, no machines" }
        if hasFailures { return "Codex Remote, a machine needs attention" }
        if isBusy { return "Codex Remote, setting up \(provisioningIDs.count) machine\(provisioningIDs.count == 1 ? "" : "s")" }
        return "Codex Remote, \(onlineCount) of \(machines.count) machines online"
    }

    // MARK: - Actions

    func createMachine(_ spec: MachineSpec) {
        do {
            _ = try manager.createMachine(spec: spec)
        } catch {
            banner = Banner(kind: .error, message: error.localizedDescription)
        }
    }

    func repair(_ machine: Machine) { manager.repair(machine.id) }
    func reconnect(_ machine: Machine) { manager.reconnect(machine.id) }

    func setPower(_ machine: Machine, up: Bool) {
        manager.setPower(machine.id, intent: up ? .up : .down)
    }

    func remove(_ machine: Machine, destroyInstance: Bool) {
        Task {
            do {
                try await manager.removeMachine(machine.id, destroyInstance: destroyInstance)
                banner = Banner(kind: .info,
                                message: destroyInstance
                                    ? "Destroyed \(machine.name) at \(machine.spec.providerKind)."
                                    : "Removed \(machine.name). The server is still running.")
            } catch {
                banner = Banner(kind: .error, message: error.localizedDescription)
            }
        }
    }

    func rename(_ machine: Machine, to name: String) {
        do { try manager.rename(machine.id, to: name) }
        catch { banner = Banner(kind: .error, message: error.localizedDescription) }
    }

    func addAccount(kind: ProviderKind, label: String, secrets: [String: Secret],
                    plainFields: [String: String]) async -> Bool {
        do {
            _ = try await manager.addAccount(kind: kind, label: label,
                                             secrets: secrets, plainFields: plainFields)
            return true
        } catch {
            banner = Banner(kind: .error, message: error.localizedDescription)
            return false
        }
    }

    func removeAccount(_ account: ProviderAccount) {
        do { try manager.removeAccount(id: account.id) }
        catch { banner = Banner(kind: .error, message: error.localizedDescription) }
    }

    func capabilities(for accountID: UUID) async throws -> ProviderCapabilities {
        try await manager.capabilities(for: accountID)
    }

    func updateSettings(_ transform: @escaping (inout AppSettings) -> Void) {
        manager.updateSettings(transform)
    }

    func refreshFromProviders() {
        Task { await manager.refreshFromProviders() }
    }

    // MARK: - Opening a session

    /// Opens the machine's launcher in Terminal, which is the whole point of the app: one
    /// click and Codex is running against the remote agent.
    func openInCodex(_ machine: Machine) {
        guard FileManager.default.isExecutableFile(atPath: machine.launcherPath) else {
            banner = Banner(kind: .error, message: "\(machine.name) has no launcher yet. Repair it first.")
            return
        }
        let url = URL(fileURLWithPath: machine.launcherPath)
        let configuration = NSWorkspace.OpenConfiguration()
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([url], withApplicationAt: terminal,
                                configuration: configuration) { [weak self] _, error in
            if let error {
                Task { @MainActor in
                    self?.banner = .init(kind: .error, message: "Could not open Terminal: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Opens the machine's live Claude session in the browser. A Claude machine has no
    /// local endpoint to launch a terminal against — it lives in the account — so the
    /// session URL is the equivalent of Codex's launcher.
    func copySetupPrompt() {
        let cli = Bundle.main.url(forAuxiliaryExecutable: "codex-remote")?.path ?? "codex-remote"
        let prompt = SetupPrompt.firstMachine(hasAccount: !accounts.isEmpty, cliPath: cli)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
        setupPromptCopiedAt = Date()
    }

    func openInClaude(_ machine: Machine) {
        guard let url = machine.claudeSessionURL.flatMap(URL.init(string:)) else {
            banner = Banner(kind: .warning,
                            message: "\(machine.name) has no Claude session yet. Sign it in first.")
            return
        }
        NSWorkspace.shared.open(url)
    }

    func copyClaudeSessionURL(_ machine: Machine) {
        guard let url = machine.claudeSessionURL else {
            banner = Banner(kind: .warning, message: "\(machine.name) has no Claude session yet.")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        banner = Banner(kind: .info, message: "Copied the Claude session link.")
    }

    func copyConnectCommand(_ machine: Machine) {
        let command = CodexRegistrar.connectCommand(for: machine)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        banner = Banner(kind: .info, message: "Copied: \(command)")
    }

    func copySSHCommand(_ machine: Machine) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("ssh \(machine.sshHostAlias)", forType: .string)
        banner = Banner(kind: .info, message: "Copied: ssh \(machine.sshHostAlias)")
    }

    func revealLogs() {
        NSWorkspace.shared.selectFile(Paths.logsDir.appendingPathComponent("codex-remote.log").path,
                                      inFileViewerRootedAtPath: Paths.logsDir.path)
    }

    // MARK: - Local integration

    var shellIntegrationInstalled: Bool { CodexRegistrar.shellIntegrationInstalled() }

    func installShellIntegration() {
        do {
            try CodexRegistrar.installShellIntegration()
            banner = Banner(kind: .info, message: "Added Codex Remote to ~/.zshrc. Open a new terminal to pick it up.")
        } catch {
            banner = Banner(kind: .error, message: error.localizedDescription)
        }
    }

    var launchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            updateSettings { $0.launchAtLogin = enabled }
        } catch {
            banner = Banner(kind: .error,
                            message: "Could not change the login item: \(error.localizedDescription)")
        }
    }

    func quit() {
        manager.shutdown()
        NSApplication.shared.terminate(nil)
    }
}
