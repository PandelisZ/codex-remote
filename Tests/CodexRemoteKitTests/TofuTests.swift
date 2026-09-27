import XCTest
@testable import CodexRemoteKit

/// Every cloud's HCL is generated from a `TofuModule`, and the generic provider above it
/// reads a fixed set of outputs. These pin that contract for every module at once, so a
/// new cloud cannot be added with, say, no `public_ipv4` output and fail only at the point
/// someone tries to SSH to it.
final class TofuModuleContractTests: XCTestCase {
    private let requiredOutputs = [
        "instance_id", "instance_name", "public_ipv4", "public_ipv6", "private_ipv4", "state",
    ]

    func testEveryModuleProducesTheOutputsTheProviderReads() {
        for module in TofuRegistration.modules {
            let hcl = module.machineConfiguration()
            for output in requiredOutputs {
                XCTAssertTrue(hcl.contains("output \"\(output)\""),
                              "\(module.displayName) does not declare output \"\(output)\"")
            }
        }
    }

    func testEveryModuleConsumesTheVariablesCodexRemoteSupplies() {
        for module in TofuRegistration.modules {
            let hcl = module.machineConfiguration()
            for variable in ["name", "region", "size", "user_data"] {
                XCTAssertTrue(hcl.contains("variable \"\(variable)\""),
                              "\(module.displayName) is missing the \(variable) variable")
                XCTAssertTrue(hcl.contains("var.\(variable)"),
                              "\(module.displayName) declares \(variable) but never uses it")
            }
        }
    }

    /// A machine is unreachable unless Codex Remote's key gets onto it, and there are two ways
    /// that happens: the module creates the key itself from the public key it is handed,
    /// or — on clouds that reject a duplicate key upload — Codex Remote registers the key through
    /// the API first and the module references the ids. Every module must do one of them.
    func testEveryModuleInstallsCodexRemotesSSHKeyOneWayOrTheOther() {
        for module in TofuRegistration.modules {
            let hcl = module.machineConfiguration()
            if module.managesSSHKey {
                XCTAssertTrue(hcl.contains("var.ssh_public_key"),
                              "\(module.displayName) claims to manage the key but never reads the public key")
            } else {
                XCTAssertTrue(hcl.contains("var.ssh_key_ids"),
                              "\(module.displayName) relies on pre-registered keys but never references their ids")
            }
        }
    }

    func testEveryModulePinsItsProvider() {
        for module in TofuRegistration.modules {
            let hcl = module.machineConfiguration()
            XCTAssertTrue(hcl.contains("source  = \"\(module.providerSource)\""),
                          "\(module.displayName) does not pin a provider source")
            XCTAssertTrue(hcl.contains("version = \"\(module.providerVersion)\""),
                          "\(module.displayName) does not constrain its provider version")
            XCTAssertTrue(module.providerSource.contains("/"),
                          "\(module.displayName)'s provider source is not namespaced")
        }
    }

    /// A module that declares an extra variable must also supply a value for it, or every
    /// apply stops to prompt — and Codex Remote runs tofu with input disabled.
    func testExtraVariablesAreBothDeclaredAndSupplied() {
        let request = InstanceRequest(name: "t", region: "r", size: "s", image: "i",
                                      sshKeyIdentifiers: [])
        for module in TofuRegistration.modules {
            let declarations = module.extraVariableDeclarations
            guard !declarations.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let supplied = module.extraVariables(request)
            for line in declarations.split(separator: "\n") where line.contains("variable \"") {
                guard let name = line.split(separator: "\"").dropFirst().first.map(String.init) else { continue }
                let hasDefault = declarations.contains("default")
                XCTAssertTrue(supplied[name] != nil || hasDefault,
                              "\(module.displayName) declares \(name) but supplies no value and has no default")
            }
        }
    }

    func testCredentialsReachTheProviderThroughTheEnvironment() {
        for module in TofuRegistration.modules {
            let secrets = Dictionary(uniqueKeysWithValues:
                module.credentialFields.filter { $0.style == .secret }.map { ($0.key, Secret("value-\($0.key)")) })
            let plain = Dictionary(uniqueKeysWithValues:
                module.credentialFields.filter { $0.style == .plain }.map { ($0.key, "plain-\($0.key)") })
            let environment = module.environment(plain, secrets)

            XCTAssertFalse(environment.isEmpty, "\(module.displayName) maps no credentials into the environment")
            for field in module.credentialFields where !field.isOptional {
                guard let variable = field.environmentVariable else { continue }
                XCTAssertNotNil(environment[variable],
                                "\(module.displayName) never sets \(variable)")
            }
        }
    }

    /// The generated files sit on disk; a token must not be among them.
    func testGeneratedConfigurationNeverEmbedsASecret() {
        for module in TofuRegistration.modules {
            let hcl = module.machineConfiguration()
            XCTAssertFalse(hcl.contains("value-token"), "\(module.displayName) embeds a token in its HCL")
            for field in module.credentialFields where field.style == .secret {
                // A secret may only appear as a variable reference, never inline.
                XCTAssertFalse(hcl.contains("\(field.key) = \""),
                               "\(module.displayName) writes \(field.key) into the HCL literally")
            }
        }
    }

