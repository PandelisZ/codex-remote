import Foundation

/// A provider registry: clouds expressed as data, fetched from a URL rather than compiled in.
///
/// The point is that adding a cloud should not need an app release. Everything a provider
/// needs is already data — some OpenTofu HCL, the environment variables its credentials map
/// onto, and the lists that fill the New machine form — so it can live in a JSON file that
/// anyone can host. Point Codex Remote at a different URL and you get a different catalogue:
/// your own homelab module, a provider we have not added yet, or a fork with the exact
/// packages and volumes your team wants baked in.
///
/// The format is documented in `docs/registry.md`, and the official one lives at
/// `https://codexremote.io/registry.json`.
///
/// ## Why this is not a plugin system
///
/// Nothing here executes on your Mac. A registry supplies HCL that OpenTofu runs against
/// the cloud you gave it credentials for, and Codex Remote validates the shape of every
/// entry before it will offer it. That is still a meaningful amount of trust — HCL can
/// create anything the token allows, and it can send outputs anywhere — so a registry is a
/// thing you choose deliberately, and pointing at a new one is a decision the app makes
/// visible rather than a silent background update.
public struct ProviderRegistryDocument: Codable, Sendable, Equatable {
    /// Bumped only for breaking changes. A document from the future is refused rather than
    /// half-understood, because a partly-parsed cloud module is worse than no module.
    public static let supportedFormatVersion = 1

    public let formatVersion: Int
    public let name: String
    public let homepage: String?
    public let updated: String?
    public let providers: [Entry]

    public init(formatVersion: Int = supportedFormatVersion, name: String,
                homepage: String? = nil, updated: String? = nil, providers: [Entry]) {
        self.formatVersion = formatVersion
        self.name = name
        self.homepage = homepage
        self.updated = updated
        self.providers = providers
    }

    // MARK: - One cloud

    public struct Entry: Codable, Sendable, Equatable {
        /// Stable identifier, e.g. `hetzner`. Machines record this, so changing it orphans
        /// existing machines — pick one and keep it.
        public let id: String
        public let displayName: String
        public let blurb: String
        public let tokenHelpURL: String?
        /// Login user on this cloud's stock Ubuntu image.
        public let sshUser: String
        /// False when the cloud rejects duplicate public keys and the key has to be
        /// registered through its API first.
        public let managesSSHKey: Bool
        public let supportsPause: Bool

        public let provider: ProviderBlock
        public let credentials: [Credential]
        /// Environment the OpenTofu provider reads, as templates. Keeping secrets here —
        /// rather than in the HCL — is what keeps them out of the state file.
        public let environment: [String: String]

        /// HCL that creates exactly one machine, plus the outputs listed in `docs/registry.md`.
        public let machineHCL: String
        /// Optional HCL of data sources and outputs only, used to fill the New machine
        /// form. It must create nothing.
        public let catalogHCL: String?
        public let catalog: CatalogMapping?
        /// Used when there is no catalog, or the catalog run fails.
        public let fallback: Capabilities
        public let extraVariables: ExtraVariables?

        public init(id: String, displayName: String, blurb: String, tokenHelpURL: String? = nil,
                    sshUser: String = "root", managesSSHKey: Bool = true,
                    supportsPause: Bool = true, provider: ProviderBlock,
                    credentials: [Credential], environment: [String: String],
                    machineHCL: String, catalogHCL: String? = nil,
                    catalog: CatalogMapping? = nil, fallback: Capabilities,
                    extraVariables: ExtraVariables? = nil) {
            self.id = id
            self.displayName = displayName
            self.blurb = blurb
            self.tokenHelpURL = tokenHelpURL
            self.sshUser = sshUser
            self.managesSSHKey = managesSSHKey
            self.supportsPause = supportsPause
            self.provider = provider
            self.credentials = credentials
            self.environment = environment
            self.machineHCL = machineHCL
            self.catalogHCL = catalogHCL
            self.catalog = catalog
            self.fallback = fallback
            self.extraVariables = extraVariables
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            displayName = try c.decode(String.self, forKey: .displayName)
            blurb = try c.decodeIfPresent(String.self, forKey: .blurb) ?? ""
            tokenHelpURL = try c.decodeIfPresent(String.self, forKey: .tokenHelpURL)
            sshUser = try c.decodeIfPresent(String.self, forKey: .sshUser) ?? "root"
            managesSSHKey = try c.decodeIfPresent(Bool.self, forKey: .managesSSHKey) ?? true
            supportsPause = try c.decodeIfPresent(Bool.self, forKey: .supportsPause) ?? true
            provider = try c.decode(ProviderBlock.self, forKey: .provider)
            credentials = try c.decodeIfPresent([Credential].self, forKey: .credentials) ?? []
            environment = try c.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
            machineHCL = try c.decode(String.self, forKey: .machineHCL)
            catalogHCL = try c.decodeIfPresent(String.self, forKey: .catalogHCL)
            catalog = try c.decodeIfPresent(CatalogMapping.self, forKey: .catalog)
            fallback = try c.decode(Capabilities.self, forKey: .fallback)
            extraVariables = try c.decodeIfPresent(ExtraVariables.self, forKey: .extraVariables)
        }
    }

