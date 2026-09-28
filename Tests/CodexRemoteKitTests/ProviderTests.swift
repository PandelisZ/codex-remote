import XCTest
@testable import CodexRemoteKit

final class SigV4Tests: XCTestCase {
    /// AWS publishes a signature test suite; `get-vanilla` is its simplest case and pins
    /// the canonical-request construction, the signing-key chain and the header format.
    func testMatchesAWSGetVanillaVector() {
        let signer = SigV4Signer(
            accessKeyID: "AKIDEXAMPLE",
            secretAccessKey: Secret("wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"),
            region: "us-east-1",
            service: "service"
        )
        var components = DateComponents()
        components.year = 2015; components.month = 8; components.day = 30
        components.hour = 12; components.minute = 36; components.second = 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: components)!

        let headers = signer.sign(method: "GET", host: "example.amazonaws.com",
                                  body: Data(), now: date)
        XCTAssertEqual(
            headers["Authorization"],
            "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, "
            + "SignedHeaders=host;x-amz-date, "
            + "Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31"
        )
    }

    func testFormBodyIsSortedAndRFC3986Encoded() {
        let body = SigV4Signer.formBody(["Version": "2016-11-15", "Action": "RunInstances",
                                         "Tag": "a b/c~d"])
        XCTAssertEqual(String(decoding: body, as: UTF8.self),
                       "Action=RunInstances&Tag=a%20b%2Fc~d&Version=2016-11-15")
    }
}

final class HetznerMappingTests: XCTestCase {
    func testStatusMapping() {
        XCTAssertEqual(HetznerProvider.mapState("initializing"), .provisioning)
        XCTAssertEqual(HetznerProvider.mapState("running"), .running)
        XCTAssertEqual(HetznerProvider.mapState("off"), .stopped)
        XCTAssertEqual(HetznerProvider.mapState("deleting"), .deleting)
        XCTAssertEqual(HetznerProvider.mapState("something-new"), .unknown)
    }

    /// Hetzner hands back a /64 network; SSH needs a single address.
    func testIPv6NetworkBecomesAnAddress() {
        XCTAssertEqual(HetznerProvider.firstIPv6Address("2a01:4f8:c17:1::/64"), "2a01:4f8:c17:1::1")
        XCTAssertEqual(HetznerProvider.firstIPv6Address("2a01:4f8::5"), "2a01:4f8::5")
    }
}

final class AWSMappingTests: XCTestCase {
    func testStatusMapping() {
        XCTAssertEqual(AWSProvider.mapState("pending"), .provisioning)
        XCTAssertEqual(AWSProvider.mapState("running"), .running)
        XCTAssertEqual(AWSProvider.mapState("terminated"), .deleted)
    }
}

final class DigitalOceanMappingTests: XCTestCase {
    func testStatusMapping() {
        XCTAssertEqual(DigitalOceanProvider.mapState("new"), .provisioning)
        XCTAssertEqual(DigitalOceanProvider.mapState("active"), .running)
        XCTAssertEqual(DigitalOceanProvider.mapState("off"), .stopped)
        XCTAssertEqual(DigitalOceanProvider.mapState(nil), .unknown)
    }
}

final class XMLTreeTests: XCTestCase {
    func testParsesNestedEC2Shapes() throws {
        let xml = """
        <DescribeInstancesResponse>
          <reservationSet>
            <item>
              <instancesSet>
                <item>
                  <instanceId>i-abc</instanceId>
                  <instanceState><name>running</name></instanceState>
                  <tagSet><item><key>Name</key><value>codex-eu</value></item></tagSet>
                </item>
              </instancesSet>
            </item>
          </reservationSet>
        </DescribeInstancesResponse>
        """
        let tree = try XCTUnwrap(XMLTreeNode.parse(Data(xml.utf8)))
        let instance = try XCTUnwrap(tree.find("instancesSet")?.all("item").first)
        XCTAssertEqual(instance["instanceId"]?.trimmedText, "i-abc")
        XCTAssertEqual(instance["instanceState"]?["name"]?.trimmedText, "running")
        XCTAssertEqual(instance.find("tagSet")?.all("item").first?["value"]?.trimmedText, "codex-eu")
    }
}