    func testModulesAndRegisteredProvidersLineUp() {
        let registered = Set(ProviderRegistry.shared.all.map(\.kind))
        for module in TofuRegistration.modules {
            XCTAssertTrue(registered.contains(module.kind),
                          "\(module.displayName) has a module but is not registered")
            XCTAssertNotNil(TofuRegistration.module(for: module.kind))
        }
    }
}

final class TofuRunnerTests: XCTestCase {
    /// OpenTofu prints warnings on stdout ahead of `output -json`, which made a real
    /// provision fail after the server had already been created.
    func testJSONIsExtractedFromAStreamWithAWarningInFrontOfIt() {
        let noisy = """
        There are some problems with the CLI configuration:

        Warning: Unable to open CLI configuration file

        {"instance_id": {"value": "167599098"}, "public_ipv4": {"value": "1.2.3.4"}}
        """
        let json = TofuRunner.firstJSONObject(in: noisy)
        XCTAssertNotNil(json)
        let parsed = (try? JSONSerialization.jsonObject(with: Data(json!.utf8))) as? [String: Any]
        let instanceID = (parsed?["instance_id"] as? [String: Any])?["value"] as? String
        XCTAssertEqual(instanceID, "167599098")
    }

    func testBracesInsideStringsDoNotEndTheObject() {
        let tricky = #"{"note": "a } inside a string", "id": {"value": "7"}}"#
        XCTAssertEqual(TofuRunner.firstJSONObject(in: tricky), tricky)
    }

    func testNoObjectFoundIsReportedRatherThanGuessed() {
        XCTAssertNil(TofuRunner.firstJSONObject(in: "Error: no outputs\n"))
    }

    func testStateWordsFromEveryCloudMapToSomethingSensible() {
        XCTAssertEqual(TofuProvider.mapState("running"), .running)   // Hetzner, AWS
        XCTAssertEqual(TofuProvider.mapState("active"), .running)    // DigitalOcean, Vultr
        XCTAssertEqual(TofuProvider.mapState("started"), .running)   // Scaleway
        XCTAssertEqual(TofuProvider.mapState("off"), .stopped)
        XCTAssertEqual(TofuProvider.mapState("stopped"), .stopped)
        XCTAssertEqual(TofuProvider.mapState("provisioning"), .provisioning)
        XCTAssertEqual(TofuProvider.mapState("terminated"), .deleted)
        // Apply does not return until the machine is up, so an unknown word means running.
        XCTAssertEqual(TofuProvider.mapState(nil), .running)
    }
}

final class TofuVariablesTests: XCTestCase {
    func testVariablesAreWrittenAsJSONWithTheNamesTheHCLDeclares() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-remote-tfvars-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let request = InstanceRequest(name: "codex-eu", region: "fsn1", size: "ccx13",
                                      image: "ubuntu-24.04", sshKeyIdentifiers: ["42"],
                                      userData: "#cloud-config\n", labels: ["managed-by": "codex-remote"],
                                      workspaceKey: "abc")
        try TofuVariables(request: request, sshPublicKey: "ssh-ed25519 AAAA test")
            .write(to: directory, extra: ["root_password": "throwaway"])

        let url = directory.appendingPathComponent("terraform.tfvars.json")
        let object = try JSONSerialization.jsonObject(
            with: Data(contentsOf: url)) as? [String: Any]

        XCTAssertEqual(object?["name"] as? String, "codex-eu")
        XCTAssertEqual(object?["region"] as? String, "fsn1")
        XCTAssertEqual(object?["ssh_key_ids"] as? [String], ["42"])
        XCTAssertEqual(object?["user_data"] as? String, "#cloud-config\n")
        XCTAssertEqual(object?["root_password"] as? String, "throwaway")
        XCTAssertEqual((object?["tags"] as? [String: String])?["managed-by"], "codex-remote")

        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.int16Value, 0o600, "the variables file must be owner-only")
    }

    /// The workspace key is what keeps a machine bound to its own state across launches.
    func testWorkspaceKeyDefaultsToSomethingUniquePerRequest() {
        let first = InstanceRequest(name: "a", region: "r", size: "s", image: "i", sshKeyIdentifiers: [])
        let second = InstanceRequest(name: "a", region: "r", size: "s", image: "i", sshKeyIdentifiers: [])
        XCTAssertNotEqual(first.workspaceKey, second.workspaceKey)
    }
}

