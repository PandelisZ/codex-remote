import Foundation

/// "Bring your own machine": a provider that creates nothing and simply points the rest of
/// the pipeline at a host you already have — a box at a provider Codex Remote does not speak yet,
/// a colo server, a spare Linux desktop.
///
/// It is a real `ComputeProvider`, which is the point: the create/bootstrap/register
/// pipeline above it does not change at all. It also makes the SSH half of Codex Remote testable
/// against a real machine without creating or billing anything.
public struct StaticHostProvider: ComputeProvider {
    public let kind = ProviderKind.existingHost
    public let displayName = "Existing machine (SSH)"

    private let address: String
    private let user: String

    public init(address: String, user: String = "root") {
        self.address = address
        self.user = user
    }

    public static let descriptor = ProviderDescriptor(
        kind: .existingHost,
        displayName: "Existing machine (SSH)",
        blurb: "A Linux box you already have. Codex Remote installs Codex on it and wires it up, but never creates or deletes anything.",
        credentialFields: [
            CredentialField(key: "address", label: "Host",
                            help: "Hostname or IP Codex Remote should SSH to, e.g. 203.0.113.10 or build-box.example.com.",
                            style: .plain),
            CredentialField(key: "user", label: "Login user",
                            help: "SSH user with sudo-free root, or root itself. Defaults to root.",
                            style: .plain, isOptional: true),
            CredentialField(key: "port", label: "SSH port",
                            help: "Defaults to 22.",
                            style: .plain, isOptional: true),
            CredentialField(key: "privateKeyPath", label: "Private key",
                            help: "Path to the key that already authorises you on that host, e.g. ~/.ssh/id_ed25519. Leave blank to use Codex Remote's own key (you must install its public key yourself).",
                            style: .plain, isOptional: true),
        ],
        make: { account, _ in
            guard let address = account.plainFields["address"], !address.isEmpty else {
                throw ProviderError.missingCredential(field: "Host", provider: "Existing machine (SSH)")
            }
            return StaticHostProvider(address: address,
                                      user: account.plainFields["user"].flatMap { $0.isEmpty ? nil : $0 } ?? "root")
        }
    )

    public func verify() async throws -> ProviderIdentity {
        ProviderIdentity(accountLabel: "\(user)@\(address)",
                         detail: "Codex Remote will not create or destroy anything on this host")
    }

    public func capabilities() async throws -> ProviderCapabilities {
        ProviderCapabilities(
            regions: [Region(slug: "self-hosted", name: address)],
            sizes: [InstanceSize(slug: "existing", name: "As provisioned",
                                 vcpus: 0, memoryGB: 0, diskGB: 0)],
            images: [OSImage(slug: "existing", name: "Whatever is installed", family: "debian")],
            recommendedImage: "existing",
            recommendedSize: "existing",
            recommendedRegion: "self-hosted"
        )
    }

    /// Nothing to register: the host already trusts whichever key the user pointed at it.
    public func ensureSSHKey(name: String, publicKey: String) async throws -> String { "" }

    public func createInstance(_ request: InstanceRequest) async throws -> Instance {
        Instance(id: "static:\(address)", name: request.name, state: .running,
                 publicIPv4: address, region: "self-hosted", size: "existing",
                 image: "existing", createdAt: Date(), providerKind: .existingHost)
    }

    public func instance(id: String) async throws -> Instance? {
        Instance(id: id, name: address, state: .running, publicIPv4: address,
                 region: "self-hosted", size: "existing", image: "existing",
                 providerKind: .existingHost)
    }

    public func listInstances() async throws -> [Instance] {
        [try await instance(id: "static:\(address)")].compactMap { $0 }
    }

    /// Refuses to touch the power state — Codex Remote did not create this machine and will not
    /// reboot or shut down something the user runs for other reasons.
    public func power(_ action: PowerAction, instanceID: String) async throws {
        throw ProviderError.unsupported("changing the power state of a machine it did not create",
                                        provider: displayName)
    }

    public func destroyInstance(id: String) async throws {
        throw ProviderError.unsupported("deleting a machine it did not create", provider: displayName)
    }

    public func defaultSSHUser(forImage image: String) -> String { user }
}