final class ProviderRegistryTests: XCTestCase {
    func testEveryRegisteredProviderIsDescribedWellEnoughToRenderAForm() {
        let descriptors = ProviderRegistry.shared.all
        XCTAssertTrue(descriptors.contains { $0.kind == .hetzner })
        XCTAssertTrue(descriptors.contains { $0.kind == .aws })
        XCTAssertTrue(descriptors.contains { $0.kind == .digitalOcean })
        XCTAssertTrue(descriptors.contains { $0.kind == .existingHost })
        for descriptor in descriptors {
            XCTAssertFalse(descriptor.displayName.isEmpty)
            XCTAssertFalse(descriptor.blurb.isEmpty)
            XCTAssertFalse(descriptor.credentialFields.isEmpty, "\(descriptor.kind) needs at least one field")
            for field in descriptor.credentialFields {
                XCTAssertFalse(field.label.isEmpty)
                XCTAssertFalse(field.help.isEmpty, "\(descriptor.kind).\(field.key) needs help text")
            }
        }
    }

    func testMissingCredentialsFailBeforeAnyNetworkCall() {
        let account = ProviderAccount(kind: .hetzner, label: "empty")
        let store = InMemoryCredentialStore()
        XCTAssertThrowsError(try ProviderRegistry.shared.provider(for: account, credentials: store)) { error in
            XCTAssertTrue("\(error)".contains("token") || error.localizedDescription.contains("API token"))
        }
    }
}

final class MockProviderTests: XCTestCase {
    func testCreateThenPowerThenDestroy() async throws {
        let provider = MockProvider()
        let identity = try await provider.verify()
        XCTAssertFalse(identity.accountLabel.isEmpty)

        let capabilities = try await provider.capabilities()
        let request = InstanceRequest(name: "t", region: capabilities.recommendedRegion,
                                      size: capabilities.recommendedSize,
                                      image: capabilities.recommendedImage,
                                      sshKeyIdentifiers: ["k"])
        let instance = try await provider.createInstance(request)
        XCTAssertEqual(instance.state, .running)
        XCTAssertNotNil(instance.sshAddress)

        try await provider.power(.stop, instanceID: instance.id)
        let stopped = try await provider.instance(id: instance.id)
        XCTAssertEqual(stopped?.state, .stopped)

        try await provider.destroyInstance(id: instance.id)
        let gone = try await provider.instance(id: instance.id)
        XCTAssertNil(gone)
    }

    func testWaitForRunningPollsUntilTheInstanceBoots() async throws {
        let provider = MockProvider(bootDelay: 2)
        let instance = try await provider.createInstance(
            InstanceRequest(name: "slow", region: "local-1", size: "small",
                            image: "ubuntu-24.04", sshKeyIdentifiers: []))
        XCTAssertEqual(instance.state, .provisioning)
        let running = try await provider.waitForRunningInstance(id: instance.id, timeout: 30)
        XCTAssertEqual(running.state, .running)
    }
}

final class StaticHostProviderTests: XCTestCase {
    func testRefusesToDestroyOrPowerCycleAMachineItDidNotCreate() async {
        let provider = StaticHostProvider(address: "203.0.113.9", user: "ubuntu")
        do {
            try await provider.destroyInstance(id: "static:203.0.113.9")
            XCTFail("destroying an adopted host must be refused")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("did not create"))
        }
        do {
            try await provider.power(.stop, instanceID: "static:203.0.113.9")
            XCTFail("power-cycling an adopted host must be refused")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("did not create"))
        }
    }

    func testReportsTheConfiguredLoginUser() async throws {
        let provider = StaticHostProvider(address: "203.0.113.9", user: "ubuntu")
        XCTAssertEqual(provider.defaultSSHUser(forImage: "existing"), "ubuntu")
        let instance = try await provider.createInstance(
            InstanceRequest(name: "box", region: "self-hosted", size: "existing",
                            image: "existing", sshKeyIdentifiers: []))
        XCTAssertEqual(instance.sshAddress, "203.0.113.9")
    }
}