    public struct ProviderBlock: Codable, Sendable, Equatable {
        /// Registry address, e.g. `hetznercloud/hcloud`.
        public let source: String
        /// Constraint, e.g. `~> 1.48`. Pinned on purpose: an unpinned provider means a
        /// machine built today and a machine built next month are not the same machine.
        public let version: String
        /// Body of the `provider "x" { … }` block. Usually empty.
        public let body: String

        public init(source: String, version: String, body: String = "") {
            self.source = source
            self.version = version
            self.body = body
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            source = try c.decode(String.self, forKey: .source)
            version = try c.decode(String.self, forKey: .version)
            body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        }
    }

    public struct Credential: Codable, Sendable, Equatable {
        public let key: String
        public let label: String
        /// Secret fields go to the keychain and are never written to disk or into state.
        public let secret: Bool
        public let help: String?
        /// Read from this environment variable when present, so a token already exported
        /// in your shell does not have to be typed again.
        public let environmentVariable: String?

        public init(key: String, label: String, secret: Bool = true,
                    help: String? = nil, environmentVariable: String? = nil) {
            self.key = key
            self.label = label
            self.secret = secret
            self.help = help
            self.environmentVariable = environmentVariable
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = try c.decode(String.self, forKey: .key)
            label = try c.decodeIfPresent(String.self, forKey: .label) ?? key
            secret = try c.decodeIfPresent(Bool.self, forKey: .secret) ?? true
            help = try c.decodeIfPresent(String.self, forKey: .help)
            environmentVariable = try c.decodeIfPresent(String.self, forKey: .environmentVariable)
        }
    }

