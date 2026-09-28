import SwiftUI
import CodexRemoteKit

/// The "new machine" form. Regions, sizes and images all come from the provider's own
/// capabilities call, so the form is identical for every cloud and needs no per-provider UI.
struct NewMachineSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var accountID: UUID?
    @State private var name = ""
    @State private var region = ""
    @State private var size = ""
    @State private var image = ""
    @State private var workspace = ""
    @State private var syncCredentials = true
    @State private var agents: Set<AgentKind> = Set(AgentKind.allCases)
    @State private var syncMCP = true
    @State private var idleShutdown = 0
    @State private var extraPackages = ""
    @State private var postSetup = ""

    @State private var capabilities: ProviderCapabilities?
    @State private var loadingCapabilities = false
    @State private var capabilityError: String?

    private var account: ProviderAccount? {
        state.accounts.first { $0.id == accountID }
    }

    private var isExistingHost: Bool { account?.kind == .existingHost }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    Picker("Provider", selection: Binding(
                        get: { accountID ?? state.accounts.first?.id },
                        set: { accountID = $0; Task { await loadCapabilities() } }
                    )) {
                        ForEach(state.accounts) { account in
                            Text("\(account.label)  ·  \(account.kind.rawValue)").tag(Optional(account.id))
                        }
                    }

                    TextField("Name", text: $name, prompt: Text("e.g. codex-eu"))
                        .help("Becomes the SSH alias codex-remote-<name> and the launcher name.")
                }

                if !isExistingHost {
                    Section("Server") {
                        if loadingCapabilities {
                            HStack(spacing: Theme.Space.snug) {
                                ProgressView().controlSize(.small)
                                Text("Reading regions and sizes from \(account?.kind.rawValue ?? "the provider")…")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        } else if let capabilityError {
                            Label {
                                Text(capabilityError)
                                    .font(.caption)
                                    .fixedSize(horizontal: false, vertical: true)
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill")
                            }
                            .foregroundStyle(.red)
                        } else if let capabilities {
                            Picker("Region", selection: $region) {
                                ForEach(capabilities.regions) { item in
                                    Text("\(item.name)  (\(item.slug))").tag(item.slug)
                                }
                            }
                            // EC2 alone re-reads the catalogue: its image ids are
                            // region-scoped, so the list on screen would otherwise offer
                            // AMIs that do not exist where the machine is going.
                            .onChange(of: region) {
                                if account?.kind.catalogueVariesByRegion == true {
                                    Task { await loadCapabilities() }
                                } else {
                                    reconcileSelections()
                                }
                            }

                            let offered = capabilities.sizes(in: region)
                            if offered.isEmpty {
                                Text("\(account?.kind.rawValue ?? "This provider") has nothing in stock in \(region) right now. Pick another region.")
                                    .font(.caption).foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                Picker("Size", selection: $size) {
                                    ForEach(offered) { item in
                                        Text("\(item.slug)  ·  \(item.summary)"
                                             + (item.architecture == "arm" ? "  · ARM" : ""))
                                            .tag(item.slug)
                                    }
                                }
                                .onChange(of: size) { reconcileSelections() }

                                Picker("Image", selection: $image) {
                                    ForEach(capabilities.images(for: size)) { item in
                                        Text(item.name).tag(item.slug)
                                    }
                                }
                            }
                        }
                    }
                }

                Section {
                    ForEach(AgentKind.allCases) { agent in
                        Toggle(isOn: Binding(
                            get: { agents.contains(agent) },
                            set: { on in
                                if on { agents.insert(agent) } else { agents.remove(agent) }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                                Label(agent.displayName, systemImage: agent.symbol)
                                Text(agent.blurb)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                } header: {
                    Text("Agents")
                } footer: {
                    if agents.contains(.claudeCode) {
                        Text("Claude Code needs a one-off browser sign-in on the machine once it is up. Codex Remote will prompt you.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section("Options") {
                        TextField("Workspace path", text: $workspace,
                                  prompt: Text(state.settings.defaultWorkspacePath))
                            .help("Directory new Codex tasks start in on the machine.")

                        if agents.contains(.codex) {
                            Toggle("Copy this Mac's Codex credentials", isOn: $syncCredentials)
                                .help("Copies ~/.codex/auth.json so the remote agent can reach the model API. Turn this off to run `codex login` on the machine instead.")
                        }

                        Toggle(isOn: $syncMCP) {
                            VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                                Text("Carry over my MCP servers")
                                Text("Remote servers and their logins travel; Mac-only ones are left behind and listed.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        if !isExistingHost {
                            Picker("Idle shutdown", selection: $idleShutdown) {
                                Text("Never").tag(0)
                                Text("After 30 minutes").tag(30)
                                Text("After 1 hour").tag(60)
                                Text("After 3 hours").tag(180)
                            }
                            .help("Powers the server off when nothing is connected, so an idle box stops costing money.")
                        }

                        TextField("Extra apt packages", text: $extraPackages,
                                  prompt: Text("golang-go postgresql-client"))
                            .help("Space-separated, installed during bootstrap.")

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Post-setup script").font(.caption).foregroundStyle(.secondary)
                            TextEditor(text: $postSetup)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(height: 70)
                                .overlay(RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.secondary.opacity(0.3)))
                            Text("Runs as root in the workspace at the end of setup — clone repos, install toolchains, drop in dotfiles.")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                }
            }
            .formStyle(.grouped)
            .softScrollEdges()

            Divider()

            HStack(spacing: Theme.Space.normal) {
                if !isExistingHost, let size = capabilities?.sizes.first(where: { $0.slug == self.size }),
                   let price = size.monthlyPrice, price > 0 {
                    Label {
                        Text(String(format: "About %@%.2f a month while it runs",
                                    size.currency == "EUR" ? "€" : "$", price))
                    } icon: {
                        Image(systemName: "creditcard")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
                    .help(canCreate ? "Build this machine"
                                    : "Pick a provider and give the machine a name first")
            }
            .padding(.horizontal, Theme.Space.gutter + Theme.Space.tight)
            .padding(.vertical, Theme.Space.roomy)
        }
        .frame(width: 500, height: 580)
        .navigationTitle("New machine")
        .task {
            accountID = accountID ?? state.accounts.first?.id
            workspace = state.settings.defaultWorkspacePath
            await loadCapabilities()
        }
    }

    private var canCreate: Bool {
        guard accountID != nil, !agents.isEmpty,
              !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if isExistingHost { return true }
        return !region.isEmpty && !size.isEmpty && !image.isEmpty
    }

    /// Keeps size and image legal after a region or size change: a type that is not
    /// stocked in the new region, or an image built for the wrong architecture, is
    /// rejected at create time, so the form never leaves one selected.
    private func reconcileSelections() {
        guard let capabilities else { return }
        let offered = capabilities.sizes(in: region)
        if !offered.contains(where: { $0.slug == size }) {
            size = offered.first(where: { $0.vcpus >= 2 && $0.memoryGB >= 4 })?.slug
                ?? offered.first?.slug ?? size
        }
        let usable = capabilities.images(for: size)
        if !usable.contains(where: { $0.slug == image }) {
            image = capabilities.recommendedImage(for: size)
        }
    }

    private func loadCapabilities() async {
        guard let accountID else { return }
        loadingCapabilities = true
        capabilityError = nil
        defer { loadingCapabilities = false }
        do {
            // Scoped to the region already chosen, so an EC2 image id belongs to the
            // region the machine will actually be created in.
            let result = try await state.capabilities(
                for: accountID, region: region.isEmpty ? nil : region)
            capabilities = result
            if region.isEmpty || !result.regions.contains(where: { $0.slug == region }) {
                region = result.recommendedRegion
            }
            if size.isEmpty || !result.sizes.contains(where: { $0.slug == size }) {
                size = result.recommendedSize
            }
            reconcileSelections()
            if image.isEmpty { image = result.recommendedImage(for: size) }
        } catch {
            capabilityError = error.localizedDescription
        }
    }

    private func create() {
        guard let account else { return }
        let spec = MachineSpec(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            accountID: account.id,
            providerKind: account.kind,
            region: isExistingHost ? "self-hosted" : region,
            size: isExistingHost ? "existing" : size,
            image: isExistingHost ? "existing" : image,
            workspacePath: workspace.isEmpty ? state.settings.defaultWorkspacePath : workspace,
            agents: agents,
            syncCodexCredentials: syncCredentials,
            syncMCPServers: syncMCP,
            extraPackages: extraPackages.split(separator: " ").map(String.init),
            postSetupScript: postSetup.isEmpty ? nil : postSetup,
            idleShutdownMinutes: idleShutdown
        )
        state.createMachine(spec)
        dismiss()
    }
}
