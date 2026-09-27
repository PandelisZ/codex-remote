import XCTest
@testable import CodexRemoteKit

final class ManagedBlockTests: XCTestCase {
    func testAppendsBlockToFileWithoutOne() {
        let original = "Host github.com\n    User git\n"
        let updated = ManagedBlock.apply(body: "Include config.d/codex-remote", to: original)
        XCTAssertTrue(updated.hasPrefix(original))
        XCTAssertTrue(updated.contains("Include config.d/codex-remote"))
        XCTAssertTrue(updated.contains(ManagedBlock.begin))
        XCTAssertTrue(updated.contains(ManagedBlock.end))
    }

    func testReplacesOnlyTheManagedRegion() {
        let original = ManagedBlock.apply(body: "first", to: "before\n") + "after\n"
        let updated = ManagedBlock.apply(body: "second", to: original)
        XCTAssertTrue(updated.hasPrefix("before\n"))
        XCTAssertTrue(updated.hasSuffix("after\n"))
        XCTAssertTrue(updated.contains("second"))
        XCTAssertFalse(updated.contains("first"))
    }

    func testRepeatedWritesAreStable() {
        var text = "user content\n"
        text = ManagedBlock.apply(body: "x", to: text)
        let once = text
        text = ManagedBlock.apply(body: "x", to: text)
        XCTAssertEqual(once, text, "rewriting the same body must not grow the file")
    }

    func testRemoveLeavesUserContentIntact() {
        let original = "keep me\n"
        let withBlock = ManagedBlock.apply(body: "managed", to: original)
        XCTAssertEqual(ManagedBlock.remove(from: withBlock), original + "\n")
    }
}

final class HostAliasTests: XCTestCase {
    func testAliasIsShellAndSSHSafe() {
        XCTAssertEqual(SSHConfigManager.hostAlias(for: "Codex EU"), "codex-remote-codex-eu")
        XCTAssertEqual(SSHConfigManager.hostAlias(for: "build/box_1"), "codex-remote-build-box-1")
        XCTAssertEqual(SSHConfigManager.hostAlias(for: "  "), "codex-remote-machine")
        XCTAssertEqual(SSHConfigManager.hostAlias(for: "a--b"), "codex-remote-a-b")
    }
}

final class PortAllocatorTests: XCTestCase {
    func testSkipsPortsAlreadyClaimedByOtherMachines() {
        let port = PortAllocator.allocate(basePort: 14560, taken: [14560, 14561])
        XCTAssertGreaterThanOrEqual(port, 14562)
    }

    func testAllocatedPortIsActuallyBindable() {
        let port = PortAllocator.allocate(basePort: 14700, taken: [])
        XCTAssertTrue(PortAllocator.isFree(port))
    }
}

final class JSONStoreTests: XCTestCase {
    func testRoundTripsAndFallsBackOnMissingFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-remote-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = JSONStore<AppSettings>(url: url) { AppSettings() }
        XCTAssertEqual(store.load().basePort, 14560, "a missing file yields the fallback")

        var settings = AppSettings()
        settings.basePort = 20000
        settings.codexVersionPin = "0.157.0"
        try store.save(settings)

        XCTAssertEqual(store.load().basePort, 20000)
        XCTAssertEqual(store.load().codexVersionPin, "0.157.0")
    }

    func testCorruptFileFallsBackInsteadOfCrashing() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-remote-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try "{ not json".write(to: url, atomically: true, encoding: .utf8)

        let store = JSONStore<AppSettings>(url: url) { AppSettings() }
        XCTAssertEqual(store.load().basePort, 14560)
    }
}

final class SecretTests: XCTestCase {
    func testSecretDoesNotPrintItsValue() {
        let secret = Secret("hunter2-super-private")
        XCTAssertEqual("\(secret)", "<redacted>")
        XCTAssertFalse(String(describing: secret).contains("hunter2"))
        XCTAssertEqual(secret.fingerprintSuffix, "vate")
    }
}

/// The Codex desktop app finds remote hosts by parsing ~/.ssh/config with the `ssh-config`
/// npm package, which does not expand `Include`. Entries behind an Include are invisible
/// to it, so they have to be written into the file itself — and above any `Host *`.
final class SSHConfigPlacementTests: XCTestCase {
    func testTheBlockLeadsTheFileSoAHostStarCannotWin() {
        let user = """
        Host *
            ServerAliveInterval 60
        """
        let out = SSHConfigManager.placeAtTop(body: "Host codex-remote-demo\n    HostName 10.0.0.1",
                                              in: user)
        let block = try! XCTUnwrap(out.range(of: "Host codex-remote-demo"))
        let star = try! XCTUnwrap(out.range(of: "Host *"))
        XCTAssertTrue(block.lowerBound < star.lowerBound)
        XCTAssertTrue(out.contains("ServerAliveInterval 60"), "the user's config must survive")
    }

