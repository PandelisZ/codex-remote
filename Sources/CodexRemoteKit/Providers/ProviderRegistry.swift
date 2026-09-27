import Foundation

/// The list of clouds Codex Remote knows how to drive. Adding one is a single `register` call.
public final class ProviderRegistry: @unchecked Sendable {
    public static let shared = ProviderRegistry()

    private let lock = Lock()
    private var descriptors: [ProviderKind: ProviderDescriptor] = [:]
    private var order: [ProviderKind] = []

    private init() {
        // Every cloud is provisioned through OpenTofu. Where Codex Remote also has a native API
        // client for the same cloud it is passed in as a runtime delegate: OpenTofu models
        // no power state and needs a provider plugin downloaded before it can answer
        // anything, so pausing, status polling and the New machine form still go through
        // the API. OpenTofu owns the lifecycle; the API owns the rest.
        register(TofuRegistration.descriptor(for: .hetzner) { _, secrets in
            guard let token = secrets["token"] else {
                throw ProviderError.missingCredential(field: "API token", provider: "Hetzner Cloud")
            }
            return HetznerProvider(token: token)
        })
        register(TofuRegistration.descriptor(for: .digitalOcean) { _, secrets in
            guard let token = secrets["token"] else {
                throw ProviderError.missingCredential(field: "Personal access token", provider: "DigitalOcean")
            }
            return DigitalOceanProvider(token: token)
        })
        register(TofuRegistration.descriptor(for: .awsEC2) { account, secrets in
            guard let key = secrets["accessKeyID"], let secret = secrets["secretAccessKey"] else {
                throw ProviderError.missingCredential(field: "Access key", provider: "Amazon EC2")
            }
            let region = account.plainFields["region"]
                ?? ProcessInfo.processInfo.environment["AWS_REGION"] ?? "us-east-1"
            return AWSProvider(accessKeyID: key.raw, secretAccessKey: secret,
                               sessionToken: secrets["sessionToken"]?.raw, region: region)
        })

        // Clouds Codex Remote reaches only through OpenTofu. They can be created and destroyed
        // but not paused, and their catalogue comes from the provider's data sources.
        register(TofuRegistration.descriptor(for: .linode))
        register(TofuRegistration.descriptor(for: .vultr))
        register(TofuRegistration.descriptor(for: .scaleway))

        // Not a cloud at all: a machine the user already owns.
        register(StaticHostProvider.descriptor)
    }

    public func register(_ descriptor: ProviderDescriptor) {
        lock.lock(); defer { lock.unlock() }
        if descriptors[descriptor.kind] == nil { order.append(descriptor.kind) }
        descriptors[descriptor.kind] = descriptor
    }

    public var all: [ProviderDescriptor] {
        lock.lock(); defer { lock.unlock() }
        return order.compactMap { descriptors[$0] }
    }

    public func descriptor(for kind: ProviderKind) -> ProviderDescriptor? {
        lock.lock(); defer { lock.unlock() }
        return descriptors[kind]
    }

    /// Resolves an account's secrets out of the credential store and builds the provider.
    public func provider(for account: ProviderAccount, credentials: CredentialStore) throws -> ComputeProvider {
        guard let descriptor = descriptor(for: account.kind) else {
            throw ProviderError.unsupported("this provider", provider: account.kind.rawValue)
        }
        var secrets: [String: Secret] = [:]
        for field in descriptor.credentialFields where field.style == .secret {
            // The environment comes first on purpose. It is what CI and a shell that
            // already exports HCLOUD_TOKEN use, it needs no unlock, and it avoids the
            // macOS keychain prompt that otherwise blocks a headless run indefinitely
            // whenever the reading binary's signature has changed.
            if let envName = field.environmentVariable,
               let value = LoginShellEnvironment.shared.value(
                   for: envName, allowed: LoginShellEnvironment.declaredVariables(self)),
               !value.isEmpty {
                secrets[field.key] = Secret(value)
                continue
            }
            if let value = try credentials.read(account.keychainAccount(for: field.key)), !value.isEmpty {
                secrets[field.key] = value
            } else if !field.isOptional {
                throw ProviderError.missingCredential(field: field.label, provider: descriptor.displayName)
            }
        }
        return try descriptor.make(account, secrets)
    }
}
