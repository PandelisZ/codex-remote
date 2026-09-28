import Foundation
import CryptoKit

/// Owns the ed25519 keypair Codex Remote installs on every machine it provisions.
/// One key per Mac, kept at `~/.codex-remote/keys/id_codex-remote`, never reused for anything else.
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
            // Sanitised on the way out, not only at generation: a key written before this
            // fix still carries whatever the Mac was called, and keys are not regenerated.
            return KeyPair(privateKeyPath: priv.path, publicKeyPath: pub.path,
                           publicKey: asciiPublicKey(publicKey))
        }

        // Clean up a half-created pair before regenerating; ssh-keygen refuses to overwrite.
        try? FileManager.default.removeItem(at: priv)
        try? FileManager.default.removeItem(at: pub)

        guard let keygen = Shell.which("ssh-keygen") else {
            throw SSHError.missingTool("ssh-keygen")
        }
        _ = try await Shell.check(keygen, [
            "-t", "ed25519", "-N", "", "-C", asciiComment(comment), "-f", priv.path,
        ], timeout: 60)

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: priv.path)
        let publicKey = try String(contentsOf: pub, encoding: .utf8)
        Log.shared.info("ssh", "Generated Codex Remote SSH key at \(priv.path).")
        return KeyPair(privateKeyPath: priv.path, publicKeyPath: pub.path,
                       publicKey: asciiPublicKey(publicKey))
    }

    // MARK: - Keeping the key ASCII

    /// The public key with its trailing comment reduced to ASCII.
    ///
    /// The default comment is `codex-remote@<the Mac's name>`, and macOS names a machine
    /// after its owner — "Pandelis’s MacBook Pro" — using U+2019, a curly apostrophe. Most
    /// clouds take the key as-is. EC2 does not: `ImportKeyPair` rejects the whole request
    /// with *"Character sets beyond ASCII are not supported"*, so provisioning failed on AWS
    /// for anyone whose Mac had a possessive in its name, which is the default.
    ///
    /// Only the comment is touched. The algorithm and the base64 blob are ASCII by
    /// construction, and rewriting either would produce a different key.
    public static func asciiPublicKey(_ key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        // "<algorithm> <blob> <comment…>" — the comment may itself contain spaces.
        let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return trimmed }
        let comment = asciiComment(String(parts[2]))
        return comment.isEmpty ? "\(parts[0]) \(parts[1])" : "\(parts[0]) \(parts[1]) \(comment)"
    }

    /// Transliterates the punctuation macOS actually produces, then drops anything else
    /// outside printable ASCII. Deliberately not a general transliteration: the comment is
    /// a label, so losing a character is better than failing to create a machine.
    public static func asciiComment(_ comment: String) -> String {
        var result = ""
        for character in comment {
            switch character {
            case "\u{2018}", "\u{2019}", "\u{02BC}": result.append("'")
            case "\u{201C}", "\u{201D}": result.append("\"")
            case "\u{2013}", "\u{2014}", "\u{2212}": result.append("-")
            case "\u{2026}": result.append("...")
            case "\u{00A0}", "\u{2007}", "\u{202F}": result.append(" ")
            default:
                // Printable ASCII only; a newline would split the authorized_keys entry.
                if let ascii = character.asciiValue, ascii >= 0x20, ascii < 0x7F {
                    result.append(character)
                }
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
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
