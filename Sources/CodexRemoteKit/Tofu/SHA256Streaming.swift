import Foundation
import CryptoKit

/// Chunked SHA-256, so a 35 MB download can be verified without being held in memory.
struct SHA256Streaming {
    private var hasher = SHA256()
    mutating func update(_ data: Data) { hasher.update(data: data) }
    mutating func finalizeHex() -> String {
        hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
