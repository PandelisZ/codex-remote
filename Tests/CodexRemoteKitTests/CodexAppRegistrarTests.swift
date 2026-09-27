import XCTest
@testable import CodexRemoteKit

/// The Codex desktop app's state file belongs to the app, not to Codex Remote. These pin the two
/// properties that matter: Codex Remote can always find its own entries, and it never disturbs
/// one the user made.
final class CodexAppRegistrarTests: XCTestCase {
    private func machine(name: String, port: Int = 14560) -> Machine {
        Machine(
            spec: MachineSpec(name: name, accountID: UUID(), providerKind: .hetzner,
                              region: "fsn1", size: "ccx13", image: "ubuntu-24.04",
                              workspacePath: "/root/workspace"),
            instance: Instance(id: "1", name: name, state: .running, publicIPv4: "203.0.113.7",
                               region: "fsn1", size: "ccx13", providerKind: .hetzner),
            stage: .ready, health: .online,
            localPort: port,
            sshHostAlias: SSHConfigManager.hostAlias(for: name),
            privateKeyPath: "/tmp/id_codex-remote"
        )
    }

    func testHostIDIsDerivedFromTheMachineSoItIsStableAndFindable() {
        let machine = machine(name: "codex-eu")
        XCTAssertEqual(CodexAppRegistrar.hostID(for: machine),
                       "remote-ssh-codex-managed:\(machine.id.uuidString.lowercased())")
        // Stable across calls — the app attaches its threads to this id.
        XCTAssertEqual(CodexAppRegistrar.hostID(for: machine), CodexAppRegistrar.hostID(for: machine))
    }

    func testOwnershipIsDecidedByShapeNotByTheCurrentMachineList() {
        // Codex Remote's own entry: minted host id plus a codex-remote- alias.
        XCTAssertTrue(CodexAppRegistrar.isCodexRemoteOwned([
            "hostId": "remote-ssh-codex-managed:\(UUID().uuidString.lowercased())",
            "alias": "codex-remote-codex-eu",
        ]))

        // A machine the user added in the app by hand: same id prefix, no Codex Remote alias.
        XCTAssertFalse(CodexAppRegistrar.isCodexRemoteOwned([
            "hostId": "remote-ssh-codex-managed:8cfd5e71-3e85-4ffd-9134-6785a703d1d3",
            "alias": NSNull(),
            "hostname": "pz@100.76.53.91",
        ]))

        // A host the app discovered from ~/.ssh/config.
        XCTAssertFalse(CodexAppRegistrar.isCodexRemoteOwned([
            "hostId": "remote-ssh-discovered:vex-dev-or1",
            "alias": "vex-dev-or1",
        ]))
    }

    /// Deciding ownership structurally is what lets a machine deleted from Codex Remote have its
    /// entry cleaned up: by then its id is no longer in the machine list to match on.
    func testAnEntryForADeletedMachineIsStillRecognisedAsCodexRemotes() {
        let gone = machine(name: "deleted-box")
        let entry: [String: Any] = [
            "hostId": CodexAppRegistrar.hostID(for: gone),
            "alias": gone.sshHostAlias,
            "displayName": gone.name,
        ]
        XCTAssertTrue(CodexAppRegistrar.isCodexRemoteOwned(entry))
    }

    func testSyncResultReportsOnlyWhatActuallyChanged() {
        let nothing = CodexAppRegistrar.SyncResult(added: [], updated: [], removed: [],
                                                   codexAppWasRunning: false)
        XCTAssertFalse(nothing.changedAnything)
        XCTAssertEqual(nothing.summary, "Codex app already up to date.")

        let changed = CodexAppRegistrar.SyncResult(added: ["codex-eu"], updated: [], removed: [],
                                                   codexAppWasRunning: false)
        XCTAssertTrue(changed.summary.contains("codex-eu"))
    }
}

