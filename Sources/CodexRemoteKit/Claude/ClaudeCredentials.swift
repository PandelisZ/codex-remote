import Foundation
import Security

/// Gets this Mac's Claude Code login onto a machine, and nothing else.
///
/// On macOS the credentials live in the login keychain under `Claude Code-credentials`; on
/// Linux they are `~/.claude/.credentials.json`. The keychain item holds two things:
///
/// * `claudeAiOauth` — the Claude Code login. This is what a remote agent needs.
/// * `mcpOAuth` — access tokens for every MCP server the user has connected: Notion,
///   Linear, Figma, Atlassian, Intercom and so on.
///
/// `claudeAiOauth` always travels — a remote agent cannot sign in without it. `mcpOAuth`
/// travels only when the machine is set to sync MCP servers, because those are live tokens
/// to the user's Notion, Linear, Figma, Slack and Stripe accounts and putting them on a
/// cloud server is a decision worth making deliberately rather than by default.
///
/// Remote Control specifically needs a *full-scope* login. A token from `claude setup-token`
/// or `CLAUDE_CODE_OAUTH_TOKEN` is deliberately limited to inference only and Claude Code
/// refuses Remote Control with it, which is why Codex Remote copies the OAuth credential rather
/// than issuing a long-lived token.
public enum ClaudeCredentials {
    public static let keychainService = "Claude Code-credentials"
    /// The scope that marks a login as full-scope rather than inference-only.
    public static let sessionScope = "user:sessions:claude_code"

    public struct Summary: Sendable {
        public let subscriptionType: String?
        public let scopes: [String]
        public let expiresAt: Date?
        public let refreshTokenExpiresAt: Date?

        /// Whether this login can start a Remote Control session at all.
        public var supportsRemoteControl: Bool { scopes.contains(sessionScope) }

        /// The refresh token is what keeps a machine signed in; the access token is
        /// refreshed automatically and its expiry does not matter.
        public var refreshTokenIsValid: Bool {
            guard let refreshTokenExpiresAt else { return true }
            return refreshTokenExpiresAt > Date()
        }
    }

    public enum Failure: LocalizedError {
        case notSignedIn
        case unreadable(String)
        case inferenceOnly
        case refreshTokenExpired(Date)

        public var errorDescription: String? {
            switch self {
            case .notSignedIn:
                return "This Mac has no Claude Code login to copy. Run `claude auth login` first, or turn off Claude Code for this machine and sign in on the machine itself."
            case .unreadable(let detail):
                return "Could not read this Mac's Claude Code login: \(detail)"
            case .inferenceOnly:
                return "This Mac's Claude Code login is inference-only, which cannot start a Remote Control session. Sign in with `claude auth login` rather than a token from `claude setup-token`."
            case .refreshTokenExpired(let when):
                return "This Mac's Claude Code login expired on \(when.formatted(date: .abbreviated, time: .shortened)). Run `claude auth login` and try again."
            }
        }
    }

    /// The Claude Code login, as the JSON a Linux machine expects at
    /// `~/.claude/.credentials.json` — with the MCP section stripped out.
    public static func portableCredentials(includeMCPTokens: Bool = false,
                                           timeout: TimeInterval = 20) async throws -> (json: String, summary: Summary, mcpTokenCount: Int) {
        let raw = try await readRawCredentials(timeout: timeout)
        guard let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
            throw Failure.unreadable("the stored credentials were not JSON")
        }
        guard let oauth = object["claudeAiOauth"] as? [String: Any] else {
            throw Failure.notSignedIn
        }

        let summary = Summary(
            subscriptionType: oauth["subscriptionType"] as? String,
            scopes: oauth["scopes"] as? [String] ?? [],
            expiresAt: millisecondDate(oauth["expiresAt"]),
            refreshTokenExpiresAt: millisecondDate(oauth["refreshTokenExpiresAt"])
        )

        guard summary.supportsRemoteControl else { throw Failure.inferenceOnly }
        if let expiry = summary.refreshTokenExpiresAt, expiry <= Date() {
            throw Failure.refreshTokenExpired(expiry)
        }

        // Key order matters here, and it is not obvious. Claude Code reads this file
        // successfully only when `claudeAiOauth` comes first; writing it with sorted keys
        // puts `mcpOAuth` in front and the login is silently ignored — `claude auth status`
        // reports "not logged in" even though the credential is right there. So the JSON is
        // assembled in order rather than serialised from a dictionary.
        var mcpTokenCount = 0
        var parts = ["\"claudeAiOauth\":" + (try encodedValue(oauth))]
        if includeMCPTokens, let mcp = object["mcpOAuth"] as? [String: Any], !mcp.isEmpty {
            parts.append("\"mcpOAuth\":" + (try encodedValue(mcp)))
            mcpTokenCount = mcp.count
        }
        return ("{" + parts.joined(separator: ",") + "}", summary, mcpTokenCount)
    }

    private static func encodedValue(_ value: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// How many third-party MCP logins would travel, for the confirmation text — counted
    /// without reading or moving the tokens themselves.
    public static func mcpTokenNames() async -> [String] {
        guard let raw = try? await readRawCredentials(timeout: 10),
              let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let mcp = object["mcpOAuth"] as? [String: Any] else { return [] }
        return mcp.keys.map { $0.split(separator: "|").first.map(String.init) ?? $0 }
            .map { $0.replacingOccurrences(of: "plugin:design:", with: "") }
            .sorted()
    }

    /// True when there is something to copy, without reading the secret itself.
    public static var isSignedInLocally: Bool {
        if FileManager.default.fileExists(atPath: localCredentialsFile.path) { return true }
        // Checking for the item's existence does not need its data, so it raises no dialog.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    public static var localCredentialsFile: URL {
        Paths.home.appendingPathComponent(".claude/.credentials.json")
    }

    /// Reads the stored credentials. The `security` tool is used rather than
    /// `SecItemCopyMatching` because the item's ACL already names it — Claude Code itself
    /// reads it that way — so this usually goes through without a dialog.
    private static func readRawCredentials(timeout: TimeInterval) async throws -> String {
        if let onDisk = try? String(contentsOf: localCredentialsFile, encoding: .utf8),
           !onDisk.isEmpty {
            return onDisk
        }
        guard let security = Shell.which("security") else {
            throw Failure.unreadable("/usr/bin/security is not available")
        }
        let result: CommandResult
        do {
            result = try await Shell.run(security,
                                         ["find-generic-password", "-s", keychainService, "-w"],
                                         timeout: timeout)
        } catch {
            throw Failure.unreadable("the keychain did not answer — macOS may be showing an access prompt behind another window")
        }
        guard result.succeeded else { throw Failure.notSignedIn }
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Failure.notSignedIn }
        return text
    }

    private static func millisecondDate(_ value: Any?) -> Date? {
        guard let milliseconds = (value as? NSNumber)?.doubleValue else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }
}
