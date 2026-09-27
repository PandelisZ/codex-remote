import SwiftUI
import CodexRemoteKit

struct SettingsView: View {
    private enum Pane: Hashable { case providers, general }
    @State private var pane: Pane = .providers

    var body: some View {
        TabView(selection: $pane) {
            Tab("Providers", systemImage: "cloud", value: Pane.providers) {
                ProviderSettings()
            }
            Tab("General", systemImage: "gearshape", value: Pane.general) {
                GeneralSettings()
            }
        }
        // macOS settings windows size to their content rather than being resized by hand.
        .frame(width: 580, height: 460)
    }
}

// MARK: - Providers

struct ProviderSettings: View {
    @EnvironmentObject private var state: AppState
    @State private var addingKind: ProviderKind?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if state.accounts.isEmpty {
                VStack(spacing: 8) {
                    Text("No provider accounts").font(.headline)
                    Text("Codex Remote needs an API token to create machines for you. Everything is stored in your login keychain — nothing leaves this Mac except calls to the provider itself.")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 40).padding(.vertical, 24)
            } else {
                Form {
                    Section {
                        ForEach(state.accounts) { account in
                            accountRow(account)
                        }
                    } header: {
                        Text("Accounts")
                    } footer: {
                        Text("Tokens are kept in your login keychain, and picked up from your shell if you export them there. They are never written into Codex Remote's files or into OpenTofu's state.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    RegistrySection()
                        .environmentObject(state)
                }
                .formStyle(.grouped)
                .softScrollEdges()
            }

            Divider()
            HStack {
                Menu {
                    ForEach(ProviderRegistry.shared.all) { descriptor in
                        Button(descriptor.displayName) { addingKind = descriptor.kind }
                    }
                } label: {
                    Label("Add account", systemImage: "plus")
                }
                .fixedSize()
                Spacer()
            }
            .padding(12)
        }
        .sheet(item: $addingKind) { kind in
            AddAccountSheet(kind: kind).environmentObject(state)
        }
    }

    @ViewBuilder
    private func accountRow(_ account: ProviderAccount) -> some View {
        HStack(spacing: Theme.Space.normal) {
            Image(systemName: symbol(for: account.kind))
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                Text(account.label).font(.body.weight(.medium))
                Text(detail(for: account))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: Theme.Space.normal)

            Text("\(machineCount(account)) machine\(machineCount(account) == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()

            Button(role: .destructive) {
                state.removeAccount(account)
            } label: {
                Image(systemName: "trash")
                    .frame(width: Theme.minimumHitTarget, height: Theme.minimumHitTarget)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .disabled(machineCount(account) > 0)
            .help(machineCount(account) > 0
                  ? "Delete this account's machines first"
                  : "Forget this account and its token")
            .accessibilityLabel("Remove \(account.label)")
        }
        .padding(.vertical, Theme.Space.tight)
    }

    private func machineCount(_ account: ProviderAccount) -> Int {
        state.machines.filter { $0.spec.accountID == account.id }.count
    }

    private func detail(for account: ProviderAccount) -> String {
        var parts = [account.kind.rawValue]
        if let identity = account.verifiedIdentity {
            parts.append(identity.accountLabel)
            if let extra = identity.detail { parts.append(extra) }
        }
        return parts.joined(separator: " · ")
    }

    private func symbol(for kind: ProviderKind) -> String {
        switch kind {
        case .hetzner: return "server.rack"
        case .digitalOcean: return "drop.fill"
        case .aws: return "cube.box"
        case .existingHost: return "desktopcomputer"
        default: return "cloud"
        }
    }
}

extension ProviderKind: @retroactive Identifiable {
    public var id: String { rawValue }
}

struct AddAccountSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let kind: ProviderKind

    @State private var label = ""
    @State private var values: [String: String] = [:]
    @State private var verifying = false
    @State private var error: String?

    private var descriptor: ProviderDescriptor? { ProviderRegistry.shared.descriptor(for: kind) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(descriptor?.displayName ?? kind.rawValue).font(.title3.weight(.semibold))
                Text(descriptor?.blurb ?? "")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)

