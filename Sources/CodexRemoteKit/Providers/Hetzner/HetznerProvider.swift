import Foundation

/// Hetzner Cloud (https://api.hetzner.cloud/v1). Token is a project-scoped API token
/// with read/write, created under Project → Security → API tokens.
public struct HetznerProvider: ComputeProvider {
    public let kind = ProviderKind.hetzner
    public let displayName = "Hetzner Cloud"
    private let http: HTTPClient

    public init(token: Secret, session: URLSession = .shared) {
        http = HTTPClient(
            providerName: "Hetzner Cloud",
            baseURL: URL(string: "https://api.hetzner.cloud/v1")!,
            defaultHeaders: ["Authorization": "Bearer \(token.raw)"],
            session: session
        )
    }

    init(http: HTTPClient) { self.http = http }

    public static let descriptor = ProviderDescriptor(
        kind: .hetzner,
        displayName: "Hetzner Cloud",
        blurb: "Cheap EU/US cloud servers. Needs a project API token with read & write.",
        credentialFields: [
            CredentialField(key: "token", label: "API token",
                            help: "Hetzner Cloud Console → your project → Security → API tokens → Generate, with Read & Write.",
                            style: .secret, environmentVariable: "HCLOUD_TOKEN"),
        ],
        tokenHelpURL: "https://console.hetzner.cloud/",
        make: { _, secrets in
            guard let token = secrets["token"] else {
                throw ProviderError.missingCredential(field: "API token", provider: "Hetzner Cloud")
            }
            return HetznerProvider(token: token)
        }
    )

    // MARK: - Protocol

    public func verify() async throws -> ProviderIdentity {
        // /servers is the cheapest authenticated call that proves both auth and project scope.
        let response = try await http.json(ServersEnvelope.self, "GET", "servers", query: ["per_page": "1"])
        let count = response.meta?.pagination?.totalEntries ?? response.servers.count
        return ProviderIdentity(accountLabel: "Hetzner project",
                                detail: "\(count) server\(count == 1 ? "" : "s") in this project")
    }

    public func capabilities() async throws -> ProviderCapabilities {
        async let locationsTask = http.json(LocationsEnvelope.self, "GET", "locations")
        async let typesTask = http.json(ServerTypesEnvelope.self, "GET", "server_types", query: ["per_page": "100"])
        async let imagesTask = http.json(ImagesEnvelope.self, "GET", "images",
                                         query: ["type": "system", "per_page": "100", "sort": "name"])
        // Which types you can actually buy where is published per datacenter, and it does
        // not match the set of locations a type has a price for — asking for one Hetzner
        // prices but does not stock gets a bare "unsupported location for server type".
        async let datacentersTask = http.json(DatacentersEnvelope.self, "GET", "datacenters")
        let (locations, types, images) = try await (locationsTask, typesTask, imagesTask)
        let stocked = (try? await datacentersTask).map(Self.availabilityByTypeID) ?? [:]

        let regions = locations.locations.map {
            Region(slug: $0.name, name: "\($0.city), \($0.country)", country: $0.country)
        }
        let sizes = types.serverTypes.filter { $0.deprecated != true }.map { type -> InstanceSize in
            let available = stocked[type.id].map { Array($0).sorted() }
                ?? type.prices?.map(\.location) ?? []
            let price = type.prices?.compactMap { Double($0.priceMonthly?.gross ?? "") }.min()
            return InstanceSize(slug: type.name, name: type.description ?? type.name,
                                vcpus: type.cores, memoryGB: type.memory, diskGB: type.disk,
                                monthlyPrice: price, currency: "EUR",
                                availableRegions: available,
                                architecture: type.architecture ?? "x86")
        }.sorted { ($0.monthlyPrice ?? .infinity) < ($1.monthlyPrice ?? .infinity) }

        // Only Debian-family images — the bootstrap is apt-based.
        let usable = images.images.filter {
            ($0.osFlavor == "ubuntu" || $0.osFlavor == "debian") && $0.status == "available"
        }
        let osImages = usable.map {
            OSImage(slug: $0.name ?? "ubuntu-24.04",
                    name: $0.description ?? $0.name ?? "unknown",
                    family: $0.osFlavor ?? "linux",
                    architecture: $0.architecture ?? "x86")
        }

        let recommendedImage = ProviderCapabilities.newestUbuntu(in: osImages)?.slug
            ?? osImages.first?.slug ?? "ubuntu-26.04"
        let recommendedRegion = regions.first(where: { $0.slug == "nbg1" })?.slug ?? regions.first?.slug ?? "nbg1"
        // cx22-class: 2 vCPU / 4 GB is the smallest size Codex is comfortable on.
        let recommendedSize = sizes.first(where: { $0.vcpus >= 2 && $0.memoryGB >= 4 })?.slug
            ?? sizes.first?.slug ?? "cx22"

        return ProviderCapabilities(regions: regions, sizes: sizes, images: osImages,
                                    recommendedImage: recommendedImage,
                                    recommendedSize: recommendedSize,
                                    recommendedRegion: recommendedRegion)
    }

