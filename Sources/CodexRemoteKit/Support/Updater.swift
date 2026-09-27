import Foundation
import CryptoKit

/// Downloads a release, verifies it, and swaps it in.
///
/// The awkward part is that the bundle being replaced is the one currently running. macOS
/// tolerates a running binary whose file is moved, but a half-replaced bundle is a broken
/// install, so the swap happens in a short detached script that waits for this process to
/// exit first. Everything before that point is reversible; the script is the only step that
/// is not, and it keeps the previous bundle until the new one is in place.
///
/// What is verified, and what is not: the download is checked against the SHA-256 published
/// in the feed, fetched over HTTPS from the project's own domain. That is the trust anchor.
/// It is weaker than a notarised, signed update — anyone who controls both the feed and the
/// asset could serve a matching pair — and the app says so rather than implying Apple has
/// checked anything.
public enum Updater {
    public enum Failure: LocalizedError {
        case downloadFailed(String)
        case hashMismatch(expected: String, got: String)
        case unpackFailed(String)
        case notWritable(String)

        public var errorDescription: String? {
            switch self {
            case .downloadFailed(let detail):
                return "The download did not finish: \(detail)"
            case .hashMismatch(let expected, let got):
                return "The download does not match the checksum the feed published — expected \(expected.prefix(12))…, got \(got.prefix(12))…. Nothing was installed."
            case .unpackFailed(let detail):
                return "The download could not be unpacked: \(detail)"
            case .notWritable(let path):
                return "\(path) cannot be replaced by this user. Move Codex Remote to /Applications, or download the update yourself."
            }
        }
    }

    public enum Progress: Sendable, Equatable {
        case downloading(fraction: Double?)
        case verifying
        case installing
        case relaunching
    }

    /// Downloads, verifies and stages the update, then relaunches into it.
    ///
    /// Returns only if something went wrong before the swap: on success the process is
    /// replaced by the new build.
    public static func install(_ release: UpdateChecker.Release,
                               bundle: URL = Bundle.main.bundleURL,
                               session: URLSession = .shared,
                               onProgress: (@Sendable (Progress) -> Void)? = nil) async throws {
        guard let url = URL(string: release.url) else {
            throw Failure.downloadFailed("the feed's url is not a url")
        }
        let application = bundle.standardizedFileURL
        // Fail before spending a download on something that cannot be installed.
        guard FileManager.default.isWritableFile(atPath: application.deletingLastPathComponent().path) else {
            throw Failure.notWritable(application.path)
        }

        onProgress?(.downloading(fraction: nil))
        let downloaded: URL
        do {
            let (temporary, response) = try await session.download(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw Failure.downloadFailed("HTTP \(http.statusCode)")
            }
            downloaded = temporary
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.downloadFailed(error.localizedDescription)
        }

        onProgress?(.verifying)
        let actual = try sha256(of: downloaded)
        guard actual.caseInsensitiveCompare(release.sha256) == .orderedSame else {
            try? FileManager.default.removeItem(at: downloaded)
            throw Failure.hashMismatch(expected: release.sha256, got: actual)
        }

        onProgress?(.installing)
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-remote-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: downloaded) }

        // `ditto` rather than unzip: it preserves the bundle's symlinks, extended
        // attributes and signature, which `unzip` flattens.
        let unpack = Process()
        unpack.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unpack.arguments = ["-x", "-k", downloaded.path, staging.path]
        let errors = Pipe()
        unpack.standardError = errors
        try unpack.run()
        unpack.waitUntilExit()
        guard unpack.terminationStatus == 0 else {
            let detail = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw Failure.unpackFailed(detail.isEmpty ? "ditto exited \(unpack.terminationStatus)" : detail)
        }

        guard let unpacked = try FileManager.default
            .contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else {
            throw Failure.unpackFailed("no .app inside the download")
        }

        onProgress?(.relaunching)
        try swap(unpacked, into: application)
    }

    // MARK: - The swap

    /// Hands the replacement to a detached script and exits.
    ///
    /// The script waits for this pid to go away before touching anything, so the bundle is
    /// never modified while it is running. The old build is kept until the new one is in
    /// place and put back if the move fails, so a failed update leaves a working app rather
    /// than a missing one.
    static func swap(_ replacement: URL, into application: URL) throws {
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-remote-swap-\(UUID().uuidString).sh")

        let body = """
        #!/bin/bash
        set -euo pipefail

        pid=$1
        new=$2
        app=$3
        backup="${app}.previous"

        # Wait for the running copy to exit. Bounded: if it never quits, do nothing rather
        # than replacing a bundle that is still in use.
        for _ in $(seq 1 100); do
          kill -0 "$pid" 2>/dev/null || break
          sleep 0.1
        done
        if kill -0 "$pid" 2>/dev/null; then
          rm -rf -- "$new" "$0"
          exit 0
        fi

        rm -rf -- "$backup"
        if [ -d "$app" ]; then mv -- "$app" "$backup"; fi

        if mv -- "$new" "$app"; then
          rm -rf -- "$backup"
        else
          # Put the working copy back rather than leaving nothing installed.
          if [ -d "$backup" ]; then mv -- "$backup" "$app"; fi
          rm -rf -- "$new" "$0"
          exit 1
        fi

        open -a "$app"
        rm -rf -- "$0"
        """

        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let swap = Process()
        swap.executableURL = URL(fileURLWithPath: "/bin/bash")
        swap.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier),
                          replacement.path, application.path]
        // Detached, with no inherited handles: it has to outlive this process.
        swap.standardOutput = FileHandle.nullDevice
        swap.standardError = FileHandle.nullDevice
        swap.standardInput = FileHandle.nullDevice
        try swap.run()
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        // Streamed: a release is tens of megabytes and there is no reason to hold it twice.
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
