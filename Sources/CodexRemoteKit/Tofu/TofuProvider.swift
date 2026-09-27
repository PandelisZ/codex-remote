import Foundation

/// A `ComputeProvider` whose create and destroy run through OpenTofu.
///
/// Everything above it — the SSH bootstrap, the tunnel, the Codex registration — is
/// unchanged; this only swaps out how the server comes into existence. Each machine gets
/// its own workspace under `~/.codex-remote/tofu/machines/<id>/`, so one machine's state
/// can never disturb another's.
///
/// Where Codex Remote already has a native API client for the same cloud, that client is kept as
/// a **runtime delegate**. OpenTofu is declarative and models no power state, so pausing
/// and resuming — and fast status polling, and populating the New machine form without
/// waiting on a provider plugin download — still go through the API. OpenTofu owns the
/// lifecycle; the API owns what happens between creation and destruction.
public struct TofuProvider: ComputeProvider {
    public let kind: ProviderKind
    public var displayName: String { module.displayName }

    private let module: TofuModule
    private let environment: [String: String]
    /// Native client for the same cloud, when Codex Remote has one.
    private let runtime: ComputeProvider?
    private let runner: TofuRunner

    public init(module: TofuModule,
                account: ProviderAccount,
                secrets: [String: Secret],
                runtime: ComputeProvider? = nil,
                runner: TofuRunner = .shared) {
        self.kind = module.kind
        self.module = module
        self.environment = module.environment(account.plainFields, secrets)
        self.runtime = runtime
        self.runner = runner
    }

    // MARK: - Credentials and catalogue

    public func verify() async throws -> ProviderIdentity {
        if let runtime { return try await runtime.verify() }

        // With no API client for this cloud, the credential check is a catalogue read —
        // it exercises the same provider and the same token without creating anything.
        guard module.catalogConfiguration() != nil else {
            let missing = module.credentialFields
                .filter { !$0.isOptional && (environment[$0.environmentVariable ?? ""] ?? "").isEmpty }
            guard missing.isEmpty else {
                throw ProviderError.missingCredential(field: missing[0].label, provider: displayName)
            }
            return ProviderIdentity(accountLabel: module.displayName,
                                    detail: "credentials are checked on the first machine")
        }
        _ = try await catalogOutputs()
        return ProviderIdentity(accountLabel: module.displayName, detail: "verified through OpenTofu")
    }

    public func capabilities() async throws -> ProviderCapabilities {
        // Prefer the API client: opening the New machine form should not wait on a
        // provider plugin download.
        if let runtime, let live = try? await runtime.capabilities() { return live }

        if module.catalogConfiguration() != nil, let parse = module.parseCatalog {
            do {
                if let parsed = parse(try await catalogOutputs()) { return parsed }
            } catch {
                Log.shared.warn("tofu", "\(displayName): catalogue read failed (\(error.localizedDescription)); using the built-in list.")
            }
        }
        return module.fallbackCapabilities()
    }

