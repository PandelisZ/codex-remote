import XCTest
@testable import CodexRemoteKit

final class CodexRegistrarTests: XCTestCase {
    private func makeMachine(name: String = "codex-eu", port: Int = 14560) -> Machine {
        Machine(
            spec: MachineSpec(name: name, accountID: UUID(), providerKind: .hetzner,
                              region: "nbg1", size: "cx22", image: "ubuntu-24.04",
                              workspacePath: "/root/workspace"),
            instance: Instance(id: "1", name: name, state: .running, publicIPv4: "203.0.113.7",
                               region: "nbg1", size: "cx22", providerKind: .hetzner),
            stage: .ready, health: .online,
            localPort: port,
            sshHostAlias: SSHConfigManager.hostAlias(for: name),
            privateKeyPath: "/tmp/id_codex-remote"
        )
    }

    func testConnectCommandMatchesWhatCodexExpects() {
        let machine = makeMachine()
        XCTAssertEqual(
            CodexRegistrar.connectCommand(for: machine),
            "codex --remote ws://127.0.0.1:14560 "
            + "--remote-auth-token-env CODEX_REMOTE_TOKEN_CODEX_REMOTE_CODEX_EU -C /root/workspace"
        )
    }

    func testTokenEnvVarIsAValidShellIdentifier() {
        let machine = makeMachine(name: "eu-west 2")
        XCTAssertEqual(machine.tokenEnvVar, "CODEX_REMOTE_TOKEN_CODEX_REMOTE_EU_WEST_2")
        XCTAssertNotNil(machine.tokenEnvVar.range(of: "^[A-Z_][A-Z0-9_]*$", options: .regularExpression))
    }

    /// The bearer token is the one secret that would let anyone who reads a dotfile drive
    /// the remote agent, so the launcher must fetch it at run time and never embed it.
    func testLauncherReadsTheTokenFromTheKeychainAtRunTime() {
        let machine = makeMachine()
        let script = CodexRegistrar.launcherScript(for: machine)

        XCTAssertTrue(script.contains("security find-generic-password"))
        XCTAssertTrue(script.contains(machine.tokenKeychainAccount))
        XCTAssertTrue(script.contains("export \(machine.tokenEnvVar)=\"$token\""),
                      "the env var must be assigned from the shell variable, not a literal")
        XCTAssertNil(script.range(of: "[0-9a-f]{64}", options: .regularExpression),
                     "no 256-bit hex literal may appear in the launcher")
        XCTAssertTrue(script.contains("PORT=\(machine.localPort)"))
        XCTAssertTrue(script.contains("--remote \"ws://127.0.0.1:$PORT\""))
        XCTAssertTrue(script.contains("-C '\(machine.spec.workspacePath)'"))
    }

    func testLauncherFailsLoudlyWhenTheTunnelIsDown() {
        let script = CodexRegistrar.launcherScript(for: makeMachine())
        XCTAssertTrue(script.contains("nc -z 127.0.0.1"))
        XCTAssertTrue(script.contains("exit 1"))
        XCTAssertTrue(script.contains("ssh -N -L"), "it should print the manual tunnel command")
    }

    func testSSHHostFileHasOneEntryPerReachableMachine() {
        let machines = [makeMachine(name: "one", port: 14560), makeMachine(name: "two", port: 14561)]
        let file = SSHConfigManager.renderHostFile(machines: machines)
        XCTAssertTrue(file.contains("Host codex-remote-one"))
        XCTAssertTrue(file.contains("Host codex-remote-two"))
        XCTAssertTrue(file.contains("HostName 203.0.113.7"))
        XCTAssertTrue(file.contains("IdentitiesOnly yes"))
        XCTAssertTrue(file.contains("UserKnownHostsFile"))
    }

    func testMachinesWithoutAnAddressAreOmittedFromSSHConfig() {
        var pending = makeMachine(name: "pending")
        pending.instance = nil
        XCTAssertFalse(SSHConfigManager.renderHostFile(machines: [pending]).contains("Host codex-remote-pending"))
    }

    func testRemoteConfigTrustsTheWorkspaceAndDisablesPrompts() {
        let config = CodexRegistrar.remoteConfig(workspacePath: "/srv/agent")
        XCTAssertTrue(config.contains("[projects.\"/srv/agent\"]"))
        XCTAssertTrue(config.contains("trust_level = \"trusted\""))
        XCTAssertTrue(config.contains("approval_policy = \"never\""))
    }

    func testStatusTextExplainsEachState() {
        var machine = makeMachine()
        machine.spec.agents = [.codex]
        // A healthy machine reports its own load. It used to print the tunnel endpoint,
        // which is the same loopback address on every machine and told you nothing.
        machine.metrics = SystemMetrics(cpuPercent: 7, memoryUsedBytes: 1 << 31,
                                        memoryTotalBytes: 1 << 34)
        XCTAssertEqual(machine.statusText, "CPU 7% · RAM 2.0/16 GB")
        XCTAssertFalse(machine.statusText.contains("ws://"))

        machine.health = .degraded
        XCTAssertTrue(machine.statusText.contains("not answering"))

        machine.stage = .installingCodex
        XCTAssertEqual(machine.statusText, "Installing Codex")

        machine.stage = .failed
        machine.lastError = "apt exploded"
        XCTAssertTrue(machine.statusText.contains("apt exploded"))
    }

