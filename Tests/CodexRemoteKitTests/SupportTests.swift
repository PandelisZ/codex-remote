import XCTest
import CryptoKit
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

/// Updating an app that replaces itself. The failure modes are quiet and expensive: a
/// downgrade, a tampered download, or a bundle swapped out from under Homebrew.
final class UpdateCheckerTests: XCTestCase {
    func testNewerVersionsAreRecognised() {
        XCTAssertTrue(UpdateChecker.isNewer("0.3.0", than: "0.2.0"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0.0", than: "0.9.9"))
        XCTAssertTrue(UpdateChecker.isNewer("0.2.1", than: "0.2.0"))
        XCTAssertTrue(UpdateChecker.isNewer("v0.3.0", than: "0.2.0"), "tags carry a v")
    }

    /// The same version must never offer itself, or the app nags forever.
    func testTheSameVersionIsNotAnUpdate() {
        XCTAssertFalse(UpdateChecker.isNewer("0.2.0", than: "0.2.0"))
        XCTAssertFalse(UpdateChecker.isNewer("v0.2.0", than: "0.2.0"))
    }

    /// A feed that has rolled back must not push users backwards.
    func testAnOlderVersionIsNeverOffered() {
        XCTAssertFalse(UpdateChecker.isNewer("0.1.9", than: "0.2.0"))
        XCTAssertFalse(UpdateChecker.isNewer("0.2.0", than: "1.0.0"))
    }

    /// Shorter and longer version strings compare by position, not by length.
    func testVersionsOfDifferentLengthsCompareByComponent() {
        XCTAssertTrue(UpdateChecker.isNewer("0.2.1", than: "0.2"))
        XCTAssertFalse(UpdateChecker.isNewer("0.2", than: "0.2.0"))
        XCTAssertTrue(UpdateChecker.isNewer("0.10.0", than: "0.9.0"), "10 beats 9, not '1' vs '9'")
    }

    /// The brew command has to be the real one or the advice is worse than none.
    func testTheHomebrewAdviceNamesTheActualTap() {
        XCTAssertEqual(UpdateChecker.homebrewUpgradeCommand,
                       "brew upgrade --cask pandelisz/tap/codex-remote")
    }
}

final class UpdaterHashTests: XCTestCase {
    /// The checksum is the only thing standing between an unsigned download and whatever
    /// the network served, so it is computed over the real file rather than trusted.
    func testTheHashIsComputedOverTheFileContents() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-remote-hash-\(UUID().uuidString)")
        try Data("codex remote".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        // Independently verifiable: `printf 'codex remote' | shasum -a 256`.
        XCTAssertEqual(try Updater.sha256(of: file),
                       "08ff438edf690b1ed2301a7eae4d82e6745b9f04cb5150433cfa30327d5cc075")
    }

    /// Streaming must give the same answer as hashing in one go, including across the
    /// 1 MiB chunk boundary.
    func testStreamingMatchesForFilesLargerThanOneChunk() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-remote-big-\(UUID().uuidString)")
        try Data(repeating: 0x61, count: (1 << 20) + 1234).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let streamed = try Updater.sha256(of: file)
        let whole = SHA256.hash(data: try Data(contentsOf: file))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(streamed, whole)
    }
}

/// Codex Remote used to keep its state inside `~/.codex`, which belongs to Codex. Moving
/// out is only safe if nothing is silently lost on the way.
final class HomeMigrationTests: XCTestCase {
    /// The new home must not be inside Codex's directory any more — that was the point.
    func testTheHomeIsNoLongerInsideCodexsDirectory() {
        let home = Paths.codexRemoteHome.path
        XCTAssertFalse(home.contains("/.codex/"), home)
        XCTAssertTrue(home.hasSuffix("/.codex-remote"), home)
    }

    /// Codex's own files genuinely live in `~/.codex` and must keep being read from there.
    func testCodexsOwnDirectoryIsStillReadInPlace() {
        XCTAssertTrue(Paths.codexHome.path.hasSuffix("/.codex"))
        XCTAssertTrue(Paths.codexAuthFile.path.hasSuffix("/.codex/auth.json"))
    }

    /// Both are overridable, and independently — a test or a second install must be able to
    /// move ours without redirecting Codex's.
    func testTheTwoHomesOverrideIndependently() {
        XCTAssertNotEqual(Paths.codexRemoteHome.path, Paths.codexHome.path)
    }

    /// Merging two histories silently is worse than leaving an orphan the user can delete,
    /// so an existing destination stops the move rather than combining them.
    func testAnExistingDestinationIsNotMergedInto() {
        // Nothing to move on a machine already migrated, so this must be a no-op.
        if FileManager.default.fileExists(atPath: Paths.codexRemoteHome.path) {
            XCTAssertFalse(Paths.migrateLegacyHome(),
                           "a populated destination must never be merged into")
        }
    }
}
