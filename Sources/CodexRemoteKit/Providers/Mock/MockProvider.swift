import Foundation

/// In-memory provider used by the test suite and by `codex-remote --provider mock`, which is
/// how the menu bar UI gets exercised end to end without spending money on real servers.
/// It can also point at an already-running host, so the SSH bootstrap and the Codex
/// registration run for real against a machine you already own.
public final class MockProvider: ComputeProvider, @unchecked Sendable {
    public let kind = ProviderKind.mock
    public let displayName = "Mock provider"

    private let lock = Lock()
    private var instances: [String: Instance] = [:]
    private var keys: [String: String] = [:]
    private var counter = 0

    /// When set, every created instance reports this address, so the rest of the pipeline
    /// talks to a real host over SSH.
    public let fixedAddress: String?
    /// Seconds the fake instance spends in `.provisioning` before flipping to `.running`.
    public let bootDelay: TimeInterval

    public init(fixedAddress: String? = nil, bootDelay: TimeInterval = 0) {
        self.fixedAddress = fixedAddress
        self.bootDelay = bootDelay
    }

    public static func descriptor(fixedAddress: String? = nil) -> ProviderDescriptor {
        ProviderDescriptor(
            kind: .mock,
            displayName: "Mock provider",
            blurb: "Fake cloud for testing. Creates no real servers.",
            credentialFields: [
                CredentialField(key: "address", label: "Existing host address",
                                help: "Optional. Point the mock at a host you already own to test the SSH bootstrap for real.",
                                style: .plain, environmentVariable: "CODEX_REMOTE_MOCK_ADDRESS", isOptional: true),
            ],
            make: { account, _ in
                MockProvider(fixedAddress: account.plainFields["address"] ?? fixedAddress)
            }
        )
    }

    public func verify() async throws -> ProviderIdentity {
        ProviderIdentity(accountLabel: "Mock account",
                         detail: fixedAddress.map { "bound to \($0)" } ?? "no real servers are created")
    }

    public func capabilities() async throws -> ProviderCapabilities {
        ProviderCapabilities(
            regions: [Region(slug: "local-1", name: "Local zone 1", country: "XX"),
                      Region(slug: "local-2", name: "Local zone 2", country: "XX")],
            sizes: [
                InstanceSize(slug: "small", name: "Small", vcpus: 2, memoryGB: 4, diskGB: 40,
                             monthlyPrice: 0, currency: "USD"),
                InstanceSize(slug: "large", name: "Large", vcpus: 8, memoryGB: 32, diskGB: 160,
                             monthlyPrice: 0, currency: "USD"),
            ],
            images: [OSImage(slug: "ubuntu-24.04", name: "Ubuntu 24.04", family: "ubuntu")],
            recommendedImage: "ubuntu-24.04",
            recommendedSize: "small",
            recommendedRegion: "local-1"
        )
    }

    public func ensureSSHKey(name: String, publicKey: String) async throws -> String {
        lock.lock(); defer { lock.unlock() }
        let id = "key-\(abs(publicKey.hashValue))"
        keys[id] = publicKey
        return id
    }

    public func createInstance(_ request: InstanceRequest) async throws -> Instance {
        lock.lock()
        counter += 1
        let id = "mock-\(counter)"
        let instance = Instance(id: id, name: request.name,
                                state: bootDelay > 0 ? .provisioning : .running,
                                publicIPv4: fixedAddress ?? "198.51.100.\(counter % 250 + 1)",
                                region: request.region, size: request.size,
                                image: request.image, createdAt: Date(), providerKind: .mock)
        instances[id] = instance
        lock.unlock()

        if bootDelay > 0 {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(self?.bootDelay ?? 0) * 1_000_000_000)
                self?.transition(id: id, to: .running)
            }
        }
        return instance
    }

    public func instance(id: String) async throws -> Instance? {
        lock.lock(); defer { lock.unlock() }
        return instances[id]
    }

    public func listInstances() async throws -> [Instance] {
        lock.lock(); defer { lock.unlock() }
        return Array(instances.values).sorted { $0.id < $1.id }
    }

    public func power(_ action: PowerAction, instanceID: String) async throws {
        switch action {
        case .start: transition(id: instanceID, to: .running)
        case .stop: transition(id: instanceID, to: .stopped)
        case .reboot: transition(id: instanceID, to: .running)
        }
    }

    public func destroyInstance(id: String) async throws {
        lock.lock(); defer { lock.unlock() }
        instances[id] = nil
    }

    private func transition(id: String, to state: InstanceState) {
        lock.lock(); defer { lock.unlock() }
        guard let current = instances[id] else { return }
        instances[id] = Instance(id: current.id, name: current.name, state: state,
                                 publicIPv4: current.publicIPv4, publicIPv6: current.publicIPv6,
                                 privateIPv4: current.privateIPv4, region: current.region,
                                 size: current.size, image: current.image,
                                 createdAt: current.createdAt, providerKind: .mock,
                                 metadata: current.metadata)
    }
}
