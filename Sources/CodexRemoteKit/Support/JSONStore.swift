import Foundation

/// Small atomic JSON file store used for the machine registry, provider accounts and settings.
/// Writes go to a sibling temp file and are moved into place so a crash mid-write cannot
/// leave a half-written registry behind.
public final class JSONStore<Value: Codable & Sendable>: @unchecked Sendable {
    private let url: URL
    private let lock = Lock()
    private let fallback: @Sendable () -> Value

    public init(url: URL, fallback: @escaping @Sendable () -> Value) {
        self.url = url
        self.fallback = fallback
    }

    public func load() -> Value {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url) else { return fallback() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let value = try? decoder.decode(Value.self, from: data) else {
            Log.shared.warn("store", "Could not decode \(url.lastPathComponent); starting from defaults.")
            return fallback()
        }
        return value
    }

    public func save(_ value: Value) throws {
        lock.lock(); defer { lock.unlock() }
        try Paths.ensureDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temp, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
    }
}
