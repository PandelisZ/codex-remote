import Foundation

/// The single place the version lives, so the MCP handshake, the CLI and the bundle cannot
/// drift apart. Kept in step with the VERSION file by Scripts/bundle.sh.
public enum CodexRemoteVersion {
    public static let current = "0.5.2"
}

import Foundation
import os

public enum LogLevel: String, Codable, Sendable, CaseIterable {
    case debug, info, warn, error
}

public struct LogLine: Codable, Sendable, Identifiable {
    public let id: UUID
    public let at: Date
    public let level: LogLevel
    public let scope: String
    public let message: String

    public init(level: LogLevel, scope: String, message: String) {
        self.id = UUID()
        self.at = Date()
        self.level = level
        self.scope = scope
        self.message = message
    }
}

/// Ring-buffered logger. The menu bar reads `recent()` to render the activity pane,
/// and everything is mirrored to a rotating file so failed provisions can be diagnosed
/// after the app has been quit.
public final class Log: @unchecked Sendable {
    public static let shared = Log()

    private let lock = Lock()
    private var buffer: [LogLine] = []
    private let capacity = 2000
    private let osLog = Logger(subsystem: "dev.codex-remote", category: "codex-remote")
    private var fileHandle: FileHandle?
    private var observers: [UUID: (LogLine) -> Void] = [:]

    private init() {}

    public func attachFile() {
        lock.lock(); defer { lock.unlock() }
        guard fileHandle == nil else { return }
        try? Paths.ensureDirectories()
        let url = Paths.logsDir.appendingPathComponent("codex-remote.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil,
                                           attributes: [.posixPermissions: 0o600])
        }
        fileHandle = try? FileHandle(forWritingTo: url)
        _ = try? fileHandle?.seekToEnd()
    }

    public func observe(_ handler: @escaping (LogLine) -> Void) -> UUID {
        lock.lock(); defer { lock.unlock() }
        let token = UUID()
        observers[token] = handler
        return token
    }

    public func removeObserver(_ token: UUID) {
        lock.lock(); defer { lock.unlock() }
        observers[token] = nil
    }

    public func log(_ level: LogLevel, _ scope: String, _ message: String) {
        let line = LogLine(level: level, scope: scope, message: message)
        lock.lock()
        buffer.append(line)
        if buffer.count > capacity { buffer.removeFirst(buffer.count - capacity) }
        let snapshot = Array(observers.values)
        let handle = fileHandle
        lock.unlock()

        osLog.log(level: level == .error ? .error : .info, "[\(scope, privacy: .public)] \(message, privacy: .public)")
        if let handle {
            let stamp = ISO8601DateFormatter().string(from: line.at)
            let text = "\(stamp) \(level.rawValue.uppercased()) [\(scope)] \(message)\n"
            try? handle.write(contentsOf: Data(text.utf8))
        }
        for observer in snapshot { observer(line) }
    }

    public func debug(_ scope: String, _ message: String) { log(.debug, scope, message) }
    public func info(_ scope: String, _ message: String) { log(.info, scope, message) }
    public func warn(_ scope: String, _ message: String) { log(.warn, scope, message) }
    public func error(_ scope: String, _ message: String) { log(.error, scope, message) }

    public func recent(limit: Int = 300) -> [LogLine] {
        lock.lock(); defer { lock.unlock() }
        return Array(buffer.suffix(limit))
    }
}

/// Values that must never reach the log or the UI are wrapped in this so an accidental
/// interpolation prints a placeholder instead of the secret.
public struct Secret: CustomStringConvertible, Sendable, Hashable {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public var description: String { "<redacted>" }
    public var isEmpty: Bool { raw.isEmpty }
    /// Last four characters, for "which key is this?" affordances in the UI.
    public var fingerprintSuffix: String { String(raw.suffix(4)) }
}
