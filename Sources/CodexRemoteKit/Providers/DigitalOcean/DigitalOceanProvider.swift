import Foundation

/// DigitalOcean Droplets (https://api.digitalocean.com/v2). Needs a personal access
/// token with read+write scope.
public struct DigitalOceanProvider: ComputeProvider {
    public let kind = ProviderKind.digitalOcean
    public let displayName = "DigitalOcean"
    private let http: HTTPClient

    public init(token: Secret, session: URLSession = .shared) {
        http = HTTPClient(
            providerName: "DigitalOcean",
            baseURL: URL(string: "https://api.digitalocean.com/v2")!,
            defaultHeaders: ["Authorization": "Bearer \(token.raw)"],
            session: session
        )
    }

    init(http: HTTPClient) { self.http = http }

    public static let descriptor = ProviderDescriptor(
        kind: .digitalOcean,
        displayName: "DigitalOcean",
        blurb: "Droplets across 14 regions. Needs a personal access token with read & write.",
        credentialFields: [
            CredentialField(key: "token", label: "Personal access token",
                            help: "DigitalOcean → API → Tokens → Generate New Token, with Write scope.",
                            style: .secret, environmentVariable: "DIGITALOCEAN_TOKEN"),
        ],
        tokenHelpURL: "https://cloud.digitalocean.com/account/api/tokens",
        make: { _, secrets in
            guard let token = secrets["token"] else {
                throw ProviderError.missingCredential(field: "Personal access token", provider: "DigitalOcean")
            }
            return DigitalOceanProvider(token: token)
        }
    )

    public func verify() async throws -> ProviderIdentity {
        let response = try await http.json(AccountEnvelope.self, "GET", "account")
        return ProviderIdentity(accountLabel: response.account.email ?? "DigitalOcean account",
                                detail: response.account.status.map { "status: \($0)" })
    }

    public func capabilities() async throws -> ProviderCapabilities {
        async let regionsTask = http.json(RegionsEnvelope.self, "GET", "regions", query: ["per_page": "100"])
        async let sizesTask = http.json(SizesEnvelope.self, "GET", "sizes", query: ["per_page": "200"])
        async let imagesTask = http.json(ImagesEnvelope.self, "GET", "images",
                                         query: ["type": "distribution", "per_page": "200"])
        let (regionsResponse, sizesResponse, imagesResponse) = try await (regionsTask, sizesTask, imagesTask)

        let regions = regionsResponse.regions.filter { $0.available != false }
            .map { Region(slug: $0.slug, name: $0.name, country: nil) }

        let sizes = sizesResponse.sizes.filter { $0.available != false }.map { size in
            InstanceSize(slug: size.slug, name: size.description ?? size.slug,
                         vcpus: size.vcpus, memoryGB: Double(size.memory) / 1024.0,
                         diskGB: size.disk, monthlyPrice: size.priceMonthly,
                         currency: "USD", availableRegions: size.regions ?? [],
                         architecture: size.slug.contains("arm") ? "arm" : "x86")
        }.sorted { ($0.monthlyPrice ?? .infinity) < ($1.monthlyPrice ?? .infinity) }

        let images = imagesResponse.images
            .filter { ($0.distribution ?? "").lowercased().contains("ubuntu") || ($0.distribution ?? "").lowercased().contains("debian") }
            .compactMap { image -> OSImage? in
                guard let slug = image.slug else { return nil }
                return OSImage(slug: slug,
                               name: "\(image.distribution ?? "") \(image.name ?? "")".trimmingCharacters(in: .whitespaces),
                               family: (image.distribution ?? "linux").lowercased(),
                               architecture: slug.contains("arm") ? "arm" : "x86")
            }

        let recommendedImage = ProviderCapabilities.newestUbuntu(in: images)?.slug
            ?? images.first?.slug ?? "ubuntu-26-04-x64"
        let recommendedRegion = regions.first(where: { $0.slug == "nyc3" })?.slug ?? regions.first?.slug ?? "nyc3"
        let recommendedSize = sizes.first(where: { $0.vcpus >= 2 && $0.memoryGB >= 4 })?.slug
            ?? sizes.first?.slug ?? "s-2vcpu-4gb"

        return ProviderCapabilities(regions: regions, sizes: sizes, images: images,
                                    recommendedImage: recommendedImage,
                                    recommendedSize: recommendedSize,
                                    recommendedRegion: recommendedRegion)
    }