    /// A machine can run either agent or both, and the status line has to speak for
    /// whichever are actually installed.
    func testStatusTextCoversBothAgents() {
        var machine = makeMachine()
        machine.spec.agents = [.codex, .claudeCode]
        machine.health = .online
        machine.agentStatuses = [AgentStatus(kind: .claudeCode, isRunning: true)]

        // Healthy Codex needs no words: the row's indicator already says the machine is
        // up. Claude is different — it can be installed and signed out on a live machine,
        // so its state is only visible if the line says so.
        let text = machine.statusText
        XCTAssertTrue(text.contains("Claude in your account"), text)
        XCTAssertFalse(text.contains("ws://"), text)

        machine.health = .degraded
        XCTAssertTrue(machine.statusText.contains("Codex not answering"), machine.statusText)
        machine.health = .online

        machine.agentStatuses = [AgentStatus(kind: .claudeCode, isRunning: false)]
        XCTAssertTrue(machine.statusText.contains("Claude not running"))
    }

    /// A Claude-only machine has no tunnel, so tunnel health must not decide its readiness.
    func testClaudeOnlyMachineNeedsNoTunnelAndIsReadyWhenRemoteControlIsUp() {
        var machine = makeMachine()
        machine.spec.agents = [.claudeCode]
        machine.health = .offline

        XCTAssertFalse(machine.needsTunnel)
        XCTAssertFalse(machine.isReady, "no Remote Control yet")

        machine.agentStatuses = [AgentStatus(kind: .claudeCode, isRunning: true,
                                             endpoint: "https://claude.ai/code/session_abc")]
        XCTAssertTrue(machine.isReady, "Remote Control up means ready, tunnel or not")
        XCTAssertEqual(machine.claudeSessionURL, "https://claude.ai/code/session_abc")
        XCTAssertTrue(machine.statusText.contains("Claude in your account"))
    }

    func testCodexMachineStillDependsOnItsTunnel() {
        var machine = makeMachine()
        machine.spec.agents = [.codex]
        machine.health = .offline
        XCTAssertTrue(machine.needsTunnel)
        XCTAssertFalse(machine.isReady)

        machine.health = .online
        XCTAssertTrue(machine.isReady)
    }
}

/// Codex's health is about SSH, not about a tunnel. The desktop app finds the host in
/// ~/.ssh/config and starts `codex app-server` on it over SSH itself; the --listen/tunnel
/// pair is Codex's separate experimental "remote terminal UI" mode. codex-demo was fully
/// usable from the app while Codex Remote reported it offline because a tunnel had stopped.
final class CodexHealthSignalTests: XCTestCase {
    func testAMachineWithNoTunnelIsNotAutomaticallyUnhealthy() async {
        // No instance address: the probe cannot reach it, which is a real reason to be
        // offline — as opposed to "a tunnel is not running", which is not.
        let machine = Machine(
            spec: MachineSpec(name: "codex-demo", accountID: UUID(), providerKind: .hetzner,
                              region: "nbg1", size: "ccx13", image: "ubuntu-26.04",
                              workspacePath: "/srv/workspace", agents: [.codex]),
            stage: .ready, health: .online, localPort: 14561,
            sshHostAlias: SSHConfigManager.hostAlias(for: "codex-demo"),
            privateKeyPath: "/tmp/id_codex-remote")
        let probe = await HealthMonitor().probe(machine)
        let codex = probe.agentStatuses.first { $0.kind == AgentKind.codex }
        XCTAssertEqual(codex?.detail, "no address",
                       "offline must be attributed to reachability, never to tunnel state")
    }
}

/// Codex's dial-out remote control — the "Control other devices" path — which needs no SSH
/// host block and no relaunch of the Codex app.
final class CodexRemoteControlTests: XCTestCase {
    /// `start` prints a human line before the JSON the first time it runs on a machine,
    /// because it installs the managed daemon. Treating stdout as one JSON blob fails
    /// exactly once per machine — the worst kind of bug to find later.
    func testTheJSONIsFoundEvenWhenTheDaemonInstallPrintsFirst() throws {
        let output = """
        Installing daemon from CLI version 0.157.1 into /root/.codex/packages/app-server-daemon...
        {"mode":"daemon","status":"connected","serverName":"codex-demo","environmentId":"env_e_6ab9"}
        """
        let object = try XCTUnwrap(CodexRemoteControl.firstJSONObject(in: output))
        XCTAssertEqual(object["status"] as? String, "connected")
        XCTAssertEqual(object["environmentId"] as? String, "env_e_6ab9")
    }

    func testNonJSONOutputIsNotMistakenForAPayload() {
        XCTAssertNil(CodexRemoteControl.firstJSONObject(in: "error: not logged in\n"))
    }