/// EC2 refuses anything outside ASCII in `ImportKeyPair` and `CreateSecurityGroup`, and
/// rejects the whole request rather than the offending field. Both inputs reach it from
/// places that looked harmless: the key comment is built from the Mac's name, and macOS
/// names a machine "<Owner>’s MacBook Pro" with a curly apostrophe.
final class ASCIISafetyTests: XCTestCase {
    func testCurlyApostropheInTheMacNameIsFlattened() {
        let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIexample codex-remote@Pandelis\u{2019}s MacBook Pro"
        let cleaned = SSHKeyManager.asciiPublicKey(key)
        XCTAssertEqual(cleaned, "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIexample codex-remote@Pandelis's MacBook Pro")
        XCTAssertTrue(cleaned.allSatisfy(\.isASCII))
    }

    func testTheKeyBlobIsNeverRewritten() {
        // Rewriting the algorithm or the base64 would produce a different key, which would
        // fail authentication rather than provisioning — a much worse failure.
        let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIexample+/=  trailing"
        let blob = SSHKeyManager.asciiPublicKey(key).split(separator: " ")[1]
        XCTAssertEqual(blob, "AAAAC3NzaC1lZDI1NTE5AAAAIexample+/=")
    }

    func testCommentlessKeySurvives() {
        let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIexample"
        XCTAssertEqual(SSHKeyManager.asciiPublicKey(key), key)
    }

    func testTypographyIsTransliteratedRatherThanDropped() {
        XCTAssertEqual(SSHKeyManager.asciiComment("em\u{2014}dash \u{201C}quoted\u{201D} \u{2026}"),
                       "em-dash \"quoted\" ...")
    }

    func testUntranslatableCharactersAreDroppedNotEscaped() {
        XCTAssertEqual(SSHKeyManager.asciiComment("codex\u{1F600}@mac\u{00E9}"), "codex@mac")
    }

    func testNewlinesCannotSplitAnAuthorizedKeysEntry() {
        XCTAssertEqual(SSHKeyManager.asciiComment("a\nssh-rsa AAAB evil"), "assh-rsa AAAB evil")
    }

    func testAWSModuleHCLIsASCII() {
        // The security group description carried an em dash, which failed every first
        // provision into a fresh account.
        let body = TofuModule.awsEC2.machineBody
        XCTAssertTrue(body.allSatisfy(\.isASCII),
                      "non-ASCII in the AWS module reaches the EC2 API: " +
                      String(body.filter { !$0.isASCII }))
    }
}

/// An EC2 AMI id belongs to exactly one region. Defaulting the image from the account's
/// home region and then creating the machine elsewhere produced `tofu apply` failing with
/// "collecting instance settings: couldn't find resource", which names neither the image
/// nor the region.
final class RegionScopedCatalogueTests: XCTestCase {
    func testOnlyEC2NeedsTheCatalogueRefetched() {
        XCTAssertTrue(ProviderKind.aws.catalogueVariesByRegion)
        // ProviderKind is a struct, not an enum, so this list is written out rather than
        // derived. A new cloud that scopes its catalogue by region belongs here too.
        for kind in [ProviderKind.hetzner, .digitalOcean, .linode, .vultr, .scaleway,
                     .existingHost, .mock] {
            XCTAssertFalse(kind.catalogueVariesByRegion,
                           "\(kind) would make the region picker re-read its catalogue for nothing")
        }
    }

    func testScopingAWSChangesTheRegionItAsks() async throws {
        let provider = AWSProvider(accessKeyID: "AKIAEXAMPLE",
                                   secretAccessKey: Secret("secret"),
                                   region: "eu-west-2")
        let scoped = provider.scoped(toRegion: "us-west-1")
        XCTAssertEqual((scoped as? AWSProvider)?.regionForTesting, "us-west-1")
        // Same region, and empty, are no-ops rather than rebuilds.
        XCTAssertEqual((provider.scoped(toRegion: "eu-west-2") as? AWSProvider)?.regionForTesting,
                       "eu-west-2")
        XCTAssertEqual((provider.scoped(toRegion: "") as? AWSProvider)?.regionForTesting,
                       "eu-west-2")
    }

    func testProvidersWithAGlobalCatalogueScopeToThemselves() {
        let provider = DigitalOceanProvider(token: Secret("token"))
        XCTAssertTrue(provider.scoped(toRegion: "nyc3") is DigitalOceanProvider)
    }
}

