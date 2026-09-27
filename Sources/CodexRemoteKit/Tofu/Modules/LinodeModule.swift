import Foundation
import Security

public extension TofuModule {
    /// Akamai Linode through the `linode/linode` provider.
    ///
    /// Linode's API insists on a root password when an instance is deployed from an image,
    /// even when key authentication is the only thing that will ever be used. Codex Remote
    /// generates a throwaway one per machine and never keeps it: the key is what gets you
    /// in, and password authentication is turned off during bootstrap anyway.
    static let linode = TofuModule(
        kind: .linode,
        displayName: "Linode",
        blurb: "Akamai Linode instances in 25+ regions. Needs a personal access token with Linodes read/write.",
        providerSource: "linode/linode",
        providerVersion: "~> 2.13",
        credentialFields: [
            CredentialField(key: "token", label: "Personal access token",
                            help: "Linode Cloud Manager → API Tokens → Create a Personal Access Token, with Linodes read/write.",
                            style: .secret, environmentVariable: "LINODE_TOKEN"),
        ],
        tokenHelpURL: "https://cloud.linode.com/profile/tokens",
        machineBody: """
        resource "linode_instance" "machine" {
          label           = replace(var.name, "/[^A-Za-z0-9-_]/", "-")
          region          = var.region
          type            = var.size
          image           = var.image
          authorized_keys = [trimspace(var.ssh_public_key)]
          root_pass       = var.root_password
          tags            = [for k, v in var.tags : "${k}:${v}"]

          metadata {
            user_data = base64encode(var.user_data)
          }

          lifecycle {
            ignore_changes = [image, metadata, root_pass]
          }
        }

        output "instance_id"   { value = linode_instance.machine.id }
        output "instance_name" { value = linode_instance.machine.label }
        output "public_ipv4"   { value = linode_instance.machine.ip_address }
        output "public_ipv6"   { value = split("/", linode_instance.machine.ipv6)[0] }
        output "private_ipv4"  { value = "" }
        output "state"         { value = linode_instance.machine.status }
        output "region"        { value = linode_instance.machine.region }
        output "size"          { value = linode_instance.machine.type }
        output "image"         { value = linode_instance.machine.image }
        """,
        catalogBody: """
        data "linode_regions" "all" {}
        data "linode_instance_types" "all" {}

        output "regions" {
          value = [for r in data.linode_regions.all.regions : {
            id      = r.id
            country = r.country
          }]
        }
        output "types" {
          value = [for t in data.linode_instance_types.all.types : {
            id       = t.id
            label    = t.label
            vcpus    = t.vcpus
            memory   = t.memory
            disk     = t.disk
            price    = t.price
            class    = t.class
          }]
        }
        """,
        parseCatalog: { outputs in
            let regions = (outputs["regions"] as? [[String: Any]] ?? []).compactMap { entry -> Region? in
                guard let id = entry["id"] as? String else { return nil }
                return Region(slug: id, name: id, country: entry["country"] as? String)
            }
            let sizes = (outputs["types"] as? [[String: Any]] ?? []).compactMap { entry -> InstanceSize? in
                guard let id = entry["id"] as? String else { return nil }
                // Linode reports memory and disk in megabytes.
                let monthly = ((entry["price"] as? [[String: Any]])?.first?["monthly"] as? NSNumber)?.doubleValue
                    ?? ((entry["price"] as? [String: Any])?["monthly"] as? NSNumber)?.doubleValue
                return InstanceSize(slug: id,
                                    name: entry["label"] as? String ?? id,
                                    vcpus: (entry["vcpus"] as? NSNumber)?.intValue ?? 0,
                                    memoryGB: ((entry["memory"] as? NSNumber)?.doubleValue ?? 0) / 1024.0,
                                    diskGB: ((entry["disk"] as? NSNumber)?.intValue ?? 0) / 1024,
                                    monthlyPrice: monthly, currency: "USD")
            }.sorted { ($0.monthlyPrice ?? .infinity) < ($1.monthlyPrice ?? .infinity) }
            guard !regions.isEmpty, !sizes.isEmpty else { return nil }
            return ProviderCapabilities(
                regions: regions, sizes: sizes,
                images: [OSImage(slug: "linode/ubuntu26.04", name: "Ubuntu 26.04", family: "ubuntu")],
                recommendedImage: "linode/ubuntu26.04",
                recommendedSize: sizes.first(where: { $0.vcpus >= 2 && $0.memoryGB >= 4 })?.slug ?? "g6-standard-2",
                recommendedRegion: regions.first(where: { $0.slug == "eu-central" })?.slug ?? regions[0].slug)
        },
        fallbackCapabilities: {
            ProviderCapabilities(
                regions: [Region(slug: "eu-central", name: "Frankfurt", country: "DE"),
                          Region(slug: "us-east", name: "Newark, NJ", country: "US"),
                          Region(slug: "ap-south", name: "Singapore", country: "SG")],
                sizes: [InstanceSize(slug: "g6-standard-2", name: "Linode 4GB", vcpus: 2, memoryGB: 4,
                                     diskGB: 80, monthlyPrice: 24, currency: "USD"),
                        InstanceSize(slug: "g6-standard-4", name: "Linode 8GB", vcpus: 4, memoryGB: 8,
                                     diskGB: 160, monthlyPrice: 48, currency: "USD")],
                images: [OSImage(slug: "linode/ubuntu26.04", name: "Ubuntu 26.04", family: "ubuntu")],
                recommendedImage: "linode/ubuntu26.04", recommendedSize: "g6-standard-2",
                recommendedRegion: "eu-central")
        },
        environment: { _, secrets in
            secrets["token"].map { ["LINODE_TOKEN": $0.raw] } ?? [:]
        },
        sshUser: "root",
        managesSSHKey: true,
        extraVariableDeclarations: """
        variable "root_password" {
          type      = string
          sensitive = true
        }
        """,
        extraVariables: { _ in
            // Required by Linode's API, immediately made irrelevant by key-only SSH.
            var bytes = [UInt8](repeating: 0, count: 24)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            return ["root_password": "Rm-" + bytes.map { String(format: "%02x", $0) }.joined()]
        }
    )
}
