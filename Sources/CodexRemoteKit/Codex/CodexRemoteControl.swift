import Foundation

/// Codex's dial-out remote control: the machine connects to OpenAI itself and appears
/// under **Connections → Control other devices**, reachable from this Mac and from the
/// phone. It needs no SSH host block, no inbound port, and no relaunch of the Codex app.
///
/// This is a *different* mechanism from the SSH one Codex Remote sets up by default, where the
/// Codex app finds the machine in `~/.ssh/config` and starts `codex app-server` on it over
/// SSH. Both can be on at once; they do not interfere.
///
/// Two caveats worth keeping in view, because neither is Codex Remote's to fix:
///
/// * `codex remote-control` is marked `[experimental]` by the CLI, and OpenAI's docs do
///   not mention it at all — they describe only the desktop-app route and state that
///   remote control "supports hosts running the ChatGPT desktop app on macOS and Windows".
///   A headless Linux box is outside the envelope the docs commit to.
/// * Pairing is deliberately manual. The client checks `/wham/remote/control/mfa_requirement`
///   before pairing a device, because a paired device can execute code under the user's
///   account. Codex Remote has the access token to POST the pairing code itself and does not,
///   for that reason: the prompt is the control, not an inconvenience to route around.
public enum CodexRemoteControl {
    /// Opens the Codex app straight at Settings → Connections, where the code is pasted.
    public static let connectionsDeepLink = URL(string: "codex://settings/connections")!

    public struct Status: Sendable, Equatable {
        public let isConnected: Bool
        public let serverName: String?
        public let environmentID: String?

        public init(isConnected: Bool, serverName: String?, environmentID: String?) {
            self.isConnected = isConnected
            self.serverName = serverName
            self.environmentID = environmentID
        }
    }

    /// A short-lived code the user types into Codex to authorise the machine.
    public struct PairingCode: Sendable, Equatable {
        /// The human-typable form, e.g. `8RA4-JY3T`. The long numeric `pairingCode` in the
        /// same payload is what the QR encodes and is not useful to show.
        public let manualCode: String
        public let environmentID: String?
        public let expiresAt: Date?

        public init(manualCode: String, environmentID: String?, expiresAt: Date?) {
            self.manualCode = manualCode
            self.environmentID = environmentID
            self.expiresAt = expiresAt
        }

        public var hasExpired: Bool {
            guard let expiresAt else { return false }
            return expiresAt <= Date()
        }

        /// Grouped the way the code is printed, so it reads as two chunks rather than a
        /// run of characters to be copied by eye.
        public var displayGroups: [String] {
            manualCode.split(separator: "-").map(String.init)
        }
    }

    public enum Failure: LocalizedError {
        case notInstalled
        case unreadable(String)

        public var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "The machine has no `codex` on its PATH, so remote control cannot be started there."
            case .unreadable(let detail):
                return "Codex did not answer with the JSON this expects: \(detail)"
            }
        }
    }

    // MARK: - Commands

    /// Starts the app-server daemon with remote control enabled. Installs the managed
    /// daemon on first run, which is why this is slower than it looks.
    @discardableResult
    public static func enable(on ssh: SSHClient, plan: BootstrapPlan) async throws -> Status {
        // Installed as a unit rather than started bare, so a machine that is powered off
        // and on again comes back into "Control other devices" by itself.
        _ = try? await ssh.runScript(BootstrapScript.installRemoteControlService(plan),
                                     timeout: 300, label: "install Codex remote control")
        let payload = try await runJSON("codex remote-control start --json", on: ssh)
        return Status(isConnected: (payload["status"] as? String) == "connected",
                      serverName: payload["serverName"] as? String,
                      environmentID: payload["environmentId"] as? String)
    }

    /// Mints a fresh pairing code. They are short-lived by design, so this is called when
    /// the user is actually looking at the window rather than during provisioning.
    public static func pair(on ssh: SSHClient) async throws -> PairingCode {
        let payload = try await runJSON("codex remote-control pair --json", on: ssh)
        guard let manual = payload["manualPairingCode"] as? String, !manual.isEmpty else {
            throw Failure.unreadable("no manualPairingCode in the response")
        }
        var expiry: Date?
        if let seconds = payload["expiresAt"] as? Double {
            expiry = Date(timeIntervalSince1970: seconds)
        } else if let seconds = payload["expiresAt"] as? Int {
            expiry = Date(timeIntervalSince1970: Double(seconds))
        }
        return PairingCode(manualCode: manual,
                           environmentID: payload["environmentId"] as? String,
                           expiresAt: expiry)
    }

    /// Whether the Codex app has taken the machine on as a device it can control.
    ///
    /// Read from the app's own state rather than asked of the machine: the machine reports
    /// itself "connected" to OpenAI as soon as remote control starts, which is true but
    /// says nothing about whether *this* Mac has accepted it. The app records an accepted
    /// device under the host id `remote-control:<environmentId>`, so that is the signal.
    ///
    /// Read-only, and tolerant of the file being absent or mid-write — the Codex app
    /// rewrites it wholesale on its own schedule, so a failed read means "not yet", never
    /// an error worth showing.
    public static func isPaired(environmentID: String?) -> Bool {
        guard let environmentID, !environmentID.isEmpty else { return false }
        guard let text = try? String(contentsOf: CodexAppRegistrar.stateFileURL, encoding: .utf8)
        else { return false }
        return text.contains(hostID(for: environmentID))
    }

    /// The id the Codex app files a remote-control device under.
    public static func hostID(for environmentID: String) -> String {
        "remote-control:\(environmentID)"
    }

    public static func disable(on ssh: SSHClient) async throws {
        _ = try await ssh.run(loginShell("codex remote-control stop --json"), timeout: 60)
    }

    // MARK: - Plumbing

    /// The login shell, to match how the Codex app starts things on a remote host — a
    /// `codex` that only resolves in a non-login shell would work here and fail there.
    static func loginShell(_ command: String) -> String {
        "bash -lc \(SSHClient.singleQuoted(command))"
    }

    private static func runJSON(_ command: String, on ssh: SSHClient) async throws -> [String: Any] {
        let result = try await ssh.run(loginShell("command -v codex >/dev/null || exit 3; \(command)"),
                                       timeout: 180)
        if result.exitCode == 3 { throw Failure.notInstalled }
        guard let object = firstJSONObject(in: result.stdout) else {
            throw Failure.unreadable(result.combined.isEmpty ? "no output" : String(result.combined.prefix(300)))
        }
        return object
    }

    /// `start` prints a human line ("Installing daemon from CLI version…") before the JSON
    /// on first run, so the payload has to be found rather than assumed to be the whole
    /// of stdout — the same shape of problem as `tofu output -json`.
    static func firstJSONObject(in text: String) -> [String: Any]? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else { continue }
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return object
            }
        }
        return nil
    }
}
