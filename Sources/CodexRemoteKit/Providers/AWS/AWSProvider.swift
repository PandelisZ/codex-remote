import Foundation

/// Amazon EC2 via the Query API, signed with SigV4. Uses the account's default VPC and
/// creates (once) a `codex-remote-ssh` security group that allows inbound TCP 22, because a
/// stock EC2 default group has no inbound rules and the SSH bootstrap could never connect.
public struct AWSProvider: ComputeProvider {
    public let kind = ProviderKind.aws
    public let displayName = "Amazon EC2"

    private let accessKeyID: String
    private let secretAccessKey: Secret
    private let sessionToken: String?
    private let region: String
    private let session: URLSession
    private static let apiVersion = "2016-11-15"
    /// Canonical's AWS account; the only owner Codex Remote trusts for Ubuntu AMIs.
    private static let canonicalOwnerID = "099720109477"

    public init(accessKeyID: String, secretAccessKey: Secret, sessionToken: String? = nil,
                region: String, session: URLSession = .shared) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
        self.region = region
        self.session = session
    }

    public static let descriptor = ProviderDescriptor(
        kind: .aws,
        displayName: "Amazon EC2",
        blurb: "EC2 instances in your default VPC. Needs an IAM access key with EC2 permissions.",
        credentialFields: [
            CredentialField(key: "accessKeyID", label: "Access key ID",
                            help: "IAM user or role access key, e.g. AKIA…",
                            style: .secret, environmentVariable: "AWS_ACCESS_KEY_ID"),
            CredentialField(key: "secretAccessKey", label: "Secret access key",
                            help: "The matching secret.",
                            style: .secret, environmentVariable: "AWS_SECRET_ACCESS_KEY"),
            CredentialField(key: "sessionToken", label: "Session token",
                            help: "Only for temporary STS credentials. Leave blank for a long-lived IAM key.",
                            style: .secret, environmentVariable: "AWS_SESSION_TOKEN", isOptional: true),
            CredentialField(key: "region", label: "Default region",
                            help: "e.g. us-east-1. Machines are created here unless you pick another region.",
                            style: .plain, environmentVariable: "AWS_REGION"),
        ],
        tokenHelpURL: "https://console.aws.amazon.com/iam/home#/security_credentials",
        make: { account, secrets in
            guard let key = secrets["accessKeyID"], let secret = secrets["secretAccessKey"] else {
                throw ProviderError.missingCredential(field: "Access key", provider: "Amazon EC2")
            }
            let region = account.plainFields["region"]
                ?? ProcessInfo.processInfo.environment["AWS_REGION"]
                ?? "us-east-1"
            return AWSProvider(accessKeyID: key.raw, secretAccessKey: secret,
                               sessionToken: secrets["sessionToken"]?.raw, region: region)
        }
    )

    // MARK: - Protocol

    public func verify() async throws -> ProviderIdentity {
        let response = try await call(["Action": "DescribeAccountAttributes"])
        let attributes = response.find("accountAttributeSet")?.all("item") ?? []
        let supported = attributes
            .first { $0["attributeName"]?.trimmedText == "supported-platforms" }?
            .find("attributeValueSet")?.all("item").first?["attributeValue"]?.trimmedText
        return ProviderIdentity(accountLabel: "AWS \(region)",
                                detail: supported.map { "platform: \($0)" })
    }

    public func capabilities() async throws -> ProviderCapabilities {
        async let regionsTask = call(["Action": "DescribeRegions"])
        async let imagesTask = describeUbuntuImages()
        let (regionsXML, images) = try await (regionsTask, imagesTask)

        let regions = (regionsXML.find("regionInfo")?.all("item") ?? []).compactMap { item -> Region? in
            guard let name = item["regionName"]?.trimmedText, !name.isEmpty else { return nil }
            return Region(slug: name, name: name)
        }.sorted { $0.slug < $1.slug }

        // EC2 has thousands of instance types and no price in the EC2 API; Codex Remote offers a
        // curated general-purpose shortlist and leaves price blank rather than guessing.
        let sizes = Self.curatedSizes

        let recommendedImage = images.first?.slug ?? ""
        let recommendedRegion = regions.first(where: { $0.slug == region })?.slug ?? region
        return ProviderCapabilities(regions: regions, sizes: sizes, images: images,
                                    recommendedImage: recommendedImage,
                                    recommendedSize: "t3.medium",
                                    recommendedRegion: recommendedRegion)
    }

    public func ensureSSHKey(name: String, publicKey: String) async throws -> String {
        let material = Data(publicKey.trimmingCharacters(in: .whitespacesAndNewlines).utf8).base64EncodedString()
        do {
            let response = try await call([
                "Action": "ImportKeyPair",
                "KeyName": name,
                "PublicKeyMaterial": material,
            ])
            return response.find("keyName")?.trimmedText ?? name
        } catch let error as AWSError where error.code == "InvalidKeyPair.Duplicate" {
            // Already imported under this name — reuse it.
            return name
        }
    }

    public func createInstance(_ request: InstanceRequest) async throws -> Instance {
        let securityGroupID = try await ensureSSHSecurityGroup()
        var parameters: [String: String] = [
            "Action": "RunInstances",
            "ImageId": request.image,
            "InstanceType": request.size,
            "MinCount": "1",
            "MaxCount": "1",
            "SecurityGroupId.1": securityGroupID,
            "TagSpecification.1.ResourceType": "instance",
            "TagSpecification.1.Tag.1.Key": "Name",
            "TagSpecification.1.Tag.1.Value": request.name,
            // Codex Remote's own marker, so `listInstances` can tell its machines apart.
            "TagSpecification.1.Tag.2.Key": "managed-by",
            "TagSpecification.1.Tag.2.Value": "codex-remote",
        ]
        if let first = request.sshKeyIdentifiers.first { parameters["KeyName"] = first }
        if let userData = request.userData {
            parameters["UserData"] = Data(userData.utf8).base64EncodedString()
        }
        var tagIndex = 3
        for (key, value) in request.labels.sorted(by: { $0.key < $1.key }) {
            parameters["TagSpecification.1.Tag.\(tagIndex).Key"] = key
            parameters["TagSpecification.1.Tag.\(tagIndex).Value"] = value
            tagIndex += 1
        }

        let response = try await call(parameters)
        guard let item = response.find("instancesSet")?.all("item").first,
              let instance = parseInstance(item) else {
            throw ProviderError.creationFailed("RunInstances returned no instance")
        }
        return instance
    }

    public func instance(id: String) async throws -> Instance? {
        do {
            let response = try await call(["Action": "DescribeInstances", "InstanceId.1": id])
            let item = response.find("reservationSet")?.all("item").first?
                .find("instancesSet")?.all("item").first
            return item.flatMap(parseInstance)
        } catch let error as AWSError where error.code.hasPrefix("InvalidInstanceID") {
            return nil
        }
    }

    public func listInstances() async throws -> [Instance] {
        let response = try await call([
            "Action": "DescribeInstances",
            "Filter.1.Name": "tag:managed-by",
            "Filter.1.Value.1": "codex-remote",
        ])
        let reservations = response.find("reservationSet")?.all("item") ?? []
        return reservations.flatMap { reservation in
            (reservation.find("instancesSet")?.all("item") ?? []).compactMap(parseInstance)
        }.filter { $0.state != .deleted }
    }

    public func power(_ action: PowerAction, instanceID: String) async throws {
        let awsAction: String
        switch action {
        case .start: awsAction = "StartInstances"
        case .stop: awsAction = "StopInstances"
        case .reboot: awsAction = "RebootInstances"
        }
        _ = try await call(["Action": awsAction, "InstanceId.1": instanceID])
    }

    public func destroyInstance(id: String) async throws {
        do {
            _ = try await call(["Action": "TerminateInstances", "InstanceId.1": id])
        } catch let error as AWSError where error.code.hasPrefix("InvalidInstanceID") {
            // Already terminated.
        }
    }

    public func defaultSSHUser(forImage image: String) -> String { "ubuntu" }

    // MARK: - Helpers

    private func describeUbuntuImages() async throws -> [OSImage] {
        let response = try await call([
            "Action": "DescribeImages",
            "Owner.1": Self.canonicalOwnerID,
            "Filter.1.Name": "name",
            "Filter.1.Value.1": "ubuntu/images/hvm-ssd*/ubuntu-*-26.04-amd64-server-*",
            "Filter.2.Name": "state",
            "Filter.2.Value.1": "available",
        ])
        let items = response.find("imagesSet")?.all("item") ?? []
        let images = items.compactMap { item -> (String, OSImage)? in
            guard let id = item["imageId"]?.trimmedText,
                  let name = item["name"]?.trimmedText else { return nil }
            let created = item["creationDate"]?.trimmedText ?? ""
            return (created, OSImage(slug: id, name: name, family: "ubuntu", architecture: "x86"))
        }
        // Newest AMI first: Canonical publishes a fresh one every few weeks.
        return images.sorted { $0.0 > $1.0 }.map(\.1).prefix(10).map { $0 }
    }

    /// Idempotently creates `codex-remote-ssh` in the default VPC with inbound TCP 22.
    private func ensureSSHSecurityGroup() async throws -> String {
        let existing = try await call([
            "Action": "DescribeSecurityGroups",
            "Filter.1.Name": "group-name",
            "Filter.1.Value.1": "codex-remote-ssh",
        ])
        if let id = existing.find("securityGroupInfo")?.all("item").first?["groupId"]?.trimmedText,
           !id.isEmpty {
            return id
        }

        let vpcs = try await call([
            "Action": "DescribeVpcs",
            "Filter.1.Name": "isDefault",
            "Filter.1.Value.1": "true",
        ])
        guard let vpcID = vpcs.find("vpcSet")?.all("item").first?["vpcId"]?.trimmedText,
              !vpcID.isEmpty else {
            throw ProviderError.creationFailed(
                "This AWS account has no default VPC in \(region). Create one, or use a region that has one.")
        }

        let created = try await call([
            "Action": "CreateSecurityGroup",
            "GroupName": "codex-remote-ssh",
            "GroupDescription": "Codex Remote — inbound SSH for managed Codex machines",
            "VpcId": vpcID,
        ])
        guard let groupID = created.find("groupId")?.trimmedText, !groupID.isEmpty else {
            throw ProviderError.creationFailed("CreateSecurityGroup returned no group id")
        }
        _ = try await call([
            "Action": "AuthorizeSecurityGroupIngress",
            "GroupId": groupID,
            "IpPermissions.1.IpProtocol": "tcp",
            "IpPermissions.1.FromPort": "22",
            "IpPermissions.1.ToPort": "22",
            "IpPermissions.1.IpRanges.1.CidrIp": "0.0.0.0/0",
            "IpPermissions.1.IpRanges.1.Description": "Codex Remote SSH bootstrap and tunnel",
        ])
        Log.shared.info("aws", "Created security group codex-remote-ssh (\(groupID)) in \(vpcID).")
        return groupID
    }

    private func parseInstance(_ item: XMLTreeNode) -> Instance? {
        guard let id = item["instanceId"]?.trimmedText, !id.isEmpty else { return nil }
        let stateName = item["instanceState"]?["name"]?.trimmedText ?? "unknown"
        let tags = item.find("tagSet")?.all("item") ?? []
        let name = tags.first { $0["key"]?.trimmedText == "Name" }?["value"]?.trimmedText ?? id
        var created: Date?
        if let launch = item["launchTime"]?.trimmedText {
            created = ISO8601DateFormatter().date(from: launch)
        }
        return Instance(
            id: id,
            name: name,
            state: Self.mapState(stateName),
            publicIPv4: item["ipAddress"]?.trimmedText.nilIfEmpty,
            publicIPv6: item.find("networkInterfaceSet")?.find("ipv6AddressesSet")?
                .all("item").first?["ipv6Address"]?.trimmedText.nilIfEmpty,
            privateIPv4: item["privateIpAddress"]?.trimmedText.nilIfEmpty,
            region: item["placement"]?["availabilityZone"]?.trimmedText ?? region,
            size: item["instanceType"]?.trimmedText ?? "unknown",
            image: item["imageId"]?.trimmedText,
            createdAt: created,
            providerKind: .aws
        )
    }

    static func mapState(_ name: String) -> InstanceState {
        switch name {
        case "pending": return .provisioning
        case "running": return .running
        case "stopping": return .stopping
        case "stopped": return .stopped
        case "shutting-down": return .deleting
        case "terminated": return .deleted
        default: return .unknown
        }
    }

    static let curatedSizes: [InstanceSize] = [
        InstanceSize(slug: "t3.small", name: "t3.small", vcpus: 2, memoryGB: 2, diskGB: 30),
        InstanceSize(slug: "t3.medium", name: "t3.medium", vcpus: 2, memoryGB: 4, diskGB: 30),
        InstanceSize(slug: "t3.large", name: "t3.large", vcpus: 2, memoryGB: 8, diskGB: 30),
        InstanceSize(slug: "t3.xlarge", name: "t3.xlarge", vcpus: 4, memoryGB: 16, diskGB: 30),
        InstanceSize(slug: "m7i.large", name: "m7i.large", vcpus: 2, memoryGB: 8, diskGB: 30),
        InstanceSize(slug: "m7i.xlarge", name: "m7i.xlarge", vcpus: 4, memoryGB: 16, diskGB: 30),
        InstanceSize(slug: "m7i.2xlarge", name: "m7i.2xlarge", vcpus: 8, memoryGB: 32, diskGB: 30),
        InstanceSize(slug: "c7i.2xlarge", name: "c7i.2xlarge", vcpus: 8, memoryGB: 16, diskGB: 30),
    ]

    // MARK: - Transport

    private func call(_ parameters: [String: String]) async throws -> XMLTreeNode {
        var all = parameters
        all["Version"] = Self.apiVersion
        let body = SigV4Signer.formBody(all)
        let host = "ec2.\(region).amazonaws.com"
        let signer = SigV4Signer(accessKeyID: accessKeyID, secretAccessKey: secretAccessKey,
                                 sessionToken: sessionToken, region: region, service: "ec2")
        let headers = signer.sign(host: host, body: body)

        var request = URLRequest(url: URL(string: "https://\(host)/")!, timeoutInterval: 45)
        request.httpMethod = "POST"
        request.httpBody = body
        for (key, value) in headers where key != "host" {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HTTPError.transport("Non-HTTP response from EC2")
        }
        guard let tree = XMLTreeNode.parse(data) else {
            throw HTTPError.decoding("EC2 returned unparseable XML", provider: "Amazon EC2")
        }
        if !(200..<300).contains(http.statusCode) {
            let error = tree.find("Error")
            let code = error?["Code"]?.trimmedText ?? "HTTP\(http.statusCode)"
            let message = error?["Message"]?.trimmedText ?? String(decoding: data, as: UTF8.self).prefix(300).description
            throw AWSError(code: code, message: message, status: http.statusCode)
        }
        return tree
    }
}

public struct AWSError: LocalizedError {
    public let code: String
    public let message: String
    public let status: Int

    public var errorDescription: String? {
        switch code {
        case "AuthFailure", "SignatureDoesNotMatch", "InvalidClientTokenId":
            return "AWS rejected the credentials (\(code)): \(message)"
        case "UnauthorizedOperation":
            return "The IAM identity is missing an EC2 permission: \(message)"
        default:
            return "AWS \(code): \(message)"
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
