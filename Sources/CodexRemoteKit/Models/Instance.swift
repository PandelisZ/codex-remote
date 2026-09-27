import Foundation

public struct Region: Codable, Hashable, Sendable, Identifiable {
    public var id: String { slug }
    public let slug: String
    public let name: String
    public let country: String?

    public init(slug: String, name: String, country: String? = nil) {
        self.slug = slug
        self.name = name
        self.country = country
    }
}

public struct InstanceSize: Codable, Hashable, Sendable, Identifiable {
    public var id: String { slug }
    public let slug: String
    public let name: String
    public let vcpus: Int
    public let memoryGB: Double
    public let diskGB: Int
    public let monthlyPrice: Double?
    public let currency: String
    public let availableRegions: [String]
    public let architecture: String

    public init(slug: String, name: String, vcpus: Int, memoryGB: Double, diskGB: Int,
                monthlyPrice: Double? = nil, currency: String = "USD",
                availableRegions: [String] = [], architecture: String = "x86") {
        self.slug = slug
        self.name = name
        self.vcpus = vcpus
        self.memoryGB = memoryGB
        self.diskGB = diskGB
        self.monthlyPrice = monthlyPrice
        self.currency = currency
        self.availableRegions = availableRegions
        self.architecture = architecture
    }

    public var summary: String {
        let symbol = currency == "EUR" ? "€" : "$"
        let price = monthlyPrice.map { String(format: " · %@%.2f/mo", symbol, $0) } ?? ""
        return "\(vcpus) vCPU · \(Int(memoryGB)) GB · \(diskGB) GB\(price)"
    }
}

public struct OSImage: Codable, Hashable, Sendable, Identifiable {
    /// Slug alone is not unique: providers publish the same image name for x86 and ARM.
    public var id: String { "\(slug)#\(architecture)" }
    public let slug: String
    public let name: String
    public let family: String
    /// "x86" or "arm". Must match the chosen server type, or creation fails.
    public let architecture: String

    public init(slug: String, name: String, family: String, architecture: String = "x86") {
        self.slug = slug
        self.name = name
        self.family = family
        self.architecture = architecture
    }
}

public struct ProviderCapabilities: Codable, Hashable, Sendable {
    public let regions: [Region]
    public let sizes: [InstanceSize]
    public let images: [OSImage]
    /// The image a new machine gets when the user does not pick one. Codex Remote's bootstrap
    /// targets Debian/Ubuntu, so every provider points this at a current Ubuntu LTS.
    public let recommendedImage: String
    public let recommendedSize: String
    public let recommendedRegion: String

    public init(regions: [Region], sizes: [InstanceSize], images: [OSImage],
                recommendedImage: String, recommendedSize: String, recommendedRegion: String) {
        self.regions = regions
        self.sizes = sizes
        self.images = images
        self.recommendedImage = recommendedImage
        self.recommendedSize = recommendedSize
        self.recommendedRegion = recommendedRegion
    }

    /// Only the types the provider actually stocks in that region.
    public func sizes(in region: String) -> [InstanceSize] {
        sizes.filter { $0.availableRegions.isEmpty || $0.availableRegions.contains(region) }
    }

    /// Picks the image a new machine should get: the newest Ubuntu on offer.
    ///
    /// Version-picking is done rather than naming one, because a hardcoded "ubuntu-24.04"
    /// quietly becomes the *old* default the moment a provider adds a newer release. Slugs
    /// differ per cloud — `ubuntu-26.04`, `ubuntu-26-04-x64`, `linode/ubuntu26.04` — so the
    /// version is parsed out of whichever shape it takes.
    public static func newestUbuntu(in images: [OSImage]) -> OSImage? {
        let ubuntu = images.filter {
            $0.family.lowercased().contains("ubuntu") || $0.slug.lowercased().contains("ubuntu")
        }
        return ubuntu.max { ubuntuVersion(of: $0) < ubuntuVersion(of: $1) }
    }

    /// `(major, minor)` from an image slug or name; `(0, 0)` when there is no version in it.
    public static func ubuntuVersion(of image: OSImage) -> (Int, Int) {
        for text in [image.slug, image.name] {
            guard let match = text.range(of: "([0-9]{2})[.\\-]([0-9]{2})",
                                         options: .regularExpression) else { continue }
            let digits = text[match].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            if digits.count == 2 { return (digits[0], digits[1]) }
        }
        return (0, 0)
    }