    func testResyncingReplacesTheBlockRatherThanStackingCopies() {
        var text = SSHConfigManager.placeAtTop(body: "Host codex-remote-one", in: "Host mine\n")
        text = SSHConfigManager.placeAtTop(body: "Host codex-remote-two", in: text)
        XCTAssertFalse(text.contains("codex-remote-one"))
        XCTAssertEqual(text.components(separatedBy: ManagedBlock.begin).count - 1, 1)
        XCTAssertTrue(text.contains("Host mine"))
    }

    func testTeardownLeavesTheUsersConfigIntact() {
        let original = "Host mine\n    HostName example.com\n"
        let withBlock = SSHConfigManager.placeAtTop(body: "Host codex-remote-demo", in: original)
        XCTAssertEqual(ManagedBlock.remove(from: withBlock).drop(while: \.isNewline),
                       original.drop(while: \.isNewline))
    }
}

/// The line under a machine's name should say something about the machine. The endpoint it
/// used to show is the same loopback address every time and tells you nothing.
final class MachineStatusLineTests: XCTestCase {
    private func machine(health: ConnectionHealth, metrics: SystemMetrics?) -> Machine {
        Machine(spec: MachineSpec(name: "box", accountID: UUID(), providerKind: .hetzner,
                                  region: "nbg1", size: "ccx13", image: "ubuntu-26.04",
                                  workspacePath: "/srv/workspace", agents: [.codex]),
                instance: Instance(id: "1", name: "box", state: .running, publicIPv4: "203.0.113.7",
                                   region: "nbg1", size: "ccx13", providerKind: .hetzner),
                stage: .ready, health: health, localPort: 14560,
                sshHostAlias: "codex-remote-box", privateKeyPath: "/tmp/k",
                metrics: metrics)
    }

    func testAnOnlineMachineReportsItsOwnLoadRatherThanALoopbackPort() {
        let sample = SystemMetrics(cpuPercent: 12.4,
                                   memoryUsedBytes: 1_288_490_188,   // 1.2 GiB
                                   memoryTotalBytes: 17_179_869_184) // 16 GiB
        let text = machine(health: .online, metrics: sample).statusText
        XCTAssertEqual(text, "CPU 12% · RAM 1.2/16 GB")
        XCTAssertFalse(text.contains("ws://"), "the endpoint is not news")
    }

    /// Before the first sample lands there is nothing to show; the row must not print an
    /// empty metrics fragment or a stray separator.
    func testAMachineWithNoSampleYetStillReadsCleanly() {
        XCTAssertEqual(machine(health: .online, metrics: nil).statusText, "Ready")
    }

    /// A machine that is not answering has a real problem to report, and load figures from
    /// the last time it worked would bury it.
    func testAnUnreachableMachineReportsTheProblemNotStaleFigures() {
        let stale = SystemMetrics(cpuPercent: 3, memoryUsedBytes: 1 << 30, memoryTotalBytes: 1 << 34)
        XCTAssertEqual(machine(health: .offline, metrics: stale).statusText, "Codex offline")
    }

    /// Memory is shown from MemAvailable, so a box with a large page cache reads as mostly
    /// free rather than nearly full.
    func testMemoryIsFormattedForGlancing() {
        let big = SystemMetrics(cpuPercent: 100, memoryUsedBytes: 12_884_901_888,
                                memoryTotalBytes: 68_719_476_736)
        XCTAssertEqual(big.summary, "CPU 100% · RAM 12/64 GB")
    }
}

/// The indicator answers one question: can I turn this machine off? Green means someone is
/// working on it, blue means it is up but idle.
extension MachineStatusLineTests {
    private func box(sessions: Int?) -> Machine {
        Machine(spec: MachineSpec(name: "box", accountID: UUID(), providerKind: .hetzner,
                                  region: "nbg1", size: "ccx13", image: "ubuntu-26.04",
                                  workspacePath: "/srv/workspace", agents: [.codex]),
                instance: Instance(id: "1", name: "box", state: .running, publicIPv4: "203.0.113.7",
                                   region: "nbg1", size: "ccx13", providerKind: .hetzner),
                stage: .ready, health: .online, localPort: 14560,
                sshHostAlias: "codex-remote-box", privateKeyPath: "/tmp/k",
                metrics: SystemMetrics(cpuPercent: 2, memoryUsedBytes: 1 << 30,
                                       memoryTotalBytes: 1 << 34),
                activeSessions: sessions)
    }

    func testAnIdleMachineSaysSoAndACountedOneSaysHowMany() {
        XCTAssertTrue(box(sessions: 0).statusText.hasPrefix("idle · "))
        XCTAssertTrue(box(sessions: 1).statusText.hasPrefix("1 session · "))
        XCTAssertTrue(box(sessions: 3).statusText.hasPrefix("3 sessions · "))
    }

    /// An unsampled machine must not read as idle: that would invite stopping a box with
    /// work on it.
    func testAnUnsampledMachineNeverClaimsToBeIdle() {
        let text = box(sessions: nil).statusText
        XCTAssertFalse(text.contains("idle"), text)
        XCTAssertFalse(text.contains("session"), text)
    }
}