/// The region-scoping fix has to survive the wrapper. `provider(for:)` hands back a
/// TofuProvider, not the API client, so a `scoped(toRegion:)` that stopped at the wrapper
/// silently did nothing — which is how the wrong-region AMI reached `tofu apply` even after
/// the catalogue was made region-aware.
final class TofuProviderScopingTests: XCTestCase {
    private func awsProvider(region: String) -> TofuProvider {
        var account = ProviderAccount(kind: .aws, label: "test")
        account.plainFields["region"] = region
        return TofuProvider(module: .awsEC2, account: account,
                            secrets: ["accessKeyID": Secret("AKIAEXAMPLE"),
                                      "secretAccessKey": Secret("secret")],
                            runtime: AWSProvider(accessKeyID: "AKIAEXAMPLE",
                                                 secretAccessKey: Secret("secret"),
                                                 region: region))
    }

    func testScopingReachesTheRuntimeThroughTheWrapper() {
        let scoped = awsProvider(region: "eu-west-2").scoped(toRegion: "us-west-1")
        XCTAssertEqual((scoped as? TofuProvider)?.runtimeRegionForTesting, "us-west-1")
    }

    func testTheOpenTofuEnvironmentFollowsTheSameRegion() {
        let scoped = awsProvider(region: "eu-west-2").scoped(toRegion: "us-west-1")
        // Read from the module's own credential fields, not hardcoded.
        XCTAssertEqual((scoped as? TofuProvider)?.environmentForTesting["AWS_REGION"], "us-west-1")
    }

    func testAnEmptyRegionIsANoOp() {
        let scoped = awsProvider(region: "eu-west-2").scoped(toRegion: "")
        XCTAssertEqual((scoped as? TofuProvider)?.runtimeRegionForTesting, "eu-west-2")
    }
}

/// Amazon's Ubuntu AMIs log in as `ubuntu` with root locked, unlike every other cloud here,
/// which hands out root. The bootstrap needs root throughout, so it is elevated at the
/// transport rather than by threading sudo through the script.
final class SSHElevationTests: XCTestCase {
    private func client(user: String) -> SSHClient {
        SSHClient(host: "198.51.100.10", user: user, privateKeyPath: "/dev/null")
    }

    func testRootIsLeftAlone() {
        XCTAssertEqual(client(user: "root").elevated("bash -s"), "bash -s")
    }

    func testANonRootUserGoesThroughPasswordlessSudo() {
        XCTAssertEqual(client(user: "ubuntu").elevated("bash -s"),
                       "sudo -n -- bash -c 'bash -s'")
    }

    func testSingleQuotesInTheCommandSurvive() {
        // The command that found this: a heredoc guard with quotes in it would otherwise
        // end the sudo wrapper early and run the tail as separate commands.
        let wrapped = client(user: "ubuntu").elevated("echo 'hello world' > /etc/thing")
        XCTAssertEqual(wrapped, "sudo -n -- bash -c 'echo '\\''hello world'\\'' > /etc/thing'")
    }

    func testTheAWSModuleStillExpectsTheUbuntuUser() {
        // If this ever becomes root, the elevation above turns into a no-op and the
        // regression would be silent.
        XCTAssertEqual(TofuModule.awsEC2.sshUser, "ubuntu")
    }
}

/// Every path that runs something remotely has to elevate, not just the obvious ones.
/// `writeFile` was missed on the first pass and failed with "mkdir: Permission denied"
/// several minutes into provisioning, after Claude Code had already been installed.
final class SSHElevationCoverageTests: XCTestCase {
    func testEveryRemoteEntryPointIsElevated() throws {
        let source = try String(
            contentsOfFile: #filePath.replacingOccurrences(
                of: "Tests/CodexRemoteKitTests/ProviderTests.swift",
                with: "Sources/CodexRemoteKit/SSH/SSHClient.swift"),
            encoding: .utf8)
        for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
        where line.contains("sshArguments([") && !line.contains("func sshArguments") {
            XCTAssertTrue(line.contains("elevated("),
                          "SSHClient.swift:\(index + 1) runs a remote command without elevating it, "
                          + "which works only on clouds that hand out root: \(line.trimmingCharacters(in: .whitespaces))")
        }
    }
}
