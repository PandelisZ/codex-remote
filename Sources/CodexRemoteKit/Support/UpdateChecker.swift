import Foundation

/// Checks whether a newer build exists.
///
/// The feed is a small JSON file published beside the site at
/// `https://codexremote.io/latest.json`, written by `Scripts/release.sh` at the same time
/// as the GitHub release. It is plain enough to check by hand:
///
/// ```bash
/// curl -s https://codexremote.io/latest.json
/// ```
///
/// Why not the GitHub API directly: it rate-limits unauthenticated callers to 60 requests
/// an hour per IP, which an app that checks on launch will hit on a shared network. The
/// feed is static, cached by the CDN, and carries the one thing the API does not — the
/// SHA-256 of the asset, which is what makes an unsigned download verifiable at all.
public enum UpdateChecker {
    public static let feedURL = URL(string: "https://codexremote.io/latest.json")!

    public struct Release: Sendable, Equatable, Codable {
        public let version: String
        public let url: String
        public let sha256: String
        public let notes: String?
        public let publishedAt: String?
        public let minimumSystemVersion: String?

        public init(version: String, url: String, sha256: String, notes: String? = nil,
                    publishedAt: String? = nil, minimumSystemVersion: String? = nil) {
            self.version = version
            self.url = url
            self.sha256 = sha256
            self.notes = notes
            self.publishedAt = publishedAt
            self.minimumSystemVersion = minimumSystemVersion
        }
    }

    public enum Outcome: Sendable, Equatable {
        case upToDate
        case available(Release)
        /// Homebrew owns this copy; updating it from inside the app would leave brew's
        /// records pointing at a version that is no longer there.
        case managedByHomebrew(Release)
    }

    public enum Failure: LocalizedError {
        case unreachable(String)
        case malformed(String)

        public var errorDescription: String? {
            switch self {
            case .unreachable(let detail): return "Could not reach the update feed: \(detail)"
            case .malformed(let detail): return "The update feed could not be read: \(detail)"
            }
        }
    }

    // MARK: - Checking

    public static func check(current: String = CodexRemoteVersion.current,
                             session: URLSession = .shared) async throws -> Outcome {
        var request = URLRequest(url: feedURL)
        request.timeoutInterval = 15
        // A cached feed would keep reporting the version that was current an hour ago.
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let data: Data
        do {
            let (body, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw Failure.unreachable("HTTP \(http.statusCode)")
            }
            data = body
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.unreachable(error.localizedDescription)
        }

        let release: Release
        do {
            release = try JSONDecoder().decode(Release.self, from: data)
        } catch {
            throw Failure.malformed(error.localizedDescription)
        }

        guard isNewer(release.version, than: current) else { return .upToDate }
        // An unsigned download is only as trustworthy as its hash, so a feed without one is
        // treated as no update rather than something to install on faith.
        guard release.sha256.count == 64, release.sha256.allSatisfy(\.isHexDigit) else {
            throw Failure.malformed("release \(release.version) has no usable sha256")
        }
        return isManagedByHomebrew ? .managedByHomebrew(release) : .available(release)
    }

    // MARK: - Versions

    /// Numeric component comparison. Deliberately not full semver: these are the project's
    /// own tags, and a pre-release suffix would need a release process that produces one.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ value: String) -> [Int] {
            value.split(whereSeparator: { $0 == "." || $0 == "v" })
                .compactMap { Int($0.prefix(while: \.isNumber)) }
        }
        let left = parts(candidate), right = parts(current)
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    // MARK: - Who owns this copy

    /// True when Homebrew installed this app.
    ///
    /// Self-updating it would replace the bundle under brew's feet: `brew list` would still
    /// claim the old version, `brew upgrade` would overwrite whatever the app installed, and
    /// `brew uninstall` would fail to find what it expected. Whoever installed it should be
    /// the one to update it.
    public static var isManagedByHomebrew: Bool {
        let bundle = Bundle.main.bundleURL.standardizedFileURL.path
        for prefix in ["/opt/homebrew/Caskroom/codex-remote", "/usr/local/Caskroom/codex-remote"]
        where FileManager.default.fileExists(atPath: prefix) {
            // The cask stages the bundle in the Caskroom and moves it to /Applications, so
            // the receipt existing alongside an /Applications copy is the signal.
            if bundle.hasPrefix("/Applications/CodexRemote.app") || bundle.hasPrefix(prefix) {
                return true
            }
        }
        return false
    }

    public static var homebrewUpgradeCommand: String {
        "brew upgrade --cask pandelisz/tap/codex-remote"
    }
}