    public func ensureSSHKey(name: String, publicKey: String) async throws -> String {
        let fingerprint = SSHKeyManager.md5Fingerprint(ofPublicKey: publicKey)
        if let fingerprint {
            let existing = try await http.json(SSHKeysEnvelope.self, "GET", "ssh_keys",
                                               query: ["fingerprint": fingerprint])
            if let match = existing.sshKeys.first { return String(match.id) }
        }
        // Name collisions are possible if the same key was uploaded under a different
        // fingerprint format, so make the name unique rather than failing the provision.
        let body = CreateSSHKeyBody(name: name, publicKey: publicKey.trimmingCharacters(in: .whitespacesAndNewlines))
        do {
            let created = try await http.json(SSHKeyEnvelope.self, "POST", "ssh_keys", body: body)
            return String(created.sshKey.id)
        } catch HTTPError.status(409, _, _) {
            let all = try await http.json(SSHKeysEnvelope.self, "GET", "ssh_keys", query: ["per_page": "100"])
            let wanted = normalizedKeyBody(publicKey)
            if let match = all.sshKeys.first(where: { normalizedKeyBody($0.publicKey ?? "") == wanted }) {
                return String(match.id)
            }
            let retry = CreateSSHKeyBody(name: "\(name)-\(UUID().uuidString.prefix(8))",
                                         publicKey: publicKey.trimmingCharacters(in: .whitespacesAndNewlines))
            let created = try await http.json(SSHKeyEnvelope.self, "POST", "ssh_keys", body: retry)
            return String(created.sshKey.id)
        }
    }

    public func createInstance(_ request: InstanceRequest) async throws -> Instance {
        let body = CreateServerBody(
            name: request.name,
            serverType: request.size,
            image: request.image,
            location: request.region,
            sshKeys: request.sshKeyIdentifiers,
            userData: request.userData,
            labels: request.labels,
            startAfterCreate: true,
            publicNet: .init(enableIPv4: true, enableIPv6: true)
        )
        do {
            let created = try await http.json(CreateServerEnvelope.self, "POST", "servers", body: body)
            return normalize(created.server)
        } catch HTTPError.status(let code, _, let detail) where detail.contains("resource_limit_exceeded") {
            _ = code
            throw ProviderError.creationFailed("""
            Hetzner will not add another server to this project yet: \(detail).
            Hetzner caps how many vCPUs a project may run, and a powered-off server still \
            counts against it. Free some up by deleting a server you no longer need, pick a \
            dedicated-vCPU type (ccx…), which has its own allowance, or ask Hetzner to raise \
            the limit under Project → Limits in the console.
            """)
        } catch HTTPError.status(let code, _, let detail) where detail.contains("unsupported location for server type") {
            _ = code
            throw ProviderError.creationFailed("""
            Hetzner will not build a \(request.size) in \(request.region). Its published \
            availability says it should, so this is usually a type your project is not \
            enabled for at all — ARM (cax…) types often are not. Pick a different type.
            """)
        }
    }

