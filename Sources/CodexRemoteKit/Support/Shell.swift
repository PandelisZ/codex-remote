import Foundation

public struct CommandResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public var succeeded: Bool { exitCode == 0 }

    /// Everything the command said, in the order that is most useful for an error message.
    public var combined: String {
        let parts = [stdout, stderr].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

public enum ShellError: LocalizedError {
    case launchFailed(String, underlying: String)
    case nonZeroExit(String, CommandResult)
    case timedOut(String, seconds: Double)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let cmd, let underlying):
            return "Could not run \(cmd): \(underlying)"
        case .nonZeroExit(let cmd, let result):
            let detail = result.combined.isEmpty ? "no output" : result.combined
            return "\(cmd) exited \(result.exitCode): \(detail)"
        case .timedOut(let cmd, let seconds):
            return "\(cmd) did not finish within \(Int(seconds))s."
        }
    }
}

/// Thin async wrapper over `Process`. Everything Codex Remote does on a remote host goes
/// through the system `ssh`/`scp` binaries rather than a bundled SSH library, so the
/// user's existing `~/.ssh/config`, agent, and hardware keys keep working unchanged.
public enum Shell {
    public static func run(
        _ executable: String,
        _ arguments: [String],
        stdin: String? = nil,
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        timeout: Double = 600
    ) async throws -> CommandResult {
        let description = ([executable] + arguments).joined(separator: " ")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        var env = ProcessInfo.processInfo.environment
        if let environment { env.merge(environment) { _, new in new } }
        process.environment = env

        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = inPipe

        // Read both pipes to EOF with readability handlers and treat EOF as the signal
        // that the stream is finished. Mixing handlers with a final `readToEnd()` races:
        // the handler may still be mid-read when the process exits, and the tail of the
        // output is lost — which shows up as an empty stdout from a command that clearly
        // produced some.
        let collector = OutputCollector()
        let streamsDone = DispatchGroup()
        streamsDone.enter()
        streamsDone.enter()

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                streamsDone.leave()
            } else {
                collector.appendOut(data)
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                streamsDone.leave()
            } else {
                collector.appendErr(data)
            }
        }

        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            throw ShellError.launchFailed(description, underlying: error.localizedDescription)
        }

        if let stdin {
            try? inPipe.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
        }
        try? inPipe.fileHandleForWriting.close()

        let timedOut = TimeoutFlag()
        let waiter = Task.detached {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if process.isRunning {
                timedOut.trip()
                process.terminate()
                // Give it a moment to exit cleanly before the hard kill.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
        }
        waiter.cancel()

        // Both pipes reach EOF once the child is gone; wait for that so nothing written
        // just before exit is dropped.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            streamsDone.notify(queue: .global()) { continuation.resume() }
        }

        if timedOut.tripped { throw ShellError.timedOut(description, seconds: timeout) }
        return CommandResult(exitCode: process.terminationStatus,
                             stdout: collector.out, stderr: collector.err)
    }

    /// Same as `run` but throws on a non-zero exit, which is what most call sites want.
    @discardableResult
    public static func check(
        _ executable: String,
        _ arguments: [String],
        stdin: String? = nil,
        environment: [String: String]? = nil,
        timeout: Double = 600
    ) async throws -> CommandResult {
        let result = try await run(executable, arguments, stdin: stdin,
                                   environment: environment, timeout: timeout)
        guard result.succeeded else {
            throw ShellError.nonZeroExit(([executable] + arguments).joined(separator: " "), result)
        }
        return result
    }

    public static func which(_ name: String) -> String? {
        let candidates = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let fromPath = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in fromPath + candidates {
            let path = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = Lock()
    private var outData = Data()
    private var errData = Data()

    func appendOut(_ data: Data) { lock.lock(); outData.append(data); lock.unlock() }
    func appendErr(_ data: Data) { lock.lock(); errData.append(data); lock.unlock() }
    var out: String { lock.lock(); defer { lock.unlock() }; return String(decoding: outData, as: UTF8.self) }
    var err: String { lock.lock(); defer { lock.unlock() }; return String(decoding: errData, as: UTF8.self) }
}

private final class TimeoutFlag: @unchecked Sendable {
    private let lock = Lock()
    private var value = false
    func trip() { lock.lock(); value = true; lock.unlock() }
    var tripped: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
