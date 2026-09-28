import Foundation
import CodexRemoteKit

/// Deterministic, local-only sample state for capturing documentation screenshots.
/// Debug builds opt in with CODEX_REMOTE_SCREENSHOT_MODE; no account or machine is created.
enum ScreenshotFixtures {
    #if DEBUG
    static let mode = ProcessInfo.processInfo.environment["CODEX_REMOTE_SCREENSHOT_MODE"]
    #else
    static let mode: String? = nil
    #endif

    static var enabled: Bool { mode != nil }

    static let hetznerID = UUID(uuidString: "c9a76e1a-97d7-45fd-a03d-a702b15fa11f")!
    static let awsID = UUID(uuidString: "f19059b4-f967-44a1-9d66-4e0c9e62de20")!

    static var accounts: [ProviderAccount] {
        if mode == "empty" { return [] }
        return [
            ProviderAccount(id: hetznerID, kind: .hetzner, label: "Hetzner",
                            verifiedIdentity: ProviderIdentity(accountLabel: "Demo account")),
            ProviderAccount(id: awsID, kind: .aws, label: "AWS",
                            verifiedIdentity: ProviderIdentity(accountLabel: "Demo account")),
        ]
    }

    static var machines: [Machine] {
        if mode == "empty" { return [] }
        let pausedSpec = MachineSpec(name: "build-eu", accountID: hetznerID,
                                     providerKind: .hetzner, region: "nbg1",
                                     size: "cx23", image: "ubuntu-24.04")
        let workingSpec = MachineSpec(name: "project-west", accountID: awsID,
                                      providerKind: .aws, region: "us-west-2",
                                      size: "t3.large", image: "ubuntu-24.04")
        return [
            Machine(spec: pausedSpec, instanceID: "sample-paused",
                    stage: .ready, health: .offline, powerIntent: .down,
                    localPort: 14560, sshHostAlias: "codex-remote-build-eu",
                    privateKeyPath: "/sample/key"),
            Machine(spec: workingSpec, instanceID: "sample-running",
                    instance: Instance(id: "sample-running", name: "project-west",
                                       state: .running, publicIPv4: "203.0.113.24",
                                       region: "us-west-2", size: "t3.large",
                                       providerKind: .aws),
                    stage: .ready, health: .online, localPort: 14561,
                    sshHostAlias: "codex-remote-project-west",
                    privateKeyPath: "/sample/key",
                    agentStatuses: [
                        AgentStatus(kind: .codex, isRunning: true,
                                    endpoint: "ws://127.0.0.1:14561"),
                        AgentStatus(kind: .claudeCode, isRunning: true,
                                    endpoint: "https://claude.ai/code"),
                    ],
                    metrics: SystemMetrics(cpuPercent: 12, memoryUsedBytes: 1_932_735_283,
                                           memoryTotalBytes: 8_589_934_592),
                    activeSessions: 2, codexVersion: "0.45.0"),
        ]
    }

    static let capabilities = ProviderCapabilities(
        regions: [Region(slug: "nbg1", name: "Nuremberg, DE"),
                  Region(slug: "hel1", name: "Helsinki, FI")],
        sizes: [InstanceSize(slug: "cx23", name: "CX23", vcpus: 2,
                             memoryGB: 4, diskGB: 40, monthlyPrice: 6.59,
                             currency: "EUR")],
        images: [OSImage(slug: "ubuntu-24.04", name: "Ubuntu 24.04 LTS",
                         family: "ubuntu")],
        recommendedImage: "ubuntu-24.04", recommendedSize: "cx23",
        recommendedRegion: "nbg1"
    )
}
