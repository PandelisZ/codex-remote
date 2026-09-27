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