    public func instance(id: String) async throws -> Instance? {
        do {
            let response = try await http.json(ServerEnvelope.self, "GET", "servers/\(id)")
            return normalize(response.server)
        } catch HTTPError.status(404, _, _) {
            return nil
        }
    }

    public func listInstances() async throws -> [Instance] {
        let response = try await http.json(ServersEnvelope.self, "GET", "servers", query: ["per_page": "100"])
        return response.servers.map(normalize)
    }

    public func power(_ action: PowerAction, instanceID: String) async throws {
        let path: String
        switch action {
        case .start: path = "servers/\(instanceID)/actions/poweron"
        case .stop: path = "servers/\(instanceID)/actions/shutdown"   // ACPI first; graceful
        case .reboot: path = "servers/\(instanceID)/actions/reboot"
        }
        _ = try await http.json(ActionEnvelope.self, "POST", path, body: EmptyBody())
    }

    public func destroyInstance(id: String) async throws {
        do {
            _ = try await http.request("DELETE", "servers/\(id)")
        } catch HTTPError.status(404, _, _) {
            // Already gone; deleting is meant to be idempotent.
        }
    }

    public func defaultSSHUser(forImage image: String) -> String { "root" }

    // MARK: - Mapping

    private func normalizedKeyBody(_ key: String) -> String {
        // "ssh-ed25519 AAAA... comment" → "AAAA..."; comments differ between uploads.
        let parts = key.split(separator: " ")
        return parts.count >= 2 ? String(parts[1]) : key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalize(_ server: HetznerServer) -> Instance {
        Instance(
            id: String(server.id),
            name: server.name,
            state: Self.mapState(server.status),
            publicIPv4: server.publicNet?.ipv4?.ip,
            publicIPv6: server.publicNet?.ipv6?.ip.map(Self.firstIPv6Address),
            privateIPv4: server.privateNet?.first?.ip,
            region: server.location?.name ?? server.datacenter?.location?.name ?? "unknown",
            size: server.serverType?.name ?? "unknown",
            image: server.image?.name ?? server.image?.description,
            createdAt: server.created,
            providerKind: .hetzner,
            metadata: ["datacenter": server.datacenter?.name ?? ""]
        )
    }

    /// Hetzner hands back a /64 like `2a01:4f8::/64`; SSH wants a single address.
    static func firstIPv6Address(_ cidr: String) -> String {
        guard let slash = cidr.firstIndex(of: "/") else { return cidr }
        let network = String(cidr[cidr.startIndex..<slash])
        return network.hasSuffix("::") ? network + "1" : network
    }

    /// type id → the set of locations that currently have it in stock.
    static func availabilityByTypeID(_ response: DatacentersEnvelope) -> [Int: Set<String>] {
        var map: [Int: Set<String>] = [:]
        for datacenter in response.datacenters {
            guard let location = datacenter.location?.name else { continue }
            for id in datacenter.serverTypes?.available ?? [] {
                map[id, default: []].insert(location)
            }
        }
        return map
    }

    static func mapState(_ status: String) -> InstanceState {
        switch status {
        case "initializing", "migrating", "rebuilding": return .provisioning
        case "starting": return .starting
        case "running": return .running
        case "stopping": return .stopping
        case "off": return .stopped
        case "deleting": return .deleting
        default: return .unknown
        }
    }
}

// MARK: - Wire types

private struct EmptyBody: Encodable {}

private struct Pagination: Decodable { let totalEntries: Int?
    enum CodingKeys: String, CodingKey { case totalEntries = "total_entries" } }
private struct Meta: Decodable { let pagination: Pagination? }

private struct HetznerServer: Decodable {
    let id: Int
    let name: String
    let status: String
    let created: Date?
    let publicNet: PublicNet?
    let privateNet: [PrivateNet]?
    let serverType: NamedRef?
    let datacenter: Datacenter?
    /// Current API responses put the location on the server itself; older ones only had
    /// it nested under `datacenter`. Both are read, newest first.
    let location: NamedRef?
    let image: ImageRef?

    enum CodingKeys: String, CodingKey {
        case id, name, status, created, image
        case publicNet = "public_net"
        case privateNet = "private_net"
        case serverType = "server_type"
        case datacenter, location
    }

