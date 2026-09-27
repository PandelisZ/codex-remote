import Foundation

public extension TofuModule {
    /// Hetzner Cloud through the `hetznercloud/hcloud` provider.
    ///
    /// The SSH key is *not* created here: Hetzner rejects a second upload of the same
    /// public key outright, and Codex Remote installs one key on every machine it makes. The key
    /// is registered once through Hetzner's API and its id passed in.
    static let hetzner = TofuModule(
        kind: .hetzner,
        displayName: "Hetzner Cloud",
        blurb: "Cheap EU/US cloud servers. Needs a project API token with Read & Write.",
        providerSource: "hetznercloud/hcloud",
        providerVersion: "~> 1.48",
        credentialFields: [
            CredentialField(key: "token", label: "API token",
                            help: "Hetzner Cloud Console → your project → Security → API tokens → Generate, with Read & Write.",
                            style: .secret, environmentVariable: "HCLOUD_TOKEN"),
        ],
        tokenHelpURL: "https://console.hetzner.cloud/",
        machineBody: """
        resource "hcloud_server" "machine" {
          name        = var.name
          server_type = var.size
          image       = var.image
          location    = var.region
          ssh_keys    = var.ssh_key_ids
          user_data   = var.user_data
          labels      = var.tags

          public_net {
            ipv4_enabled = true
            ipv6_enabled = true
          }

          lifecycle {
            # The image is only the starting point; Codex Remote configures the machine over SSH
            # afterwards. Reacting to an image change would destroy and rebuild it.
            ignore_changes = [image, user_data]
          }
        }

        output "instance_id"   { value = hcloud_server.machine.id }
        output "instance_name" { value = hcloud_server.machine.name }
        output "public_ipv4"   { value = hcloud_server.machine.ipv4_address }
        output "public_ipv6"   { value = hcloud_server.machine.ipv6_address }
        output "private_ipv4"  { value = "" }
        output "state"         { value = hcloud_server.machine.status }
        output "region"        { value = hcloud_server.machine.location }
        output "size"          { value = hcloud_server.machine.server_type }
        output "image"         { value = hcloud_server.machine.image }
        """,
        catalogBody: """
        data "hcloud_datacenters"  "all" {}
        data "hcloud_server_types" "all" {}
        data "hcloud_images"       "all" {
          with_architecture = ["x86", "arm"]
          most_recent       = true
        }

        output "locations" {
          value = distinct([for d in data.hcloud_datacenters.all.datacenters : d.location])
        }
        output "server_types" {
          value = [for t in data.hcloud_server_types.all.server_types : {
            name         = t.name
            description  = t.description
            cores        = t.cores
            memory       = t.memory
            disk         = t.disk
            architecture = t.architecture
          }]
        }
        output "images" {
          value = [for i in data.hcloud_images.all.images : {
            name         = i.name
            description  = i.description
            os_flavor    = i.os_flavor
            architecture = i.architecture
          } if i.os_flavor == "ubuntu" || i.os_flavor == "debian"]
        }
        """,
        parseCatalog: { outputs in
            let regions = (outputs["locations"] as? [String] ?? []).map { Region(slug: $0, name: $0) }
            let sizes = (outputs["server_types"] as? [[String: Any]] ?? []).compactMap { entry -> InstanceSize? in
                guard let name = entry["name"] as? String else { return nil }
                return InstanceSize(slug: name,
                                    name: entry["description"] as? String ?? name,
                                    vcpus: (entry["cores"] as? NSNumber)?.intValue ?? 0,
                                    memoryGB: (entry["memory"] as? NSNumber)?.doubleValue ?? 0,
                                    diskGB: (entry["disk"] as? NSNumber)?.intValue ?? 0,
                                    currency: "EUR",
                                    architecture: entry["architecture"] as? String ?? "x86")
            }
            let images = (outputs["images"] as? [[String: Any]] ?? []).compactMap { entry -> OSImage? in
                guard let name = entry["name"] as? String, !name.isEmpty else { return nil }
                return OSImage(slug: name,
                               name: entry["description"] as? String ?? name,
                               family: entry["os_flavor"] as? String ?? "linux",
                               architecture: entry["architecture"] as? String ?? "x86")
            }
            guard !regions.isEmpty, !sizes.isEmpty else { return nil }
            return ProviderCapabilities(
                regions: regions, sizes: sizes, images: images,
                recommendedImage: ProviderCapabilities.newestUbuntu(in: images)?.slug
                    ?? images.first?.slug ?? "ubuntu-26.04",
                recommendedSize: sizes.first(where: { $0.vcpus >= 2 && $0.memoryGB >= 4 })?.slug ?? "cx23",
                recommendedRegion: regions.first(where: { $0.slug == "nbg1" })?.slug ?? regions.first?.slug ?? "nbg1")
        },
        fallbackCapabilities: {
            ProviderCapabilities(
                regions: [Region(slug: "nbg1", name: "Nuremberg", country: "DE"),
                          Region(slug: "fsn1", name: "Falkenstein", country: "DE"),
                          Region(slug: "hel1", name: "Helsinki", country: "FI"),
                          Region(slug: "ash", name: "Ashburn, VA", country: "US"),
                          Region(slug: "hil", name: "Hillsboro, OR", country: "US")],
                sizes: [InstanceSize(slug: "cx23", name: "CX23", vcpus: 2, memoryGB: 4, diskGB: 40,
                                     monthlyPrice: 6.59, currency: "EUR"),
                        InstanceSize(slug: "cx33", name: "CX33", vcpus: 4, memoryGB: 8, diskGB: 80,
                                     monthlyPrice: 10.19, currency: "EUR"),
                        InstanceSize(slug: "ccx13", name: "CCX13 (dedicated)", vcpus: 2, memoryGB: 8,
                                     diskGB: 80, monthlyPrice: 51.59, currency: "EUR")],
                images: [OSImage(slug: "ubuntu-26.04", name: "Ubuntu 26.04", family: "ubuntu"),
                         OSImage(slug: "ubuntu-24.04", name: "Ubuntu 24.04 LTS", family: "ubuntu")],
                recommendedImage: "ubuntu-26.04", recommendedSize: "cx23", recommendedRegion: "nbg1")
        },
        environment: { _, secrets in
            secrets["token"].map { ["HCLOUD_TOKEN": $0.raw] } ?? [:]
        },
        sshUser: "root",
        // Hetzner answers a duplicate public key with a uniqueness error, so the key is
        // registered once through its API and referenced here by id.
        managesSSHKey: false
    )
}