    /// The code is shown in groups rather than as a run of characters, because it is
    /// transcribed by hand into another app.
    func testTheCodeIsPresentedInTheGroupsItIsPrintedIn() {
        let code = CodexRemoteControl.PairingCode(manualCode: "8RA4-JY3T",
                                                  environmentID: "env_e_1", expiresAt: nil)
        XCTAssertEqual(code.displayGroups, ["8RA4", "JY3T"])
    }

    /// A code that has quietly gone stale looks identical to one Codex rejected, so expiry
    /// has to be something the UI can state rather than infer.
    func testExpiryIsReportedRatherThanLeftToBeGuessed() {
        let past = CodexRemoteControl.PairingCode(manualCode: "AAAA-BBBB", environmentID: nil,
                                                  expiresAt: Date(timeIntervalSinceNow: -1))
        let future = CodexRemoteControl.PairingCode(manualCode: "AAAA-BBBB", environmentID: nil,
                                                    expiresAt: Date(timeIntervalSinceNow: 300))
        let unknown = CodexRemoteControl.PairingCode(manualCode: "AAAA-BBBB", environmentID: nil,
                                                     expiresAt: nil)
        XCTAssertTrue(past.hasExpired)
        XCTAssertFalse(future.hasExpired)
        XCTAssertFalse(unknown.hasExpired, "an unknown expiry must not read as expired")
    }

    /// The commands run through a login shell, matching how the Codex app starts things on
    /// a remote host — a `codex` that only resolves in a non-login shell would pass here
    /// and fail there.
    func testCommandsGoThroughALoginShell() {
        let wrapped = CodexRemoteControl.loginShell("codex remote-control pair --json")
        XCTAssertTrue(wrapped.hasPrefix("bash -lc "))
        XCTAssertTrue(wrapped.contains("remote-control pair --json"))
    }

    func testTheDeepLinkPointsAtTheConnectionsPane() {
        XCTAssertEqual(CodexRemoteControl.connectionsDeepLink.absoluteString,
                       "codex://settings/connections")
    }
}

extension CodexRemoteControlTests {
    /// The machine calls itself "connected" the moment remote control starts, which says
    /// nothing about whether THIS Mac accepted it. The app files an accepted device under
    /// `remote-control:<environmentId>`, so that — not the machine — is the signal.
    func testTheDeviceIDMatchesWhatTheCodexAppFilesItUnder() {
        XCTAssertEqual(CodexRemoteControl.hostID(for: "env_e_6ab9"),
                       "remote-control:env_e_6ab9")
    }

    /// A missing environment id must never read as paired, or the window would announce
    /// success and close on a machine nobody can reach.
    func testAnAbsentEnvironmentIsNeverReportedAsPaired() {
        XCTAssertFalse(CodexRemoteControl.isPaired(environmentID: nil))
        XCTAssertFalse(CodexRemoteControl.isPaired(environmentID: ""))
    }

    /// An environment the app has never seen is not paired, however healthy the machine is.
    func testAnUnknownEnvironmentIsNotPaired() {
        XCTAssertFalse(CodexRemoteControl.isPaired(
            environmentID: "env_e_definitelynotpaired0000000000"))
    }
}

extension CodexRemoteControlTests {
    /// `codex remote-control start` bootstraps a daemon Codex supervises by pid, and
    /// nothing brings it back after a reboot — a machine powered off and on again would
    /// silently drop out of "Control other devices". The unit exists to stop that.
    func testRemoteControlComesBackAfterAReboot() {
        let script = BootstrapScript.installRemoteControlService(
            BootstrapPlan(workspacePath: "/srv/workspace", remotePort: 1456))
        XCTAssertTrue(script.contains("WantedBy=multi-user.target"),
                      "without an [Install] section `enable` has nothing to hook to boot")
        XCTAssertTrue(script.contains("systemctl enable codex-remote-control.service"))
        XCTAssertTrue(script.contains("ExecStart=/usr/local/bin/codex remote-control start --json"))
    }

    /// The command bootstraps the daemon and returns, so a plain `Type=simple` unit would
    /// be considered dead the moment it succeeded.
    func testTheUnitAccountsForACommandThatReturns() {
        let script = BootstrapScript.installRemoteControlService(
            BootstrapPlan(workspacePath: "/srv/workspace", remotePort: 1456))
        XCTAssertTrue(script.contains("Type=oneshot"))
        XCTAssertTrue(script.contains("RemainAfterExit=yes"))
    }

    /// All three units follow one prefix, so `systemctl status 'codex-remote-*'` finds the
    /// lot and nothing Codex Remote installed is anonymous on the box.
    func testEveryUnitSharesTheProductPrefix() {
        for name in [BootstrapScript.serviceName,
                     BootstrapScript.claudeServiceName,
                     BootstrapScript.remoteControlServiceName] {
            XCTAssertTrue(name.hasPrefix("codex-remote-"), "\(name) breaks the pattern")
        }
    }
}
