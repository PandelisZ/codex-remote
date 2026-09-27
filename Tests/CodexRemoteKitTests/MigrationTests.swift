import XCTest
@testable import CodexRemoteKit

/// The machine registry is a file on disk that older builds wrote. Swift's synthesized
/// `Codable` treats a missing key as a decoding error even when the property has a default,
/// so adding a field would make every previously saved machine fail to decode — and since
/// `JSONStore` falls back to an empty registry, the user's machines would simply vanish.
///
/// These decode the exact shape earlier versions wrote.
final class RegistryMigrationTests: XCTestCase {
    /// A registry written before Codex Remote knew about Claude Code or MCP syncing.
    private let legacyJSON = """
    {
      "version": 1,
      "machines": [
        {
          "id": "E7665BE4-DECD-409B-A8A7-102B59F7D4A3",
          "spec": {
            "accountID": "00000000-0000-4000-A000-000000000001",
            "extraPackages": [],
            "idleShutdownMinutes": 0,
            "image": "ubuntu-24.04",
            "name": "codex-eu",
            "providerKind": "hetzner",
            "region": "fsn1",
            "size": "ccx13",
            "sshPort": 22,
            "syncCodexCredentials": true,
            "workspacePath": "/root/workspace"
          },
          "createdAt": "2026-09-26T20:00:00Z",
          "health": "online",
          "localPort": 14560,
          "powerIntent": "up",
          "privateKeyPath": "/Users/example/.codex-remote/keys/id_codex-remote",
          "remotePort": 1456,
          "sshHostAlias": "codex-remote-codex-eu",
          "sshPort": 22,
          "sshUser": "root",
          "stage": "ready"
        }
      ]
    }
    """

    private func decode(_ json: String) throws -> MachineRegistry {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MachineRegistry.self, from: Data(json.utf8))
    }

    func testAMachineSavedBeforeClaudeSupportStillLoads() throws {
        let registry = try decode(legacyJSON)
        XCTAssertEqual(registry.machines.count, 1, "the machine must survive the upgrade")

        let machine = try XCTUnwrap(registry.machines.first)
        XCTAssertEqual(machine.name, "codex-eu")
        XCTAssertEqual(machine.sshHostAlias, "codex-remote-codex-eu")
        XCTAssertEqual(machine.stage, .ready)
        XCTAssertEqual(machine.localPort, 14560)
    }

    /// A machine from before the split ran Codex, so that is what it must come back as —
    /// not "both", which would have Codex Remote try to start an agent that was never installed.
    func testLegacyMachinesDefaultToCodexOnly() throws {
        let machine = try XCTUnwrap(decode(legacyJSON).machines.first)
        XCTAssertEqual(machine.spec.agents, [.codex])
        XCTAssertTrue(machine.runs(.codex))
        XCTAssertFalse(machine.runs(.claudeCode))
        XCTAssertTrue(machine.needsTunnel)
        XCTAssertTrue(machine.agentStatuses.isEmpty)
    }

    func testNewOptionsTakeSensibleDefaultsWhenAbsent() throws {
        let machine = try XCTUnwrap(decode(legacyJSON).machines.first)
        XCTAssertTrue(machine.spec.syncMCPServers, "syncing MCP servers is the default")
        XCTAssertEqual(machine.spec.sshPort, 22)
    }

    /// An existing machine keeps the workspace it was built with. Silently moving it to the
    /// new shared location would point Codex Remote at a directory that machine does not have.
    func testAnExistingMachineKeepsItsOriginalWorkspace() throws {
        let noWorkspace = """
        {"version":1,"machines":[{
          "id":"11111111-1111-1111-1111-111111111111",
          "spec":{"accountID":"22222222-2222-2222-2222-222222222222","image":"ubuntu-24.04",
                  "name":"old","providerKind":"hetzner","region":"fsn1","size":"cx23"},
          "privateKeyPath":"/tmp/key","sshHostAlias":"codex-remote-old"}]}
        """
        let machine = try XCTUnwrap(decode(noWorkspace).machines.first)
        XCTAssertEqual(machine.spec.workspacePath, "/root/workspace")

        // And a new one gets the shared location.
        XCTAssertEqual(MachineSpec(name: "new", accountID: UUID(), providerKind: .hetzner,
                                   region: "fsn1", size: "cx23", image: "ubuntu-26.04").workspacePath,
                       "/srv/workspace")
    }

    /// A registry written by *this* build has to round-trip too, or the next launch loses
    /// everything that was just saved.
    func testCurrentFormatRoundTrips() throws {
        var machine = try XCTUnwrap(decode(legacyJSON).machines.first)
        machine.spec.agents = [.codex, .claudeCode]
        machine.agentStatuses = [
            AgentStatus(kind: .claudeCode, isRunning: true,
                        endpoint: "https://claude.ai/code/session_abc"),
        ]

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(MachineRegistry(machines: [machine]))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let round = try decoder.decode(MachineRegistry.self, from: data)

        XCTAssertEqual(round.machines.first?.spec.agents, [.codex, .claudeCode])
        XCTAssertEqual(round.machines.first?.claudeSessionURL,
                       "https://claude.ai/code/session_abc")
    }

    /// The minimum a record can contain and still be usable.
    func testAMinimalRecordDecodes() throws {
        let minimal = """
        {"version":1,"machines":[{
          "id":"11111111-1111-1111-1111-111111111111",
          "spec":{"accountID":"22222222-2222-2222-2222-222222222222","image":"ubuntu-24.04",
                  "name":"bare","providerKind":"hetzner","region":"fsn1","size":"cx23"},
          "privateKeyPath":"/tmp/key","sshHostAlias":"codex-remote-bare"
        }]}
        """
        let machine = try XCTUnwrap(decode(minimal).machines.first)
        XCTAssertEqual(machine.name, "bare")
        XCTAssertEqual(machine.spec.workspacePath, "/root/workspace")
        XCTAssertEqual(machine.stage, .queued)
        XCTAssertEqual(machine.powerIntent, .up)
    }
}