    struct PublicNet: Decodable {
        let ipv4: IPv4?
        let ipv6: IPv6?
        struct IPv4: Decodable { let ip: String? }
        struct IPv6: Decodable { let ip: String? }
    }
    struct PrivateNet: Decodable { let ip: String? }
    struct NamedRef: Decodable { let name: String? }
    struct Datacenter: Decodable { let name: String?; let location: NamedRef? }
    struct ImageRef: Decodable { let name: String?; let description: String? }
}

private struct ServersEnvelope: Decodable { let servers: [HetznerServer]; let meta: Meta? }
private struct ServerEnvelope: Decodable { let server: HetznerServer }
private struct CreateServerEnvelope: Decodable { let server: HetznerServer }
private struct ActionEnvelope: Decodable { let action: ActionBody?
    struct ActionBody: Decodable { let id: Int?; let status: String? } }

private struct CreateServerBody: Encodable {
    let name: String
    let serverType: String
    let image: String
    let location: String
    let sshKeys: [String]
    let userData: String?
    let labels: [String: String]
    let startAfterCreate: Bool
    let publicNet: PublicNet

    struct PublicNet: Encodable {
        let enableIPv4: Bool
        let enableIPv6: Bool
        enum CodingKeys: String, CodingKey {
            case enableIPv4 = "enable_ipv4"
            case enableIPv6 = "enable_ipv6"
        }
    }

    enum CodingKeys: String, CodingKey {
        case name, image, location, labels
        case serverType = "server_type"
        case sshKeys = "ssh_keys"
        case userData = "user_data"
        case startAfterCreate = "start_after_create"
        case publicNet = "public_net"
    }
}

private struct HetznerLocation: Decodable {
    let name: String
    let city: String
    let country: String
}
private struct LocationsEnvelope: Decodable { let locations: [HetznerLocation] }

struct DatacentersEnvelope: Decodable {
    let datacenters: [Datacenter]

    struct Datacenter: Decodable {
        let name: String?
        let location: LocationRef?
        let serverTypes: ServerTypes?
        enum CodingKeys: String, CodingKey {
            case name, location
            case serverTypes = "server_types"
        }
        struct LocationRef: Decodable { let name: String? }
        struct ServerTypes: Decodable { let available: [Int]?; let supported: [Int]? }
    }
}

private struct HetznerServerType: Decodable {
    let id: Int
    let name: String
    let description: String?
    let cores: Int
    let memory: Double
    let disk: Int
    let deprecated: Bool?
    let architecture: String?
    let prices: [Price]?

    struct Price: Decodable {
        let location: String
        let priceMonthly: Amount?
        enum CodingKeys: String, CodingKey { case location; case priceMonthly = "price_monthly" }
        struct Amount: Decodable { let gross: String? }
    }
}
private struct ServerTypesEnvelope: Decodable {
    let serverTypes: [HetznerServerType]
    enum CodingKeys: String, CodingKey { case serverTypes = "server_types" }
}

private struct HetznerImage: Decodable {
    let name: String?
    let description: String?
    let osFlavor: String?
    let status: String?
    let architecture: String?
    enum CodingKeys: String, CodingKey {
        case name, description, status, architecture
        case osFlavor = "os_flavor"
    }
}
private struct ImagesEnvelope: Decodable { let images: [HetznerImage] }

private struct HetznerSSHKey: Decodable {
    let id: Int
    let name: String?
    let publicKey: String?
    enum CodingKeys: String, CodingKey { case id, name; case publicKey = "public_key" }
}
private struct SSHKeysEnvelope: Decodable {
    let sshKeys: [HetznerSSHKey]
    enum CodingKeys: String, CodingKey { case sshKeys = "ssh_keys" }
}
private struct SSHKeyEnvelope: Decodable {
    let sshKey: HetznerSSHKey
    enum CodingKeys: String, CodingKey { case sshKey = "ssh_key" }
}
private struct CreateSSHKeyBody: Encodable {
    let name: String
    let publicKey: String
    enum CodingKeys: String, CodingKey { case name; case publicKey = "public_key" }
}
