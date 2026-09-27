import Foundation

public extension TofuModule {
    /// Scaleway through the `scaleway/scaleway` provider.
    ///
    /// Scaleway's SSH keys are account-wide rather than per-project-region, and a server
    /// picks them up automatically at boot, so the key is created here and not referenced
    /// by the instance resource.
    static let scaleway = TofuModule(
        kind: .scaleway,
        displayName: "Scaleway",
        blurb: "Scaleway instances in Paris, Amsterdam and Warsaw. Needs an API key and the project id.",
        providerSource: "scaleway/scaleway",
        providerVersion: "~> 2.39",
        providerBody: """
        zone   = var.region
        region = substr(var.region, 0, length(var.region) - 2)
        """,
        credentialFields: [
            CredentialField(key: "accessKey", label: "Access key",
                            help: "Scaleway console → IAM → API keys. Looks like SCWXXXXXXXXXXXXXXXXX.",
                            style: .secret, environmentVariable: "SCW_ACCESS_KEY"),
            CredentialField(key: "secretKey", label: "Secret key",
                            help: "The matching secret, shown once when the key is created.",
                            style: .secret, environmentVariable: "SCW_SECRET_KEY"),
            CredentialField(key: "projectID", label: "Project ID",
                            help: "Scaleway console → Project settings → Project ID.",
                            style: .plain, environmentVariable: "SCW_DEFAULT_PROJECT_ID"),
        ],
        tokenHelpURL: "https://console.scaleway.com/iam/api-keys",
        machineBody: """
        resource "scaleway_iam_ssh_key" "machine" {
          name       = "codex-remote-${var.name}"
          public_key = trimspace(var.ssh_public_key)
        }

        # A Scaleway instance has no public address unless one is attached, so reserve it
        # explicitly rather than relying on a dynamic one that can change on reboot.
        resource "scaleway_instance_ip" "machine" {
          zone = var.region
        }

        resource "scaleway_instance_server" "machine" {
          name  = var.name
          type  = var.size
          image = var.image
          zone  = var.region
          ip_id = scaleway_instance_ip.machine.id
          tags  = [for k, v in var.tags : "${k}-${v}"]

          user_data = {
            cloud-init = var.user_data
          }

          # The key has to exist before the server boots, or cloud-init installs nothing.
          depends_on = [scaleway_iam_ssh_key.machine]

          lifecycle {
            ignore_changes = [image, user_data]
          }
        }

        output "instance_id"   { value = scaleway_instance_server.machine.id }
        output "instance_name" { value = scaleway_instance_server.machine.name }
        output "public_ipv4"   { value = scaleway_instance_ip.machine.address }
        output "public_ipv6" {
          value = try([for ip in scaleway_instance_server.machine.public_ips :
                       ip.address if ip.family == "inet6"][0], "")
        }
        output "private_ipv4" {
          value = try(scaleway_instance_server.machine.private_ips[0].address, "")
        }
        output "state"  { value = scaleway_instance_server.machine.state }
        output "region" { value = scaleway_instance_server.machine.zone }
        output "size"   { value = scaleway_instance_server.machine.type }
        output "image"  { value = scaleway_instance_server.machine.image }
        """,
        fallbackCapabilities: {
            ProviderCapabilities(
                regions: [Region(slug: "fr-par-1", name: "Paris 1", country: "FR"),
                          Region(slug: "fr-par-2", name: "Paris 2", country: "FR"),
                          Region(slug: "nl-ams-1", name: "Amsterdam 1", country: "NL"),
                          Region(slug: "pl-waw-1", name: "Warsaw 1", country: "PL")],
                sizes: [InstanceSize(slug: "DEV1-M", name: "DEV1-M", vcpus: 3, memoryGB: 4,
                                     diskGB: 40, monthlyPrice: 16.43, currency: "EUR"),
                        InstanceSize(slug: "DEV1-L", name: "DEV1-L", vcpus: 4, memoryGB: 8,
                                     diskGB: 80, monthlyPrice: 32.85, currency: "EUR"),
                        InstanceSize(slug: "PRO2-S", name: "PRO2-S", vcpus: 4, memoryGB: 16,
                                     diskGB: 0, monthlyPrice: 54.75, currency: "EUR")],
                images: [OSImage(slug: "ubuntu_resolute", name: "Ubuntu 26.04", family: "ubuntu")],
                recommendedImage: "ubuntu_resolute", recommendedSize: "DEV1-M",
                recommendedRegion: "fr-par-1")
        },
        environment: { fields, secrets in
            var environment: [String: String] = [:]
            if let key = secrets["accessKey"] { environment["SCW_ACCESS_KEY"] = key.raw }
            if let key = secrets["secretKey"] { environment["SCW_SECRET_KEY"] = key.raw }
            if let project = fields["projectID"], !project.isEmpty {
                environment["SCW_DEFAULT_PROJECT_ID"] = project
                environment["SCW_DEFAULT_ORGANIZATION_ID"] = project
            }
            return environment
        },
        sshUser: "root",
        managesSSHKey: true
    )
}