    public func ensureSSHKey(name: String, publicKey: String) async throws -> String {
        let existing = try await http.json(SSHKeysEnvelope.self, "GET", "account/keys", query: ["per_page": "200"])
        let wanted = keyBody(publicKey)
        if let match = existing.sshKeys.first(where: { keyBody($0.publicKey ?? "") == wanted }) {
            return String(match.id)
        }
        let body = CreateKeyBody(name: name, publicKey: publicKey.trimmingCharacters(in: .whitespacesAndNewlines))
        let created = try await http.json(SSHKeyEnvelope.self, "POST", "account/keys", body: body)
        return String(created.sshKey.id)
    }

    public func createInstance(_ request: InstanceRequest) async throws -> Instance {
        let body = CreateDropletBody(
            name: request.name,
            region: request.region,
            size: request.size,
            image: request.image,
            sshKeys: request.sshKeyIdentifiers.map { Int($0).map(SSHKeyRef.numeric) ?? .fingerprint($0) },
            userData: request.userData,
            ipv6: true,
            tags: request.labels.map { "\($0.key)-\($0.value)" }
                .map { $0.replacingOccurrences(of: ".", with: "-") }
        )
        let created = try await http.json(DropletEnvelope.self, "POST", "droplets", body: body)
        return normalize(created.droplet)
    }

    public func instance(id: String) async throws -> Instance? {
        do {
            let response = try await http.json(DropletEnvelope.self, "GET", "droplets/\(id)")
            return normalize(response.droplet)
        } catch HTTPError.status(404, _, _) {
            return nil
        }
    }

    public func listInstances() async throws -> [Instance] {
        let response = try await http.json(DropletsEnvelope.self, "GET", "droplets", query: ["per_page": "200"])
        return response.droplets.map(normalize)
    }

    public func power(_ action: PowerAction, instanceID: String) async throws {
        let type: String
        switch action {
        case .start: type = "power_on"
        case .stop: type = "shutdown"
        case .reboot: type = "reboot"
        }
        _ = try await http.json(ActionEnvelope.self, "POST", "droplets/\(instanceID)/actions",
                                body: ActionBody(type: type))
    }

    public func destroyInstance(id: String) async throws {
        let response = try await http.request("DELETE", "droplets/\(id)")
        guard response.isSuccess || response.status == 404 else {
            throw HTTPError.status(response.status, provider: "DigitalOcean", detail: response.text)
        }
    }

    public func defaultSSHUser(forImage image: String) -> String { "root" }

