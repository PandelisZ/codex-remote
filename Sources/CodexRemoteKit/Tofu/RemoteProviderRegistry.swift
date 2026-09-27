import Foundation

/// Fetches and caches the provider registry.
///
/// The catalogue of clouds is data, so it is fetched rather than compiled in: new providers
/// can land for everyone without an app release, and anyone can host their own. See
/// `ProviderRegistryDocument` for the format and `docs/registry.md` for the reference.
///
/// Three rules shape this:
///
/// * **The cache is authoritative when the network is not.** A machine you need to reach at
///   an airport must not depend on a GitHub fetch, so a cached registry is used whenever
///   the network fails, however old it is.
/// * **A bad fetch never replaces a good cache.** A registry that does not parse, or that
///   comes from a future format version, is reported and discarded — the previous one keeps
///   working.
/// * **Changing the URL is a decision, not a background update.** A registry supplies HCL
///   that runs against your cloud credentials. Pointing at a new one is something the user
///   does on purpose and can see.
public actor RemoteProviderRegistry {
    public static let officialURL = URL(string: "https://codexremote.io/registry.json")!

    public struct Loaded: Sendable {
        public let document: ProviderRegistryDocument
        public let source: URL
        public let fetchedAt: Date
        /// True when this came from disk because the network could not be reached.
        public let fromCache: Bool
    }

    public enum Failure: LocalizedError {
        case http(status: Int)
        case unreadable(String)

        public var errorDescription: String? {
            switch self {
            case .http(let status):
                return "The registry URL answered with HTTP \(status)."
            case .unreadable(let detail):
                return "The registry could not be read: \(detail)"
            }
        }
    }

    public static let shared = RemoteProviderRegistry()

    private var cached: Loaded?
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    private var cacheFile: URL {
        Paths.codexRemoteHome.appendingPathComponent("registry.json")
    }

    private var metaFile: URL {
        Paths.codexRemoteHome.appendingPathComponent("registry-meta.json")
    }

    /// The registry to use, fetching when the cache is older than `maxAge`.
    @discardableResult
    public func load(from url: URL, maxAge: TimeInterval = 6 * 3600,
                     force: Bool = false) async -> Loaded? {
        if !force, let cached, cached.source == url,
           Date().timeIntervalSince(cached.fetchedAt) < maxAge {
            return cached
        }
        if !force, cached == nil, let disk = loadFromDisk(expecting: url),
           Date().timeIntervalSince(disk.fetchedAt) < maxAge {
            cached = disk
            return disk
        }

        do {
            let document = try await fetch(url)
            let loaded = Loaded(document: document, source: url, fetchedAt: Date(), fromCache: false)
            cached = loaded
            save(loaded)
            Log.shared.info("registry", "Loaded \(document.providers.count) provider(s) from \(url.absoluteString).")
            return loaded
        } catch {
            // A failed refresh must not take working providers away.
            if let fallback = cached ?? loadFromDisk(expecting: url) {
                Log.shared.warn("registry", "Using the cached registry: \(error.localizedDescription)")
                cached = fallback
                return Loaded(document: fallback.document, source: fallback.source,
                              fetchedAt: fallback.fetchedAt, fromCache: true)
            }
            Log.shared.warn("registry", "No registry available: \(error.localizedDescription)")
            return nil
        }
    }

    public func cachedDocument() -> Loaded? { cached ?? loadFromDisk(expecting: nil) }

    /// Fetches and validates without touching the cache — what the Settings pane uses to
    /// check a URL before the user commits to it.
    public func preview(_ url: URL) async throws -> ProviderRegistryDocument {
        try await fetch(url)
    }

    // MARK: - Plumbing

    private func fetch(_ url: URL) async throws -> ProviderRegistryDocument {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        // Always revalidate: a stale registry from an HTTP cache would silently hide a
        // provider that was fixed upstream, and this file is small.
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.http(status: http.statusCode)
        }
        do {
            let document = try JSONDecoder().decode(ProviderRegistryDocument.self, from: data)
            return try document.validated()
        } catch let invalid as ProviderRegistryDocument.Invalid {
            throw Failure.unreadable(invalid.localizedDescription)
        } catch {
            throw Failure.unreadable(error.localizedDescription)
        }
    }

    private struct Meta: Codable { let source: String; let fetchedAt: Date }

    private func save(_ loaded: Loaded) {
        do {
            try Paths.ensureDirectories()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(loaded.document).write(to: cacheFile, options: .atomic)
            let meta = Meta(source: loaded.source.absoluteString, fetchedAt: loaded.fetchedAt)
            let metaEncoder = JSONEncoder()
            metaEncoder.dateEncodingStrategy = .iso8601
            try metaEncoder.encode(meta).write(to: metaFile, options: .atomic)
        } catch {
            // Not fatal: the registry is in memory for this run either way.
            Log.shared.warn("registry", "Could not cache the registry: \(error.localizedDescription)")
        }
    }

    /// `expecting` nil accepts whatever is cached, which is what a cold start wants.
    private func loadFromDisk(expecting url: URL?) -> Loaded? {
        guard let data = try? Data(contentsOf: cacheFile),
              let document = try? JSONDecoder().decode(ProviderRegistryDocument.self, from: data),
              let validated = try? document.validated() else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let meta = (try? Data(contentsOf: metaFile)).flatMap { try? decoder.decode(Meta.self, from: $0) }
        let source = meta.flatMap { URL(string: $0.source) } ?? url ?? Self.officialURL
        if let url, source != url { return nil }
        return Loaded(document: validated, source: source,
                      fetchedAt: meta?.fetchedAt ?? .distantPast, fromCache: true)
    }
}
