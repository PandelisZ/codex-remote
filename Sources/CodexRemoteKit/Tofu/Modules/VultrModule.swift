import Foundation

public extension TofuModule {
    /// Vultr through the `vultr/vultr` provider.
    ///
    /// Vultr identifies operating systems by numeric id rather than a slug, so the image
    /// is resolved here with a data source on the name Codex Remote passes in. That keeps the
    /// form's image list the same shape as every other cloud's.
    static let vultr = TofuModule(
        kind: .vultr,
        displayName: "Vultr",
        blurb: "Vultr cloud compute in 30+ locations. Needs an API key, with your IP allowed in Vultr's API settings.",
        providerSource: "vultr/vultr",
        providerVersion: "~> 2.21",
        providerBody: """
        # The Vultr provider marks api_key required, so it has to appear here. It arrives
        # as TF_VAR_vultr_api_key from the environment, which keeps the key out of the
        # generated files and out of the state.
        api_key     = var.vultr_api_key
        rate_limit  = 700
        retry_limit = 3
        """,
        credentialFields: [
            CredentialField(key: "apiKey", label: "API key",
                            help: "Vultr → Account → API → Personal Access Token. Add your current IP to the access control list there, or calls are refused.",
                            style: .secret, environmentVariable: "VULTR_API_KEY"),
        ],
        tokenHelpURL: "https://my.vultr.com/settings/#settingsapi",
        machineBody: """
        data "vultr_os" "image" {
          filter {
            name   = "name"
            values = [var.image]
          }
        }

        resource "vultr_ssh_key" "machine" {
          name    = "codex-remote-${var.name}"
          ssh_key = trimspace(var.ssh_public_key)
        }

        resource "vultr_instance" "machine" {
          label       = var.name
          hostname    = replace(var.name, "/[^A-Za-z0-9-]/", "-")
          region      = var.region
          plan        = var.size
          os_id       = data.vultr_os.image.id
          ssh_key_ids = [vultr_ssh_key.machine.id]
          user_data   = var.user_data
          enable_ipv6 = true
          tags        = [for k, v in var.tags : "${k}-${v}"]

          lifecycle {
            ignore_changes = [os_id, user_data]
          }
        }

        output "instance_id"   { value = vultr_instance.machine.id }
        output "instance_name" { value = vultr_instance.machine.label }
        output "public_ipv4"   { value = vultr_instance.machine.main_ip }
        output "public_ipv6"   { value = vultr_instance.machine.v6_main_ip }
        output "private_ipv4"  { value = vultr_instance.machine.internal_ip }
        output "state"         { value = vultr_instance.machine.status }
        output "region"        { value = vultr_instance.machine.region }
        output "size"          { value = vultr_instance.machine.plan }
        output "image"         { value = data.vultr_os.image.name }
        """,
        fallbackCapabilities: {
            ProviderCapabilities(
                regions: [Region(slug: "fra", name: "Frankfurt", country: "DE"),
                          Region(slug: "ams", name: "Amsterdam", country: "NL"),
                          Region(slug: "lhr", name: "London", country: "GB"),
                          Region(slug: "ewr", name: "New Jersey", country: "US"),
                          Region(slug: "sjc", name: "Silicon Valley", country: "US"),
                          Region(slug: "nrt", name: "Tokyo", country: "JP")],
                sizes: [InstanceSize(slug: "vc2-2c-4gb", name: "Regular 2/4", vcpus: 2, memoryGB: 4,
                                     diskGB: 80, monthlyPrice: 20, currency: "USD"),
                        InstanceSize(slug: "vc2-4c-8gb", name: "Regular 4/8", vcpus: 4, memoryGB: 8,
                                     diskGB: 160, monthlyPrice: 40, currency: "USD"),
                        InstanceSize(slug: "vhp-2c-4gb-amd", name: "High Performance 2/4 AMD",
                                     vcpus: 2, memoryGB: 4, diskGB: 128, monthlyPrice: 24, currency: "USD")],
                images: [OSImage(slug: "Ubuntu 26.04 x64", name: "Ubuntu 24.04 LTS", family: "ubuntu")],
                recommendedImage: "Ubuntu 26.04 x64", recommendedSize: "vc2-2c-4gb",
                recommendedRegion: "fra")
        },
        environment: { _, secrets in
            guard let key = secrets["apiKey"] else { return [:] }
            return ["VULTR_API_KEY": key.raw, "TF_VAR_vultr_api_key": key.raw]
        },
        sshUser: "root",
        managesSSHKey: true,
        extraVariableDeclarations: """
        variable "vultr_api_key" {
          type      = string
          sensitive = true
          default   = ""
        }
        """
    )
}
