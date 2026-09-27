import Foundation

public extension TofuModule {
    /// DigitalOcean through the `digitalocean/digitalocean` provider.
    ///
    /// Like Hetzner, DigitalOcean rejects a second upload of the same public key, so the
    /// key is registered once through its API and referenced here by id.
    static let digitalOcean = TofuModule(
        kind: .digitalOcean,
        displayName: "DigitalOcean",
        blurb: "Droplets across 14 regions. Needs a personal access token with write scope.",
        providerSource: "digitalocean/digitalocean",
        providerVersion: "~> 2.40",
        credentialFields: [
            CredentialField(key: "token", label: "Personal access token",
                            help: "DigitalOcean → API → Tokens → Generate New Token, with Write scope.",
                            style: .secret, environmentVariable: "DIGITALOCEAN_TOKEN"),
        ],
        tokenHelpURL: "https://cloud.digitalocean.com/account/api/tokens",
        machineBody: """
        resource "digitalocean_droplet" "machine" {
          name      = var.name
          region    = var.region
          size      = var.size
          image     = var.image
          ssh_keys  = var.ssh_key_ids
          user_data = var.user_data
          ipv6      = true
          tags      = [for k, v in var.tags : replace("${k}-${v}", ".", "-")]

          lifecycle {
            ignore_changes = [image, user_data]
          }
        }

        output "instance_id"   { value = digitalocean_droplet.machine.id }
        output "instance_name" { value = digitalocean_droplet.machine.name }
        output "public_ipv4"   { value = digitalocean_droplet.machine.ipv4_address }
        output "public_ipv6"   { value = digitalocean_droplet.machine.ipv6_address }
        output "private_ipv4"  { value = digitalocean_droplet.machine.ipv4_address_private }
        output "state"         { value = digitalocean_droplet.machine.status }
        output "region"        { value = digitalocean_droplet.machine.region }
        output "size"          { value = digitalocean_droplet.machine.size }
        output "image"         { value = digitalocean_droplet.machine.image }
        """,
        catalogBody: """
        data "digitalocean_regions" "all" {
          filter {
            key    = "available"
            values = ["true"]
          }
        }
        data "digitalocean_sizes" "all" {
          filter {
            key    = "available"
            values = ["true"]
          }
        }

        output "regions" {
          value = [for r in data.digitalocean_regions.all.regions : {
            slug = r.slug
            name = r.name
          }]
        }
        output "sizes" {
          value = [for s in data.digitalocean_sizes.all.sizes : {
            slug          = s.slug
            vcpus         = s.vcpus
            memory        = s.memory
            disk          = s.disk
            price_monthly = s.price_monthly
            regions       = s.regions
          }]
        }
        """,
        parseCatalog: { outputs in
            let regions = (outputs["regions"] as? [[String: Any]] ?? []).compactMap { entry -> Region? in
                guard let slug = entry["slug"] as? String else { return nil }
                return Region(slug: slug, name: entry["name"] as? String ?? slug)
            }
            let sizes = (outputs["sizes"] as? [[String: Any]] ?? []).compactMap { entry -> InstanceSize? in
                guard let slug = entry["slug"] as? String else { return nil }
                let megabytes = (entry["memory"] as? NSNumber)?.doubleValue ?? 0
                return InstanceSize(slug: slug, name: slug,
                                    vcpus: (entry["vcpus"] as? NSNumber)?.intValue ?? 0,
                                    memoryGB: megabytes / 1024.0,
                                    diskGB: (entry["disk"] as? NSNumber)?.intValue ?? 0,
                                    monthlyPrice: (entry["price_monthly"] as? NSNumber)?.doubleValue,
                                    currency: "USD",
                                    availableRegions: entry["regions"] as? [String] ?? [],
                                    architecture: slug.contains("arm") ? "arm" : "x86")
            }.sorted { ($0.monthlyPrice ?? .infinity) < ($1.monthlyPrice ?? .infinity) }
            guard !regions.isEmpty, !sizes.isEmpty else { return nil }
            return ProviderCapabilities(
                regions: regions, sizes: sizes,
                images: [OSImage(slug: "ubuntu-26-04-x64", name: "Ubuntu 26.04", family: "ubuntu"),
                         OSImage(slug: "ubuntu-24-04-x64", name: "Ubuntu 24.04 LTS", family: "ubuntu")],
                recommendedImage: "ubuntu-26-04-x64",
                recommendedSize: sizes.first(where: { $0.vcpus >= 2 && $0.memoryGB >= 4 })?.slug ?? "s-2vcpu-4gb",
                recommendedRegion: regions.first(where: { $0.slug == "nyc3" })?.slug ?? regions[0].slug)
        },
        fallbackCapabilities: {
            ProviderCapabilities(
                regions: [Region(slug: "nyc3", name: "New York 3"), Region(slug: "fra1", name: "Frankfurt 1"),
                          Region(slug: "ams3", name: "Amsterdam 3"), Region(slug: "sfo3", name: "San Francisco 3")],
                sizes: [InstanceSize(slug: "s-2vcpu-4gb", name: "Basic 2/4", vcpus: 2, memoryGB: 4,
                                     diskGB: 80, monthlyPrice: 24, currency: "USD"),
                        InstanceSize(slug: "s-4vcpu-8gb", name: "Basic 4/8", vcpus: 4, memoryGB: 8,
                                     diskGB: 160, monthlyPrice: 48, currency: "USD")],
                images: [OSImage(slug: "ubuntu-26-04-x64", name: "Ubuntu 26.04", family: "ubuntu"),
                         OSImage(slug: "ubuntu-24-04-x64", name: "Ubuntu 24.04 LTS", family: "ubuntu")],
                recommendedImage: "ubuntu-26-04-x64", recommendedSize: "s-2vcpu-4gb", recommendedRegion: "nyc3")
        },
        environment: { _, secrets in
            secrets["token"].map { ["DIGITALOCEAN_TOKEN": $0.raw] } ?? [:]
        },
        sshUser: "root",
        managesSSHKey: false
    )
}
