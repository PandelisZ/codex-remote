import Foundation

/// A coding agent Codex Remote can put on a machine.
///
/// The two reach you in fundamentally different ways, and that shapes everything else:
///
/// * **Codex** listens on the machine's own loopback interface and refuses to bind
///   anywhere else, so Codex Remote holds an SSH tunnel to it and the machine is reachable only
///   from this Mac.
/// * **Claude Code** connects *outbound* to Anthropic when started with `--remote-control`,
///   so the session appears in your account — on claude.ai/code, on your phone, in any
///   other Claude session — with no tunnel and no local registration at all.
///
/// A machine can run either or both.
public enum AgentKind: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case codex
    case claudeCode = "claude-code"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claudeCode: return "Claude Code"
        }
    }

    public var symbol: String {
        switch self {
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .claudeCode: return "sparkle"
        }
    }

    /// One line for the "new machine" form.
    public var blurb: String {
        switch self {
        case .codex:
            return "Reachable from this Mac through an SSH tunnel, and added to the Codex app's Remotes."
        case .claudeCode:
            return "Signs in to your account and appears wherever you use Claude — the web, your phone, other sessions."
        }
    }

    /// True when Codex Remote has to hold a local tunnel for this agent to be reachable.
    public var needsLocalTunnel: Bool { self == .codex }
}

/// Whether an agent is actually up on a machine, as last observed.
public struct AgentStatus: Codable, Hashable, Sendable, Identifiable {
    public var kind: AgentKind
    public var isRunning: Bool
    /// Where to reach it — a `ws://` endpoint for Codex, a claude.ai session URL for Claude.
    public var endpoint: String?
    public var detail: String?
    public var checkedAt: Date?

    public var id: String { kind.rawValue }

    /// Marker for an agent that is installed but waiting on a one-off browser sign-in.
    public static let needsSignIn = "needs sign-in"
    public var needsSignIn: Bool { !isRunning && detail == Self.needsSignIn }

    /// Tolerant of fields added later — see `MachineSpec.init(from:)`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(AgentKind.self, forKey: .kind)
        isRunning = try container.decodeIfPresent(Bool.self, forKey: .isRunning) ?? false
        endpoint = try container.decodeIfPresent(String.self, forKey: .endpoint)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        checkedAt = try container.decodeIfPresent(Date.self, forKey: .checkedAt)
    }

    public init(kind: AgentKind, isRunning: Bool = false, endpoint: String? = nil,
                detail: String? = nil, checkedAt: Date? = nil) {
        self.kind = kind
        self.isRunning = isRunning
        self.endpoint = endpoint
        self.detail = detail
        self.checkedAt = checkedAt
    }
}