            Form {
                TextField("Label", text: $label, prompt: Text(descriptor?.displayName ?? ""))
                    .help("Just a name for you — useful when you have more than one account.")

                ForEach(descriptor?.credentialFields ?? []) { field in
                    VStack(alignment: .leading, spacing: 3) {
                        if field.style == .secret {
                            SecureField(field.label, text: binding(field.key))
                        } else {
                            TextField(field.label, text: binding(field.key))
                        }
                        Text(field.help + (field.environmentVariable.map { "  Leave blank to use $\($0)." } ?? ""))
                            .font(.caption2).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if let help = descriptor?.tokenHelpURL, let url = URL(string: help) {
                    Link("Where do I get this?", destination: url).font(.caption)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button(verifying ? "Checking…" : "Add") { Task { await add() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(verifying || !hasRequiredFields)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 460)
    }

    private var hasRequiredFields: Bool {
        (descriptor?.credentialFields ?? []).allSatisfy { field in
            if field.isOptional { return true }
            if !(values[field.key] ?? "").isEmpty { return true }
            // An env var counts: the token may already be exported in the environment.
            if let env = field.environmentVariable,
               !(ProcessInfo.processInfo.environment[env] ?? "").isEmpty { return true }
            return false
        }
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { values[key] ?? "" }, set: { values[key] = $0 })
    }

    private func add() async {
        guard let descriptor else { return }
        verifying = true
        error = nil
        defer { verifying = false }

        var secrets: [String: Secret] = [:]
        var plain: [String: String] = [:]
        for field in descriptor.credentialFields {
            var raw = values[field.key] ?? ""
            if raw.isEmpty, let env = field.environmentVariable {
                raw = ProcessInfo.processInfo.environment[env] ?? ""
            }
            if raw.isEmpty { continue }
            if field.style == .secret { secrets[field.key] = Secret(raw) } else { plain[field.key] = raw }
        }

        let name = label.isEmpty ? descriptor.displayName : label
        // The manager verifies the credentials before it keeps them, so a bad token
        // surfaces here rather than halfway through a provision.
        if await state.addAccount(kind: kind, label: name, secrets: secrets, plainFields: plain) {
            dismiss()
        } else {
            error = state.banner?.message ?? "Could not verify those credentials."
            state.banner = nil
        }
    }
}

// MARK: - General

struct GeneralSettings: View {
    @EnvironmentObject private var state: AppState
    @State private var basePort = ""
    @State private var codexPin = ""
    @State private var workspace = ""
    @State private var pollSeconds = 15.0

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Open Codex Remote at login", isOn: Binding(
                    get: { state.launchAtLoginEnabled },
                    set: { state.setLaunchAtLogin($0) }
                ))
                .help("Tunnels only exist while Codex Remote is running, so machines show as offline until it starts.")
            }