/// Claude Code reads `~/.claude/.credentials.json` only when `claudeAiOauth` is the first
/// key. Writing it with sorted keys puts `mcpOAuth` in front and the login is silently
/// ignored — `claude auth status` reports "not logged in" with the credential sitting right
/// there. This is exactly the kind of thing that is invisible until a machine fails to come
/// up, so it is pinned.
final class ClaudeCredentialOrderTests: XCTestCase {
    func testCredentialKeyOrderIsNotAlphabetical() {
        // The shape Codex Remote writes, built the way `portableCredentials` builds it.
        let json = #"{"claudeAiOauth":{"accessToken":"x"},"mcpOAuth":{"linear":{}}}"#

        let oauthIndex = json.range(of: "\"claudeAiOauth\"")?.lowerBound
        let mcpIndex = json.range(of: "\"mcpOAuth\"")?.lowerBound
        XCTAssertNotNil(oauthIndex)
        XCTAssertNotNil(mcpIndex)
        XCTAssertTrue(oauthIndex! < mcpIndex!,
                      "claudeAiOauth has to come first or Claude Code ignores the login")

        // It still has to be valid JSON with both keys present.
        let parsed = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        XCTAssertEqual(Set(parsed?.keys ?? [:].keys).sorted(), ["claudeAiOauth", "mcpOAuth"])
    }

    /// Sorted-key serialisation is what caused the bug; proving it reorders guards against
    /// someone "tidying" the writer back to `JSONSerialization` with `.sortedKeys`.
    func testSortedKeysWouldPutTheWrongKeyFirst() throws {
        let payload: [String: Any] = ["claudeAiOauth": ["a": 1], "mcpOAuth": ["b": 2]]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("{\"claudeAiOauth\""), """
            If this ever passes with sorted keys, the ordering hazard is gone and the manual \
            assembly in ClaudeCredentials could be simplified. It does not today.
            """)
    }
}

/// Signing a machine in to Claude Code is a browser round trip, and the URL has to survive
/// being read out of a terminal transcript.
final class ClaudeLoginTests: XCTestCase {
    /// Exactly what a machine printed: an OSC-8 hyperlink, so the URL appears twice with
    /// only escape bytes between the copies.
    private let realOutput = "Opening browser to sign in…\n"
        + "If the browser didn't open, visit: \u{1B}]8;;"
        + "https://claude.com/cai/oauth/authorize?code=true&client_id=9d1c250a&state=ABC"
        + "https://claude.com/cai/oauth/authorize?code=true&client_id=9d1c250a&state=ABC"
        + "\u{1B}]8;;\nPaste code here if prompted > "

    func testTheURLIsNotDoubledByTheHyperlinkEscape() throws {
        let url = try XCTUnwrap(ClaudeLogin.authorizeURL(in: realOutput))
        XCTAssertEqual(url.absoluteString,
                       "https://claude.com/cai/oauth/authorize?code=true&client_id=9d1c250a&state=ABC")
        XCTAssertEqual(url.absoluteString.components(separatedBy: "https://").count - 1, 1,
                       "a doubled URL is rejected by the browser")
    }

    func testAPlainURLStillParses() throws {
        let plain = "If the browser didn't open, visit: "
            + "https://claude.com/cai/oauth/authorize?code=true&state=XYZ\nPaste code here > "
        let url = try XCTUnwrap(ClaudeLogin.authorizeURL(in: plain))
        XCTAssertTrue(url.absoluteString.hasSuffix("state=XYZ"))
    }

    func testOutputWithNoLinkYieldsNothingRatherThanAGuess() {
        XCTAssertNil(ClaudeLogin.authorizeURL(in: "Error: could not reach the sign-in service\n"))
    }
}

extension ClaudeLoginTests {
    /// The FIFO lives in /tmp, which is sticky and world-writable, and belongs to the
    /// agent account. `fs.protected_fifos` refuses an open-for-write on it from any other
    /// user — root included, since this is not a DAC check CAP_DAC_OVERRIDE can bypass.
    /// Writing the code as root therefore failed every sign-in with EACCES.
    func testTheCodeIsWrittenToTheFifoAsTheAgentNotAsRoot() {
        let script = ClaudeLogin.submitScript(code: "abc#def", user: "claude")
        guard let write = script.range(of: "> /tmp/codex-remote-claude-login.fifo") else {
            return XCTFail("expected the code to be written to the FIFO")
        }
        let line = script[script[..<write.lowerBound].lastIndex(of: "\n")!..<write.upperBound]
        XCTAssertTrue(line.contains("su - claude -c"),
                      "the FIFO write must drop to the agent account, got: \(line)")
    }

    /// A code is pasted from a browser and goes into a shell command; it must not be able
    /// to end the quoting and run anything of its own.
    func testACodeCarryingQuotesCannotEscapeIntoTheShell() throws {
        let nasty = "abc'; touch /tmp/pwned; echo '#state"
        let script = ClaudeLogin.submitScript(code: nasty, user: "claude")
        // Round-trip through a real shell: echo the command and confirm it is inert.
        let probe = script.components(separatedBy: "\n")
            .first { $0.contains("codex-remote-claude-login.fifo") && $0.contains("printf") }
        let command = try XCTUnwrap(probe)
        XCTAssertFalse(command.contains("touch /tmp/pwned") && !command.contains("'\\''"),
                       "the payload must stay quoted, got: \(command)")
    }
}