    private func catalogOutputs() async throws -> [String: Any] {
        guard let configuration = module.catalogConfiguration() else { return [:] }
        let workdir = runner.catalogDir.appendingPathComponent(kind.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
        try configuration.write(to: workdir.appendingPathComponent("main.tf"),
                                atomically: true, encoding: .utf8)
        try await runner.initialize(workdir: workdir, environment: environment)
        // Data sources have to be read into state before `output` can see them. Nothing
        // is created: the configuration has no resources.
        try await runner.apply(workdir: workdir, environment: environment, timeout: 600)
        return try await runner.outputs(workdir: workdir, environment: environment)
    }

    // MARK: - SSH keys

    public func ensureSSHKey(name: String, publicKey: String) async throws -> String {
        // A module that declares its own key resource takes the public key as a variable,
        // so there is nothing to pre-register.
        guard !module.managesSSHKey else { return "" }
        guard let runtime else {
            throw ProviderError.unsupported("registering an SSH key without an API client",
                                            provider: displayName)
        }
        return try await runtime.ensureSSHKey(name: name, publicKey: publicKey)
    }

    // MARK: - Lifecycle

    public func createInstance(_ request: InstanceRequest) async throws -> Instance {
        let workdir = workspace(for: request.workspaceKey)
        try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
        try module.machineConfiguration().write(to: workdir.appendingPathComponent("main.tf"),
                                                atomically: true, encoding: .utf8)

        let keyPair = try await SSHKeyManager.ensureKeyPair()
        try TofuVariables(request: request, sshPublicKey: keyPair.publicKey)
            .write(to: workdir, extra: module.extraVariables(request))

        try await runner.initialize(workdir: workdir, environment: environment)
        try await runner.apply(workdir: workdir, environment: environment)

        let outputs = try await runner.outputs(workdir: workdir, environment: environment)
        guard let instance = instance(from: outputs, workspaceKey: request.workspaceKey,
                                      fallbackName: request.name,
                                      region: request.region, size: request.size,
                                      image: request.image) else {
            throw ProviderError.creationFailed(
                "OpenTofu applied cleanly but the \(displayName) module produced no instance outputs.")
        }
        Log.shared.info("tofu", "\(displayName): created \(instance.name) (\(instance.id)) at \(instance.sshAddress ?? "no address").")
        return instance
    }

    public func instance(id: String) async throws -> Instance? {
        // The API client answers this far faster than a state refresh, and the pipeline
        // polls it while a machine boots.
        if let runtime, let live = try? await runtime.instance(id: providerSideID(for: id) ?? id),
           live != nil {
            return live
        }
        let workdir = workspace(for: id)
        guard runner.hasState(workdir: workdir) else { return nil }
        let outputs = try await runner.outputs(workdir: workdir, environment: environment)
        return instance(from: outputs, workspaceKey: id, fallbackName: id,
                        region: "unknown", size: "unknown", image: nil)
    }

    public func listInstances() async throws -> [Instance] {
        if let runtime { return try await runtime.listInstances() }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: runner.machinesDir, includingPropertiesForKeys: nil)) ?? []
        var found: [Instance] = []
        for directory in contents where runner.hasState(workdir: directory) {
            if let instance = try? await instance(id: directory.lastPathComponent) {
                found.append(instance)
            }
        }
        return found
    }

    public func power(_ action: PowerAction, instanceID: String) async throws {
        // OpenTofu describes what should exist, not whether it is switched on, so this is
        // the one operation that genuinely needs the cloud's own API.
        guard let runtime else {
            throw ProviderError.unsupported("""
            pausing a machine on \(displayName). OpenTofu describes what should exist, not \
            whether it is running, and Codex Remote has no direct API client for this cloud yet — \
            so it can create and destroy machines here, but not power them off and on
            """, provider: displayName)
        }
        try await runtime.power(action, instanceID: providerSideID(for: instanceID) ?? instanceID)
    }

    public func destroyInstance(id: String) async throws {
        let workdir = workspace(for: id)
        guard runner.hasState(workdir: workdir) else {
            // Created before the OpenTofu backend, or already torn down — fall back to the
            // API client so "delete the server" still means what it says.
            if let runtime { try await runtime.destroyInstance(id: id) }
            return
        }
        try await runner.destroy(workdir: workdir, environment: environment)
        try? FileManager.default.removeItem(at: workdir)
        Log.shared.info("tofu", "\(displayName): destroyed the machine in workspace \(id).")
    }

    public func defaultSSHUser(forImage image: String) -> String { module.sshUser }

    // MARK: - Helpers

    private func workspace(for key: String) -> URL {
        runner.machinesDir.appendingPathComponent(key, isDirectory: true)
    }

    /// The cloud's own id for a machine, read from its workspace outputs — needed when
    /// handing work to the API client, which knows nothing about workspaces.
    private func providerSideID(for workspaceKey: String) -> String? {
        let workdir = workspace(for: workspaceKey)
        guard runner.hasState(workdir: workdir),
              let cached = try? String(contentsOf: workdir.appendingPathComponent("instance-id"),
                                       encoding: .utf8) else { return nil }
        let trimmed = cached.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func instance(from outputs: [String: Any], workspaceKey: String,
                          fallbackName: String, region: String, size: String,
                          image: String?) -> Instance? {
        func string(_ key: String) -> String? {
            guard let value = outputs[key] else { return nil }
            if let text = value as? String { return text.isEmpty ? nil : text }
            if let number = value as? NSNumber { return number.stringValue }
            return nil
        }
        guard let providerID = string("instance_id") else { return nil }

        // Remember the cloud's id so power and status can be handed to the API client.
        let workdir = workspace(for: workspaceKey)
        try? providerID.write(to: workdir.appendingPathComponent("instance-id"),
                             atomically: true, encoding: .utf8)

        return Instance(
            id: workspaceKey,
            name: string("instance_name") ?? fallbackName,
            // `tofu apply` does not return until the cloud reports the machine up, so by
            // the time outputs exist it is running.
            state: Self.mapState(string("state")),
            publicIPv4: string("public_ipv4"),
            publicIPv6: string("public_ipv6"),
            privateIPv4: string("private_ipv4"),
            region: string("region") ?? region,
            size: string("size") ?? size,
            image: string("image") ?? image,
            createdAt: Date(),
            providerKind: kind,
            metadata: ["provider_instance_id": providerID, "engine": "opentofu"]
        )
    }

    static func mapState(_ raw: String?) -> InstanceState {
        switch (raw ?? "").lowercased() {
        case "", "running", "active", "ok", "started", "on": return .running
        case "off", "stopped", "shutoff", "halted": return .stopped
        case "initializing", "starting", "provisioning", "new", "pending", "creating": return .provisioning
        case "stopping", "shutting-down": return .stopping
        case "deleting", "terminating": return .deleting
        case "deleted", "terminated": return .deleted
        default: return .running
        }
    }
}