/// The prompt behind the empty state's copy button. It is handed to an agent with a shell,
/// so the things it must not do matter as much as the steps.
final class SetupPromptTests: XCTestCase {
    private func prompt(hasAccount: Bool = false) -> String {
        SetupPrompt.firstMachine(hasAccount: hasAccount, cliPath: "/usr/local/bin/codex-remote")
    }

    /// An agent that guesses at a region and a size spends the user's money on the wrong
    /// machine, so the prompt has to make asking the default.
    func testItTellsTheAgentToAskRatherThanGuess() {
        let text = prompt()
        XCTAssertTrue(text.contains("asking one question at a time"))
        XCTAssertTrue(text.contains("Do not guess at flags"))
    }

    /// Creating twice means being billed twice, and there is no undo.
    func testItWarnsAgainstRunningCreateTwice() {
        XCTAssertTrue(prompt().contains("Do not run it more than once"))
    }

    /// The whole point of keychain storage is that the token never passes through a chat
    /// transcript or an argv anyone can read.
    func testItNeverAsksTheUserToHandOverAToken() {
        let text = prompt()
        XCTAssertTrue(text.contains("Do not ask me to paste the token to you"))
        XCTAssertTrue(text.contains("Never put a token in a command line argument"))
    }

    /// Codex's pairing prompt is a security control, and an agent told to "make it work"
    /// would otherwise try to route around it.
    func testItTellsTheAgentNotToBypassThePairingPrompt() {
        XCTAssertTrue(prompt().contains("do not try to work around it"))
    }

    /// With an account already set up, the token instructions are noise; without one they
    /// are the first thing needed.
    func testItAdaptsToWhetherAnAccountExists() {
        XCTAssertTrue(prompt(hasAccount: false).contains("No provider account is configured yet"))
        XCTAssertTrue(prompt(hasAccount: true).contains("already configured"))
        XCTAssertFalse(prompt(hasAccount: true).contains("No provider account is configured yet"))
    }

    /// A bare `codex-remote` is not on PATH until the shell integration is sourced, so the
    /// prompt carries the real path.
    func testItCarriesTheResolvedCLIPath() {
        XCTAssertTrue(prompt().contains("/usr/local/bin/codex-remote"))
    }
}

/// The MCP tools spend money and can destroy servers, and an agent will call them in a
/// loop. The permission table is the whole safety story, so it is pinned here.
final class MCPPermissionTests: XCTestCase {
    func testReadingIsAlwaysAllowed() {
        let locked = MCPServer.Permissions(allowWrites: false, allowDestroy: false)
        XCTAssertTrue(locked.permits(.read))
    }

    func testWritingIsOffUntilItIsTurnedOn() {
        XCTAssertFalse(MCPServer.Permissions(allowWrites: false, allowDestroy: false).permits(.write))
        XCTAssertTrue(MCPServer.Permissions(allowWrites: true, allowDestroy: false).permits(.write))
    }

    /// Creating the wrong machine costs pence; deleting the right one loses work. Allowing
    /// changes must not quietly allow deletion too.
    func testAllowingChangesDoesNotAllowDestroying() {
        let writes = MCPServer.Permissions(allowWrites: true, allowDestroy: false)
        XCTAssertTrue(writes.permits(.write))
        XCTAssertFalse(writes.permits(.destroy))
    }

    /// Destroy without write is incoherent — the UI disables it, and the model refuses to
    /// represent it rather than trusting the UI.
    func testDestroyCannotBeGrantedOnItsOwn() {
        XCTAssertFalse(MCPServer.Permissions(allowWrites: false, allowDestroy: true).permits(.destroy))
    }

    /// Every tool has to declare a level, and the money-spending ones must not be reads.
    func testTheCostlyToolsAreNotReads() {
        let byName = Dictionary(uniqueKeysWithValues: MCPServer.tools().map { ($0.name, $0.level) })
        XCTAssertEqual(byName["list_machines"], .read)
        XCTAssertEqual(byName["create_machine"], .write)
        XCTAssertEqual(byName["run_command"], .write)
        XCTAssertEqual(byName["destroy_machine"], .destroy)
    }

    /// An agent reading only the tool list must be able to tell that create bills the user.
    func testCreateWarnsAboutCostInItsDescription() {
        let create = MCPServer.tools().first { $0.name == "create_machine" }
        XCTAssertTrue(create?.description.contains("COSTS MONEY") == true)
        let destroy = MCPServer.tools().first { $0.name == "destroy_machine" }
        XCTAssertTrue(destroy?.description.contains("CANNOT BE UNDONE") == true)
    }

    /// The confirm argument exists so a hallucinated name cannot delete a real machine.
    func testDestroyRequiresAMatchingConfirmation() {
        let destroy = MCPServer.tools().first { $0.name == "destroy_machine" }
        let schema = destroy?.schema["required"] as? [String] ?? []
        XCTAssertTrue(schema.contains("confirm"))
    }
}
