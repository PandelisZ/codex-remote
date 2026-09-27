import Foundation

public enum ProviderError: LocalizedError {
    case missingCredential(field: String, provider: String)
    case unsupported(String, provider: String)
    case instanceNotFound(String)
    case creationFailed(String)
    case timeout(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredential(let field, let provider):
            return "\(provider) needs a value for \(field). Add it in Codex Remote → Settings → Providers."
        case .unsupported(let what, let provider):
            return "\(provider) does not support \(what)."
        case .instanceNotFound(let id):
            return "The provider no longer knows about instance \(id). It may have been deleted outside Codex Remote."
        case .creationFailed(let detail):
            return "Could not create the server: \(detail)"
        case .timeout(let detail):
            return "Timed out: \(detail)"
        }
    }
}

/// The whole provider surface Codex Remote needs. Everything above this protocol — the
/// provisioning pipeline, the SSH bootstrap, the Codex registration, the menu bar —
/// is provider-agnostic, so a new cloud is this protocol plus a registry entry.
public protocol ComputeProvider: Sendable {
    var kind: ProviderKind { get }
    var displayName: String { get }

    /// Confirms the credentials work and says whose account they are.
    func verify() async throws -> ProviderIdentity

    /// Regions, machine sizes and images, for the "New machine" form.
    func capabilities() async throws -> ProviderCapabilities

    /// Registers `publicKey` with the provider (idempotent) and returns the provider-side id
    /// to pass in `InstanceRequest.sshKeyIdentifiers`.
    func ensureSSHKey(name: String, publicKey: String) async throws -> String

    func createInstance(_ request: InstanceRequest) async throws -> Instance
    func instance(id: String) async throws -> Instance?
    func listInstances() async throws -> [Instance]
    func power(_ action: PowerAction, instanceID: String) async throws
    func destroyInstance(id: String) async throws

    /// Login name on the provider's stock image for this OS family.
    func defaultSSHUser(forImage image: String) -> String
}

public extension ComputeProvider {
    func defaultSSHUser(forImage image: String) -> String { "root" }

    /// Generic create-then-poll. Providers rarely need to override this.
    func waitForRunningInstance(
        id: String,
        timeout: TimeInterval = 300,
        onPoll: ((Instance) -> Void)? = nil
    ) async throws -> Instance {
        let deadline = Date().addingTimeInterval(timeout)
        var delay: UInt64 = 2_000_000_000
        while Date() < deadline {
            guard let current = try await instance(id: id) else {
                throw ProviderError.instanceNotFound(id)
            }
            onPoll?(current)
            if current.state == .running, current.sshAddress != nil { return current }
            if current.state == .deleted {
                throw ProviderError.creationFailed("The provider deleted instance \(id) while it was booting.")
            }
            try await Task.sleep(nanoseconds: delay)
            delay = min(delay + 1_000_000_000, 6_000_000_000)
        }
        throw ProviderError.timeout("instance \(id) did not reach a running state with an IP within \(Int(timeout))s")
    }
}

/// Static description of a provider, available before any credentials exist — this is what
/// the settings UI enumerates when the user goes to add an account.
public struct ProviderDescriptor: Sendable, Identifiable {
    public var id: String { kind.rawValue }
    public let kind: ProviderKind
    public let displayName: String
    public let blurb: String
    public let credentialFields: [CredentialField]
    public let tokenHelpURL: String?
    /// Builds a live provider from an account plus its resolved secrets.
    public let make: @Sendable (ProviderAccount, [String: Secret]) throws -> ComputeProvider

    public init(kind: ProviderKind, displayName: String, blurb: String,
                credentialFields: [CredentialField], tokenHelpURL: String? = nil,
                make: @escaping @Sendable (ProviderAccount, [String: Secret]) throws -> ComputeProvider) {
        self.kind = kind
        self.displayName = displayName
        self.blurb = blurb
        self.credentialFields = credentialFields
        self.tokenHelpURL = tokenHelpURL
        self.make = make
    }
}
