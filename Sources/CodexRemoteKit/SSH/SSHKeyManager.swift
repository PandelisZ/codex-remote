import Foundation
import CryptoKit

/// Owns the ed25519 keypair Codex Remote installs on every machine it provisions.
/// One key per Mac, kept at `~/.codex/codex-remote/keys/id_codex-remote`, never reused for anything else.
public enum SSHKeyManager {
    public struct KeyPair: Sendable {
        public let privateKeyPath: String
        public let publicKeyPath: String
        public let publicKey: String
    }

    public static var defaultPrivateKeyURL: URL { Paths.keysDir.appendingPathComponent("id_codex-remote") }
    public static var defaultPublicKeyURL: URL { Paths.keysDir.appendingPathComponent("id_codex-remote.pub") }

    /// Creates the key if it is missing, otherwise returns the existing one.
    public static func ensureKeyPair(comment: String = "codex-remote@\(Host.current().localizedName ?? "mac")") async throws -> KeyPair {
        try Paths.ensureDirectories()
        let priv = defaultPrivateKeyURL
        let pub = defaultPublicKeyURL

        if FileManager.default.fileExists(atPath: priv.path),
           let publicKey = try? String(contentsOf: pub, encoding: .utf8) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: priv.path)
            return KeyPair(privateKeyPath: priv.path, publicKeyPath: pub.path,
                           publicKey: publicKey.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // Clean up a half-created pair before regenerating; ssh-keygen refuses to overwrite.
        try? FileManager.default.removeItem(at: priv)
        try? FileManager.default.removeItem(at: pub)

        guard let keygen = Shell.which("ssh-keygen") else {
            throw SSHError.missingTool("ssh-keygen")
        }
        _ = try await Shell.check(keygen, [
            "-t", "ed25519", "-N", "", "-C", comment, "-f", priv.path,
        ], timeout: 60)

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: priv.path)
        let publicKey = try String(contentsOf: pub, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        Log.shared.info("ssh", "Generated Codex Remote SSH key at \(priv.path).")
        return KeyPair(privateKeyPath: priv.path, publicKeyPath: pub.path, publicKey: publicKey)
    }

    /// `aa:bb:cc:…` MD5 fingerprint — the format Hetzner and DigitalOcean index keys by.
    public static func md5Fingerprint(ofPublicKey key: String) -> String? {
        let parts = key.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return nil }
        return Insecure.MD5.hash(data: blob)
            .map { String(format: "%02x", $0) }
            .joined(separator: ":")
    }

    /// SHA256 fingerprint in OpenSSH's `SHA256:…` form, for display.
    public static func sha256Fingerprint(ofPublicKey key: String) -> String? {
        let parts = key.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return nil }
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "SHA256:\(digest)"
    }
}