final class SSHTransportFailureTests: XCTestCase {
    /// Installing packages restarts services and sometimes kills the session. Retrying that
    /// is safe; retrying a script that genuinely failed is not.
    func testDroppedConnectionsAreRetryableAndScriptFailuresAreNot() {
        func result(_ code: Int32, _ stderr: String) -> CommandResult {
            CommandResult(exitCode: code, stdout: "", stderr: stderr)
        }
        XCTAssertTrue(SSHClient.isTransportFailure(result(255, "Connection reset by peer")))
        XCTAssertTrue(SSHClient.isTransportFailure(result(1, "client_loop: send disconnect: Broken pipe")))
        XCTAssertTrue(SSHClient.isTransportFailure(result(255, "")))
        XCTAssertFalse(SSHClient.isTransportFailure(result(1, "E: Unable to locate package nope")))
        XCTAssertFalse(SSHClient.isTransportFailure(result(100, "dpkg was interrupted")))
    }
}

final class CapabilityFilteringTests: XCTestCase {
    private let capabilities = ProviderCapabilities(
        regions: [Region(slug: "fsn1", name: "Falkenstein"), Region(slug: "hel1", name: "Helsinki")],
        sizes: [
            InstanceSize(slug: "cx23", name: "CX23", vcpus: 2, memoryGB: 4, diskGB: 40,
                         availableRegions: ["hel1"], architecture: "x86"),
            InstanceSize(slug: "cax11", name: "CAX11", vcpus: 2, memoryGB: 4, diskGB: 40,
                         availableRegions: ["fsn1", "hel1"], architecture: "arm"),
        ],
        images: [
            OSImage(slug: "ubuntu-24.04", name: "Ubuntu 24.04 (x86)", family: "ubuntu", architecture: "x86"),
            OSImage(slug: "ubuntu-24.04", name: "Ubuntu 24.04 (ARM)", family: "ubuntu", architecture: "arm"),
        ],
        recommendedImage: "ubuntu-24.04",
        recommendedSize: "cx23",
        recommendedRegion: "fsn1"
    )

    /// Hetzner prices types in locations it does not stock them in, and answers a create
    /// there with a bare "unsupported location for server type" — so the form must filter.
    func testOnlyTypesStockedInTheRegionAreOffered() {
        XCTAssertEqual(capabilities.sizes(in: "fsn1").map(\.slug), ["cax11"])
        XCTAssertEqual(Set(capabilities.sizes(in: "hel1").map(\.slug)), ["cx23", "cax11"])
    }

    /// An x86 image on an ARM server type is rejected at create time.
    func testImagesAreFilteredToTheServerTypeArchitecture() {
        XCTAssertEqual(capabilities.images(for: "cax11").map(\.architecture), ["arm"])
        XCTAssertEqual(capabilities.images(for: "cx23").map(\.architecture), ["x86"])
    }

    func testImagesWithTheSameSlugAreStillDistinguishable() {
        let ids = Set(capabilities.images.map(\.id))
        XCTAssertEqual(ids.count, 2, "x86 and ARM images share a slug and must not collide")
    }

    func testUnknownSizeFallsBackToTheWholeImageListRatherThanNothing() {
        XCTAssertEqual(capabilities.images(for: "does-not-exist").count, 2)
    }
}

extension CodexAppRegistrarTests {
    /// The app holds this state in memory and writes the whole file back on its own
    /// schedule, so an edit made under a running app is overwritten and the entry is
    /// silently gone. Reporting "added" in that case is a lie, and it was one: codex-demo
    /// was reported as added and never appeared.
    func testItRefusesToWriteWhileTheCodexAppIsRunning() throws {
        guard CodexAppRegistrar.isCodexAppRunning else {
            throw XCTSkip("Codex app is not running; this path cannot be exercised")
        }
        XCTAssertThrowsError(try CodexAppRegistrar.sync(machines: [])) { error in
            guard case CodexAppRegistrar.Failure.codexAppRunning = error else {
                return XCTFail("expected codexAppRunning, got \(error)")
            }
        }
    }

    /// Discovery is the documented path and needs no state-file surgery, so the message
    /// must point at it rather than reading as a failure.
    func testTheRunningAppMessageExplainsDiscoveryStillWorks() {
        let text = CodexAppRegistrar.Failure.codexAppRunning.errorDescription ?? ""
        XCTAssertTrue(text.contains(".ssh/config"))
        XCTAssertTrue(text.lowercased().contains("discover"))
    }
}