    public struct Option: Codable, Sendable, Equatable {
        public let id: String
        public let label: String
        public init(id: String, label: String) { self.id = id; self.label = label }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            label = try c.decodeIfPresent(String.self, forKey: .label) ?? id
        }
    }

    public struct Capabilities: Codable, Sendable, Equatable {
        public let regions: [Option]
        public let sizes: [Option]
        public let images: [Option]
        public let defaultRegion: String?
        public let defaultSize: String?
        public let defaultImage: String?

        public init(regions: [Option], sizes: [Option], images: [Option],
                    defaultRegion: String? = nil, defaultSize: String? = nil,
                    defaultImage: String? = nil) {
            self.regions = regions
            self.sizes = sizes
            self.images = images
            self.defaultRegion = defaultRegion
            self.defaultSize = defaultSize
            self.defaultImage = defaultImage
        }
    }

    /// How to read a catalog run's outputs. Each entry names an output holding a list of
    /// objects, and which of their keys are the id and the label.
    public struct CatalogMapping: Codable, Sendable, Equatable {
        public struct Field: Codable, Sendable, Equatable {
            public let output: String
            public let id: String
            public let label: String?
            public init(output: String, id: String, label: String? = nil) {
                self.output = output
                self.id = id
                self.label = label
            }
        }
        public let regions: Field?
        public let sizes: Field?
        public let images: Field?

        public init(regions: Field? = nil, sizes: Field? = nil, images: Field? = nil) {
            self.regions = regions
            self.sizes = sizes
            self.images = images
        }
    }

    public struct ExtraVariables: Codable, Sendable, Equatable {
        /// Extra HCL `variable` blocks this module needs.
        public let declarations: String
        /// Values for them, as templates.
        public let values: [String: String]

        public init(declarations: String = "", values: [String: String] = [:]) {
            self.declarations = declarations
            self.values = values
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            declarations = try c.decodeIfPresent(String.self, forKey: .declarations) ?? ""
            values = try c.decodeIfPresent([String: String].self, forKey: .values) ?? [:]
        }
    }

    // MARK: - Validation

    public enum Invalid: LocalizedError, Equatable {
        case unsupportedVersion(found: Int)
        case noProviders
        case duplicateIDs([String])
        case entry(id: String, problem: String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let found):
                return "This registry is format version \(found); this build understands version \(supportedFormatVersion). Update Codex Remote, or point it at a registry it can read."
            case .noProviders:
                return "The registry parsed, but it lists no providers."
            case .duplicateIDs(let ids):
                return "Two providers share an id (\(ids.joined(separator: ", "))). Ids identify a machine's cloud, so they have to be unique."
            case .entry(let id, let problem):
                return "Provider `\(id)` is not usable: \(problem)"
            }
        }
    }

    /// Checked before anything is offered in the UI, so a malformed entry fails at the
    /// point it can be explained rather than halfway through creating a server.
    public func validated() throws -> ProviderRegistryDocument {
        guard formatVersion <= Self.supportedFormatVersion else {
            throw Invalid.unsupportedVersion(found: formatVersion)
        }
        guard !providers.isEmpty else { throw Invalid.noProviders }

        var seen = Set<String>()
        var duplicates: [String] = []
        for entry in providers where !seen.insert(entry.id).inserted { duplicates.append(entry.id) }
        guard duplicates.isEmpty else { throw Invalid.duplicateIDs(duplicates.sorted()) }

        for entry in providers {
            if entry.id.trimmingCharacters(in: .whitespaces).isEmpty {
                throw Invalid.entry(id: "(empty)", problem: "it has no id")
            }
            if entry.provider.source.isEmpty {
                throw Invalid.entry(id: entry.id, problem: "no OpenTofu provider source")
            }
            if entry.provider.version.isEmpty {
                throw Invalid.entry(id: entry.id, problem: "the provider version is unpinned; pin it so a machine built today matches one built next month")
            }
            if entry.machineHCL.isEmpty {
                throw Invalid.entry(id: entry.id, problem: "no machineHCL, so it cannot create anything")
            }
            // Outputs are the contract between a module and the rest of the app; without
            // them a machine would come up with no address to reach it at.
            for required in ["instance_id", "public_ipv4"] where !entry.machineHCL.contains(required) {
                throw Invalid.entry(id: entry.id,
                                    problem: "machineHCL declares no `\(required)` output (see docs/registry.md)")
            }
            if entry.fallback.regions.isEmpty || entry.fallback.sizes.isEmpty || entry.fallback.images.isEmpty {
                throw Invalid.entry(id: entry.id,
                                    problem: "the fallback lists are incomplete; they are what the form shows when the catalog cannot be read")
            }
            for (variable, template) in entry.environment where template.isEmpty {
                throw Invalid.entry(id: entry.id, problem: "environment variable `\(variable)` has an empty template")
            }
        }
        return self
    }

    // MARK: - Templates

    /// Expands `{{secret.token}}`, `{{field.project}}` and `{{request.region}}`.
    ///
    /// Deliberately tiny: a registry should be readable by someone who has never seen this
    /// codebase, and an expression language would make a JSON file into a program.
    /// An unknown placeholder expands to empty rather than throwing, because a provider
    /// that ignores a variable it does not need is normal.
    public static func expand(_ template: String,
                              fields: [String: String],
                              secrets: [String: String],
                              request: [String: String] = [:]) -> String {
        var result = ""
        var rest = Substring(template)
        while let open = rest.range(of: "{{") {
            result += rest[rest.startIndex..<open.lowerBound]
            guard let close = rest.range(of: "}}", range: open.upperBound..<rest.endIndex) else {
                // An unclosed placeholder is literal text, not a parse error.
                result += rest[open.lowerBound...]
                return result
            }
            let token = rest[open.upperBound..<close.lowerBound]
                .trimmingCharacters(in: .whitespaces)
            let parts = token.split(separator: ".", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                switch parts[0] {
                case "secret": result += secrets[parts[1]] ?? ""
                case "field": result += fields[parts[1]] ?? ""
                case "request": result += request[parts[1]] ?? ""
                default: break
                }
            }
            rest = rest[close.upperBound...]
        }
        result += rest
        return result
    }
}
