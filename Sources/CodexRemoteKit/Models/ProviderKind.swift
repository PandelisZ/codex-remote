import Foundation

/// Identifies a provider implementation. Adding a cloud means adding a case here,
/// a `ComputeProvider` conformance, and one line in `ProviderRegistry`.
public struct ProviderKind: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public static let hetzner = ProviderKind("hetzner")
    public static let digitalOcean = ProviderKind("digitalocean")
    public static let aws = ProviderKind("aws")
    public static let linode = ProviderKind("linode")
    public static let vultr = ProviderKind("vultr")
    public static let scaleway = ProviderKind("scaleway")
    public static let existingHost = ProviderKind("existing-host")
    public static let mock = ProviderKind("mock")
}

/// One credential input a provider needs, described well enough that the settings
/// window can render the form without knowing anything about the provider.
public struct CredentialField: Codable, Hashable, Sendable, Identifiable {
    public enum Style: String, Codable, Sendable { case secret, plain }

    public var id: String { key }
    public let key: String
    public let label: String
    public let help: String
    public let style: Style
    public let environmentVariable: String?
    public let isOptional: Bool

    public init(key: String, label: String, help: String, style: Style = .secret,
                environmentVariable: String? = nil, isOptional: Bool = false) {
        self.key = key
        self.label = label
        self.help = help
        self.style = style
        self.environmentVariable = environmentVariable
        self.isOptional = isOptional
    }
}

/// Who the token belongs to, shown in the UI after a successful credential check.
public struct ProviderIdentity: Codable, Hashable, Sendable {
    public let accountLabel: String
    public let detail: String?

    public init(accountLabel: String, detail: String? = nil) {
        self.accountLabel = accountLabel
        self.detail = detail
    }
}

/// A saved provider login. Secret values are in the keychain under `\(id.uuidString).\(fieldKey)`;
/// only non-secret fields (a region, an account id) are stored inline.
public struct ProviderAccount: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var kind: ProviderKind
    public var label: String
    public var plainFields: [String: String]
    public var verifiedIdentity: ProviderIdentity?
    public var createdAt: Date

    public init(id: UUID = UUID(), kind: ProviderKind, label: String,
                plainFields: [String: String] = [:],
                verifiedIdentity: ProviderIdentity? = nil,
                createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.label = label
        self.plainFields = plainFields
        self.verifiedIdentity = verifiedIdentity
        self.createdAt = createdAt
    }

    /// Tolerant of fields added later — see `MachineSpec.init(from:)`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(ProviderKind.self, forKey: .kind)
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? kind.rawValue
        plainFields = try container.decodeIfPresent([String: String].self, forKey: .plainFields) ?? [:]
        verifiedIdentity = try container.decodeIfPresent(ProviderIdentity.self, forKey: .verifiedIdentity)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    public func keychainAccount(for fieldKey: String) -> String {
        "\(id.uuidString).\(fieldKey)"
    }
}