/// The data-loss hazard is not specific to `Machine` — it applies to every type Codex Remote
/// persists. These decode the smallest legal JSON for each, which is what a registry
/// written by an older build effectively is.
final class PersistedTypeToleranceTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(json.utf8))
    }

    func testSettingsSurviveFieldsBeingAdded() throws {
        // A settings file from before Codex-app registration or MCP syncing existed.
        let settings = try decode(AppSettings.self, #"{"basePort":14560}"#)
        XCTAssertEqual(settings.basePort, 14560)
        // New machines get the shared workspace, which the Claude account can reach.
        XCTAssertEqual(settings.defaultWorkspacePath, "/srv/workspace")
        XCTAssertTrue(settings.registerWithCodexApp)
        XCTAssertEqual(settings.healthPollSeconds, 15)
    }

    func testAnEmptySettingsObjectIsAllDefaults() throws {
        let settings = try decode(AppSettings.self, "{}")
        XCTAssertEqual(settings.basePort, AppSettings().basePort)
    }

    func testProviderAccountsSurvive() throws {
        let account = try decode(ProviderAccount.self, """
        {"id":"11111111-1111-1111-1111-111111111111","kind":"hetzner"}
        """)
        XCTAssertEqual(account.kind, .hetzner)
        XCTAssertEqual(account.label, "hetzner")
        XCTAssertTrue(account.plainFields.isEmpty)
    }

    func testInstancesSurvive() throws {
        let instance = try decode(Instance.self, #"{"id":"167599098"}"#)
        XCTAssertEqual(instance.id, "167599098")
        XCTAssertEqual(instance.state, .unknown)
        XCTAssertEqual(instance.region, "unknown")
    }

    func testAgentStatusSurvives() throws {
        let status = try decode(AgentStatus.self, #"{"kind":"claude-code"}"#)
        XCTAssertEqual(status.kind, .claudeCode)
        XCTAssertFalse(status.isRunning)
    }

    /// The worst case: one record in the file is corrupt. Losing that one is acceptable;
    /// losing the whole registry is not.
    func testOneBrokenMachineDoesNotEmptyTheRegistry() throws {
        let mixed = """
        {"version":1,"machines":[
          {"id":"11111111-1111-1111-1111-111111111111",
           "spec":{"accountID":"22222222-2222-2222-2222-222222222222","image":"ubuntu-26.04",
                   "name":"good","providerKind":"hetzner","region":"fsn1","size":"cx23"},
           "privateKeyPath":"/tmp/key","sshHostAlias":"codex-remote-good"},
          {"id":"not-a-uuid","spec":{}},
          {"id":"33333333-3333-3333-3333-333333333333",
           "spec":{"accountID":"22222222-2222-2222-2222-222222222222","image":"ubuntu-26.04",
                   "name":"also-good","providerKind":"hetzner","region":"fsn1","size":"cx23"},
           "privateKeyPath":"/tmp/key","sshHostAlias":"codex-remote-also-good"}
        ]}
        """
        let registry = try decode(MachineRegistry.self, mixed)
        XCTAssertEqual(registry.machines.map(\.name), ["good", "also-good"],
                       "the readable machines must survive a broken sibling")
    }

    func testAccountRegistryToleratesAMissingList() throws {
        XCTAssertTrue(try decode(AccountRegistry.self, #"{"version":1}"#).accounts.isEmpty)
    }
}