    private func keyBody(_ key: String) -> String {
        let parts = key.split(separator: " ")
        return parts.count >= 2 ? String(parts[1]) : key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalize(_ droplet: Droplet) -> Instance {
        let v4 = droplet.networks?.v4 ?? []
        let v6 = droplet.networks?.v6 ?? []
        return Instance(
            id: String(droplet.id),
            name: droplet.name,
            state: Self.mapState(droplet.status),
            publicIPv4: v4.first(where: { $0.type == "public" })?.ipAddress,
            publicIPv6: v6.first(where: { $0.type == "public" })?.ipAddress,
            privateIPv4: v4.first(where: { $0.type == "private" })?.ipAddress,
            region: droplet.region?.slug ?? "unknown",
            size: droplet.sizeSlug ?? "unknown",
            image: droplet.image?.slug ?? droplet.image?.name,
            createdAt: droplet.createdAt,
            providerKind: .digitalOcean
        )
    }

    static func mapState(_ status: String?) -> InstanceState {
        switch status {
        case "new": return .provisioning
        case "active": return .running
        case "off": return .stopped
        case "archive": return .deleted
        default: return .unknown
        }
    }
}

// MARK: - Wire types

private struct AccountEnvelope: Decodable {
    let account: Account
    struct Account: Decodable { let email: String?; let status: String? }
}

private struct DORegion: Decodable {
    let slug: String
    let name: String
    let available: Bool?
}
private struct RegionsEnvelope: Decodable { let regions: [DORegion] }

private struct DOSize: Decodable {
    let slug: String
    let description: String?
    let memory: Int
    let vcpus: Int
    let disk: Int
    let priceMonthly: Double?
    let regions: [String]?
    let available: Bool?
    enum CodingKeys: String, CodingKey {
        case slug, description, memory, vcpus, disk, regions, available
        case priceMonthly = "price_monthly"
    }
}
private struct SizesEnvelope: Decodable { let sizes: [DOSize] }

private struct DOImage: Decodable {
    let slug: String?
    let name: String?
    let distribution: String?
}
private struct ImagesEnvelope: Decodable { let images: [DOImage] }

private struct Droplet: Decodable {
    let id: Int
    let name: String
    let status: String?
    let sizeSlug: String?
    let createdAt: Date?
    let region: RegionRef?
    let image: ImageRef?
    let networks: Networks?

    enum CodingKeys: String, CodingKey {
        case id, name, status, region, image, networks
        case sizeSlug = "size_slug"
        case createdAt = "created_at"
    }

    struct RegionRef: Decodable { let slug: String? }
    struct ImageRef: Decodable { let slug: String?; let name: String? }
    struct Networks: Decodable {
        let v4: [Net]?
        let v6: [Net]?
        struct Net: Decodable {
            let ipAddress: String?
            let type: String?
            enum CodingKeys: String, CodingKey { case type; case ipAddress = "ip_address" }
        }
    }
}
private struct DropletEnvelope: Decodable { let droplet: Droplet }
private struct DropletsEnvelope: Decodable { let droplets: [Droplet] }

/// DO accepts either a numeric key id or a fingerprint string in `ssh_keys`.
private enum SSHKeyRef: Encodable {
    case numeric(Int)
    case fingerprint(String)
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .numeric(let value): try container.encode(value)
        case .fingerprint(let value): try container.encode(value)
        }
    }
}

private struct CreateDropletBody: Encodable {
    let name: String
    let region: String
    let size: String
    let image: String
    let sshKeys: [SSHKeyRef]
    let userData: String?
    let ipv6: Bool
    let tags: [String]
    enum CodingKeys: String, CodingKey {
        case name, region, size, image, ipv6, tags
        case sshKeys = "ssh_keys"
        case userData = "user_data"
    }
}

private struct ActionBody: Encodable { let type: String }
private struct ActionEnvelope: Decodable {
    let action: Act?
    struct Act: Decodable { let id: Int?; let status: String? }
}

private struct DOSSHKey: Decodable {
    let id: Int
    let name: String?
    let publicKey: String?
    let fingerprint: String?
    enum CodingKeys: String, CodingKey { case id, name, fingerprint; case publicKey = "public_key" }
}
private struct SSHKeysEnvelope: Decodable {
    let sshKeys: [DOSSHKey]
    enum CodingKeys: String, CodingKey { case sshKeys = "ssh_keys" }
}
private struct SSHKeyEnvelope: Decodable {
    let sshKey: DOSSHKey
    enum CodingKeys: String, CodingKey { case sshKey = "ssh_key" }
}
private struct CreateKeyBody: Encodable {
    let name: String
    let publicKey: String
    enum CodingKeys: String, CodingKey { case name; case publicKey = "public_key" }
}
