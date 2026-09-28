<!-- Copied from docs/adding-a-provider.md by Scripts/sync-site-docs.sh. Edit the repo, not this. -->

# Adding a provider

A cloud is a `TofuModule`: a provider address, the HCL for one machine, and a list of
credentials. No new Swift type, no API client, no request/response plumbing. That is what
bundling OpenTofu buys — its provider ecosystem is the part Codex Remote would otherwise have to
rewrite for every cloud.

## 1. Write the module

```swift
public extension TofuModule {
    static let exoscale = TofuModule(
        kind: ProviderKind("exoscale"),
        displayName: "Exoscale",
        blurb: "Exoscale instances in Europe. Needs an API key and secret.",
        providerSource: "exoscale/exoscale",
        providerVersion: "~> 0.59",
        credentialFields: [
            CredentialField(key: "apiKey", label: "API key",
                            help: "Exoscale portal → IAM → API keys.",
                            style: .secret, environmentVariable: "EXOSCALE_API_KEY"),
            CredentialField(key: "apiSecret", label: "API secret",
                            help: "The matching secret.",
                            style: .secret, environmentVariable: "EXOSCALE_API_SECRET"),
        ],
        machineBody: """
        resource "exoscale_ssh_key" "machine" {
          name       = "codex-remote-${var.name}"
          public_key = trimspace(var.ssh_public_key)
        }

        resource "exoscale_compute_instance" "machine" {
          name        = var.name
          zone        = var.region
          type        = var.size
          template_id = var.image
          ssh_key     = exoscale_ssh_key.machine.name
          user_data   = var.user_data
          disk_size   = 50
        }

        output "instance_id"   { value = exoscale_compute_instance.machine.id }
        output "instance_name" { value = exoscale_compute_instance.machine.name }
        output "public_ipv4"   { value = exoscale_compute_instance.machine.public_ip_address }
        output "public_ipv6"   { value = "" }
        output "private_ipv4"  { value = "" }
        output "state"         { value = exoscale_compute_instance.machine.state }
        """,
        fallbackCapabilities: { /* regions, sizes, images */ },
        environment: { _, secrets in
            var environment: [String: String] = [:]
            if let key = secrets["apiKey"] { environment["EXOSCALE_API_KEY"] = key.raw }
            if let key = secrets["apiSecret"] { environment["EXOSCALE_API_SECRET"] = key.raw }
            return environment
        }
    )
}
```

## 2. Register it

```swift
// ProviderRegistry.init
register(TofuRegistration.descriptor(for: .exoscale))
```

It now appears in the Add account menu, the New machine form, `codex-remote providers`, and
the provisioning pipeline. The settings form is generated from `credentialFields` — there
is no per-provider UI.

## 3. Validate it

```bash
codex-remote tofu validate --provider exoscale
```

This downloads the provider plugin and checks the generated HCL against that provider's
real schema. It creates nothing and costs nothing, and it is the only practical way to keep
a dozen clouds honest without holding an account on each. Run it before you commit.

## The contract

**Variables Codex Remote supplies** — `name`, `region`, `size`, `image`, `ssh_public_key`,
`ssh_key_ids`, `user_data`, `tags`. Declare extras with `extraVariableDeclarations` and
supply their values from `extraVariables`; a variable with neither a value nor a default
stops the apply to prompt, and Codex Remote runs OpenTofu with input disabled.

**Outputs the module must produce** — `instance_id`, `instance_name`, `public_ipv4`,
`public_ipv6`, `private_ipv4`, `state`. Optionally `region`, `size`, `image`.
`TofuModuleContractTests` asserts all of this for every module.

**Credentials travel in the environment**, never in the generated files, so they stay out
of the workspace and out of the state file. If a provider marks its credential *required*
in the provider block — Vultr does — take it as a variable and pass it as `TF_VAR_…`, which
OpenTofu reads from the environment too.

## Getting the SSH key onto the machine

Two ways, and every module must do one of them:

- `managesSSHKey: true` — the module creates the key resource from `var.ssh_public_key`.
  This is the default and the simplest.
- `managesSSHKey: false` — Codex Remote registers the key through that cloud's own API first and
  passes the ids in `var.ssh_key_ids`. Hetzner and DigitalOcean need this, because both
  reject a second upload of the same public key and Codex Remote installs one key everywhere.

## Pause and resume

OpenTofu describes what should exist, not whether it is running, so there is no declarative
way to power a machine off. A cloud gets a working pause switch only if Codex Remote also has a
native API client for it, passed as the runtime delegate:

```swift
register(TofuRegistration.descriptor(for: .hetzner) { _, secrets in
    HetznerProvider(token: secrets["token"]!)
})
```

The delegate also answers status polling and populates the New machine form, both of which
would otherwise wait on a provider plugin download. Without one, the module still creates
and destroys machines and the UI simply shows no pause switch.

## What the bootstrap assumes

- Debian or Ubuntu with `apt` and `systemd`.
- Login as root, or a user with password-free root — set `sshUser` if it is not `root`
  (AWS uses `ubuntu`).
- Outbound network for `apt` and `npm`.

## Testing without spending money

`MockProvider` implements `ComputeProvider` in memory and can be pointed at a host you
already own, so the SSH half runs for real. `StaticHostProvider` is the shipping version of
that idea: it creates nothing and refuses to power-cycle or delete, which is what you want
when adopting a machine you did not make.

`./Scripts/integration-test.sh` runs the whole post-create pipeline against a systemd
Docker container.