            Section {
                Toggle("Let agents manage machines", isOn: Binding(
                    get: { state.settings.mcpAllowWrites },
                    set: { value in state.updateSettings { $0.mcpAllowWrites = value } }))
                Toggle("Let agents destroy machines", isOn: Binding(
                    get: { state.settings.mcpAllowDestroy },
                    set: { value in state.updateSettings { $0.mcpAllowDestroy = value } }))
                    .disabled(!state.settings.mcpAllowWrites)

                HStack {
                    Button("Copy setup command") {
                        let binary = Bundle.main.url(forAuxiliaryExecutable: "codex-remote")?.path ?? "codex-remote"
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("claude mcp add codex-remote -- \(binary) mcp serve",
                                                       forType: .string)
                        state.banner = AppState.Banner(kind: .info, message: "Copied. Run it in a terminal to connect your agent.")
                    }
                    Spacer()
                }
            } header: {
                Text("Agent access")
            } footer: {
                Text("Codex Remote can run as an MCP server, so an agent can look at your machines — and, if you allow it, build and change them itself. Reading is always available once connected. Changing machines is off by default because these tools spend money on your cloud account, and destroying has its own switch because deleting the right machine is a worse mistake than creating the wrong one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Codex desktop app") {
                if state.codexAppInstalled {
                    Toggle("Add machines to Codex's Remotes", isOn: Binding(
                        get: { state.settings.registerWithCodexApp },
                        set: { value in state.updateSettings { $0.registerWithCodexApp = value } }
                    ))
                    .help("Writes each ready machine into the Codex app's own remote list, with the workspace pre-added as a project.")

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(state.codexAppMachines.isEmpty
                                 ? "No machines registered yet"
                                 : "In Codex: \(state.codexAppMachines.joined(separator: ", "))")
                            Text("Codex re-reads this list when it launches, so a newly added machine appears after you quit and reopen it.")
                                .font(.caption2).foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button("Sync now") { state.syncCodexApp() }
                            .controlSize(.small)
                    }
                } else {
                    Text("The Codex desktop app isn't installed. Machines still work from the terminal with the generated launchers.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Shell") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.shellIntegrationInstalled
                             ? "Shell integration installed"
                             : "Shell integration not installed")
                        Text("Puts `codex-attach` and one launcher per machine on your PATH.")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if !state.shellIntegrationInstalled {
                        Button("Add to ~/.zshrc") { state.installShellIntegration() }
                            .controlSize(.small)
                    }
                }
            }

            Section("Defaults for new machines") {
                TextField("Workspace path", text: $workspace)
                    .onSubmit { state.updateSettings { $0.defaultWorkspacePath = workspace } }
                TextField("Pin Codex version", text: $codexPin, prompt: Text("latest"))
                    .onSubmit {
                        state.updateSettings { $0.codexVersionPin = codexPin.isEmpty ? nil : codexPin }
                    }
                    .help("npm version installed on each machine, e.g. 0.157.0. Blank installs the latest.")
            }

            Section("Networking") {
                TextField("First local port", text: $basePort)
                    .onSubmit {
                        if let value = Int(basePort), value > 1024, value < 65000 {
                            state.updateSettings { $0.basePort = value }
                        }
                    }
                    .help("Each machine gets the next free loopback port from here for its SSH tunnel.")

                LabeledContent("Health check") {
                    VStack(alignment: .trailing, spacing: Theme.Space.hairline) {
                        Slider(value: $pollSeconds, in: 5...120, step: 5) {
                            Text("Health check interval")
                        } onEditingChanged: { editing in
                            if !editing {
                                state.updateSettings { $0.healthPollSeconds = Int(pollSeconds) }
                            }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                        Text("Every \(Int(pollSeconds)) seconds")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }

            Section {
                LabeledContent("Machine registry", value: Paths.machinesFile.path)
                LabeledContent("SSH hosts", value: Paths.sshManagedFile.path)
                LabeledContent("Launchers", value: Paths.binDir.path)
                LabeledContent("SSH key", value: SSHKeyManager.defaultPrivateKeyURL.path)
            } header: {
                Text("On disk")
            } footer: {
                Text("Provider tokens and per-machine app-server tokens are in the login keychain, never in these files.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .task {
            basePort = String(state.settings.basePort)
            codexPin = state.settings.codexVersionPin ?? ""
            workspace = state.settings.defaultWorkspacePath
            pollSeconds = Double(state.settings.healthPollSeconds)
        }
    }
}

/// Where the catalogue of clouds comes from.
///
/// A registry supplies OpenTofu HCL that runs against the credentials you gave it, so
/// switching to a new one is a deliberate act: the URL is checked and summarised before it
/// is saved, and nothing changes until you accept what came back.
struct RegistrySection: View {
    @EnvironmentObject private var state: AppState

    @State private var draft = ""
    @State private var checking = false
    @State private var found: ProviderRegistryDocument?
    @State private var problem: String?
    @State private var loadedNote: String?

    private var official: String { RemoteProviderRegistry.officialURL.absoluteString }
    private var isDirty: Bool { draft != state.settings.providerRegistryURL }

    var body: some View {
        Section {
            TextField("Registry URL", text: $draft, prompt: Text(official))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .onSubmit { Task { await check() } }

            HStack(spacing: Theme.Space.snug) {
                Button("Check") { Task { await check() } }
                    .disabled(checking || draft.trimmingCharacters(in: .whitespaces).isEmpty)
                if isDirty, found != nil {
                    Button("Use this registry") { save() }
                        .buttonStyle(.borderedProminent)
                }
                if draft != official {
                    Button("Reset to official") {
                        draft = official
                        found = nil
                        problem = nil
                    }
                }
                if checking { ProgressView().controlSize(.small) }
                Spacer()
            }

            if let found {
                LabeledContent("Found") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(found.name) — \(found.providers.count) provider\(found.providers.count == 1 ? "" : "s")")
                        Text(found.providers.map(\.displayName).joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let loadedNote {
                Text(loadedNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Registry")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Clouds are data — OpenTofu HCL plus the environment their credentials map onto — so the catalogue is fetched rather than built in. Point this at your own registry for your own providers.")
                Text("A registry supplies HCL that runs against your cloud credentials. Only use one you trust, the same way you would a Terraform module you are about to apply.")
                Link("Registry format", destination: URL(string: "https://github.com/PandelisZ/codex-remote/blob/main/docs/registry.md")!)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .task {
            draft = state.settings.providerRegistryURL
            if let loaded = await RemoteProviderRegistry.shared.cachedDocument() {
                loadedNote = loaded.fromCache
                    ? "Using a cached copy from \(loaded.fetchedAt.formatted(date: .abbreviated, time: .shortened))."
                    : nil
            }
        }
    }

    private func check() async {
        guard let url = URL(string: draft.trimmingCharacters(in: .whitespaces)) else {
            problem = "That is not a URL."
            return
        }
        checking = true
        problem = nil
        found = nil
        do {
            found = try await RemoteProviderRegistry.shared.preview(url)
        } catch {
            problem = error.localizedDescription
        }
        checking = false
    }

    private func save() {
        let url = draft.trimmingCharacters(in: .whitespaces)
        state.updateSettings { $0.providerRegistryURL = url }
        loadedNote = "Saved. New machines can use these providers."
    }
}