    /// Images that will boot on that server type. Picking an x86 image for an ARM machine
    /// is rejected at create time, so the form must never offer the combination.
    public func images(for sizeSlug: String) -> [OSImage] {
        guard let size = sizes.first(where: { $0.slug == sizeSlug }) else { return images }
        let matching = images.filter { $0.architecture == size.architecture }
        return matching.isEmpty ? images : matching
    }

    /// The image to default to for a given server type.
    public func recommendedImage(for sizeSlug: String) -> String {
        let candidates = images(for: sizeSlug)
        return candidates.first(where: { $0.slug == recommendedImage })?.slug
            ?? candidates.first?.slug ?? recommendedImage
    }
}

public enum InstanceState: String, Codable, Sendable {
    case provisioning, running, stopping, stopped, starting, deleting, deleted, unknown

    public var isLive: Bool { self == .running }
    public var isTransitional: Bool {
        self == .provisioning || self == .starting || self == .stopping || self == .deleting
    }
}

/// A provider's server, normalised. Everything above the provider layer speaks only this.
public struct Instance: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let state: InstanceState
    public let publicIPv4: String?
    public let publicIPv6: String?
    public let privateIPv4: String?
    public let region: String
    public let size: String
    public let image: String?
    public let createdAt: Date?
    public let providerKind: ProviderKind
    /// Anything provider-specific worth surfacing but not worth modelling.
    public let metadata: [String: String]

    public init(id: String, name: String, state: InstanceState, publicIPv4: String? = nil,
                publicIPv6: String? = nil, privateIPv4: String? = nil, region: String,
                size: String, image: String? = nil, createdAt: Date? = nil,
                providerKind: ProviderKind, metadata: [String: String] = [:]) {
        self.id = id
        self.name = name
        self.state = state
        self.publicIPv4 = publicIPv4
        self.publicIPv6 = publicIPv6
        self.privateIPv4 = privateIPv4
        self.region = region
        self.size = size
        self.image = image
        self.createdAt = createdAt
        self.providerKind = providerKind
        self.metadata = metadata
    }

    /// Tolerant of fields added later — see `MachineSpec.init(from:)`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
        state = try container.decodeIfPresent(InstanceState.self, forKey: .state) ?? .unknown
        publicIPv4 = try container.decodeIfPresent(String.self, forKey: .publicIPv4)
        publicIPv6 = try container.decodeIfPresent(String.self, forKey: .publicIPv6)
        privateIPv4 = try container.decodeIfPresent(String.self, forKey: .privateIPv4)
        region = try container.decodeIfPresent(String.self, forKey: .region) ?? "unknown"
        size = try container.decodeIfPresent(String.self, forKey: .size) ?? "unknown"
        image = try container.decodeIfPresent(String.self, forKey: .image)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        providerKind = try container.decodeIfPresent(ProviderKind.self, forKey: .providerKind)
            ?? ProviderKind("unknown")
        metadata = try container.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
    }

    /// The address SSH should dial. IPv4 first because more home networks can reach it.
    public var sshAddress: String? { publicIPv4 ?? publicIPv6 }
}

public struct InstanceRequest: Codable, Hashable, Sendable {
    public let name: String
    public let region: String
    public let size: String
    public let image: String
    /// Provider-side id of the SSH key that must be installed on the new machine.
    public let sshKeyIdentifiers: [String]
    /// cloud-init. Providers that support it use it purely to guarantee the SSH key and
    /// python/curl are present; all real setup happens over SSH afterwards.
    public let userData: String?
    public let labels: [String: String]
    /// Stable per-machine key, used by providers that keep state of their own. The
    /// OpenTofu backend names a machine's workspace after it, so the same machine always
    /// maps to the same state file across app launches.
    public let workspaceKey: String

    public init(name: String, region: String, size: String, image: String,
                sshKeyIdentifiers: [String], userData: String? = nil,
                labels: [String: String] = [:], workspaceKey: String = UUID().uuidString) {
        self.name = name
        self.region = region
        self.size = size
        self.image = image
        self.sshKeyIdentifiers = sshKeyIdentifiers
        self.userData = userData
        self.labels = labels
        self.workspaceKey = workspaceKey
    }
}

public enum PowerAction: String, Codable, Sendable {
    case start, stop, reboot
}
