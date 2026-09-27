import Foundation
import Security

/// Provider tokens live in the login keychain, never in the JSON state files.
/// The JSON only ever stores the account UUID that addresses the keychain item.
public enum Keychain {
    public enum Failure: LocalizedError {
        case status(OSStatus)
        case encoding
        case blocked(String)

        public var errorDescription: String? {
            switch self {
            case .status(let code):
                let detail = SecCopyErrorMessageString(code, nil) as String? ?? "OSStatus \(code)"
                return "Keychain error: \(detail)"
            case .encoding:
                return "Keychain value was not valid UTF-8."
            case .blocked(let account):
                return "The keychain did not answer for \(account) — macOS is probably showing an access prompt behind another window. Allow it, or export the provider's token as an environment variable instead."
            }
        }
    }

    private static let service = "io.codexremote.credentials"

    public static func set(_ value: Secret, account: String) throws {
        let data = Data(value.raw.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            let update = SecItemUpdate(query as CFDictionary,
                                       [kSecValueData as String: data] as CFDictionary)
            guard update == errSecSuccess else { throw Failure.status(update) }
        } else if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let add = SecItemAdd(insert as CFDictionary, nil)
            guard add == errSecSuccess else { throw Failure.status(add) }
        } else {
            throw Failure.status(status)
        }
    }

    public static func get(account: String) throws -> Secret? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure.status(status) }
        guard let data = item as? Data, let text = String(data: data, encoding: .utf8) else {
            throw Failure.encoding
        }
        return Secret(text)
    }

    public static func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure.status(status)
        }
    }
}

/// Indirection so tests (and `codex-remote` running headless in CI) can swap the keychain
/// for an in-memory store without touching the login keychain.
public protocol CredentialStore: Sendable {
    func read(_ account: String) throws -> Secret?
    func write(_ secret: Secret, for account: String) throws
    func remove(_ account: String) throws
}

public struct KeychainCredentialStore: CredentialStore {
    /// How long to wait for the keychain before giving up. A read can block forever when
    /// macOS decides to show an access dialog — which it does whenever the calling
    /// binary's signature has changed — and a provisioning run must not hang on that.
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 20) { self.timeout = timeout }

    public func read(_ account: String) throws -> Secret? {
        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            do { box.set(.success(try Keychain.get(account: account))) }
            catch { box.set(.failure(error)) }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            throw Keychain.Failure.blocked(account)
        }
        switch box.get() {
        case .success(let secret): return secret
        case .failure(let error): throw error
        case .none: return nil
        }
    }
    public func write(_ secret: Secret, for account: String) throws { try Keychain.set(secret, account: account) }
    public func remove(_ account: String) throws { try Keychain.delete(account: account) }
}

public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = Lock()
    private var values: [String: Secret] = [:]
    public init(_ seed: [String: Secret] = [:]) { values = seed }
    public func read(_ account: String) throws -> Secret? {
        lock.lock(); defer { lock.unlock() }; return values[account]
    }
    public func write(_ secret: Secret, for account: String) throws {
        lock.lock(); defer { lock.unlock() }; values[account] = secret
    }
    public func remove(_ account: String) throws {
        lock.lock(); defer { lock.unlock() }; values[account] = nil
    }
}

/// Reads a token from the environment first (`HCLOUD_TOKEN`, `DIGITALOCEAN_TOKEN`, ...)
/// then falls back to the keychain. Lets `codex-remote` be driven from CI without a keychain prompt.
public struct EnvironmentFirstCredentialStore: CredentialStore {
    private let envKeys: [String: String]
    private let fallback: CredentialStore

    public init(envKeys: [String: String], fallback: CredentialStore = KeychainCredentialStore()) {
        self.envKeys = envKeys
        self.fallback = fallback
    }

    public func read(_ account: String) throws -> Secret? {
        if let key = envKeys[account],
           let value = ProcessInfo.processInfo.environment[key], !value.isEmpty {
            return Secret(value)
        }
        return try fallback.read(account)
    }

    public func write(_ secret: Secret, for account: String) throws { try fallback.write(secret, for: account) }
    public func remove(_ account: String) throws { try fallback.remove(account) }
}

/// Tiny thread-safe slot for handing a keychain result back across the timeout boundary.
private final class ResultBox: @unchecked Sendable {
    private let lock = Lock()
    private var value: Result<Secret?, Error>?
    func set(_ result: Result<Secret?, Error>) { lock.lock(); value = result; lock.unlock() }
    func get() -> Result<Secret?, Error>? { lock.lock(); defer { lock.unlock() }; return value }
}
