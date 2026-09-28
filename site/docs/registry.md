<!-- Copied from docs/registry.md by Scripts/sync-site-docs.sh. Edit the repo, not this. -->

# The provider registry

Clouds are data, not code. A provider is some OpenTofu HCL, the environment variables its
credentials map onto, and the lists that fill the New machine form — so the catalogue lives
in a JSON file fetched at runtime instead of being compiled into the app.

Two things follow. A new cloud can reach everyone without an app release. And you can point
Codex Remote at your own registry — **Settings → Providers → Registry** — and get your own
catalogue: a homelab module, a provider nobody has added yet, or a fork of ours with the
packages, volumes and network your team wants baked in.

The official registry is <https://codexremote.io/registry.json>, built from
[`site/registry.json`](../site/registry.json) in this repo. Adding a provider there is a
pull request, not a release.

## What you are trusting

A registry supplies HCL that OpenTofu runs against the credentials you gave it. It can
create anything that token allows. Nothing in a registry executes on your Mac, and Codex
Remote validates the shape of every entry before offering it — but that is a long way from
"safe to point at a stranger's URL". Treat a registry like a Terraform module you are about
to apply, because that is what it is.

Changing the URL is therefore a deliberate action in Settings, never a background update,
and the app tells you what it found before you commit to it.

## Rules the loader enforces

Refused outright, with the previous registry left working:

- a `formatVersion` newer than the app understands — a half-understood cloud module is
  worse than no module
- two providers sharing an `id`; machines record that id, so it has to be unique
- an entry with no `machineHCL`, or whose HCL declares no `instance_id` and `public_ipv4`
  output — without those a machine comes up with no way to reach it
- an unpinned provider `version`, so a machine built today matches one built next month
- empty `fallback` lists, which are what the form shows when the catalog cannot be read

A fetch that fails for any reason leaves the cached registry in place. The cache is used
whenever the network is not available, however old it is — a machine you need at an airport
must not depend on a GitHub fetch.

## Format

```jsonc
{
  "formatVersion": 1,
  "name": "My providers",
  "homepage": "https://github.com/me/my-registry",   // optional
  "updated": "2026-09-27",                            // optional, for humans
  "providers": [ /* entries, below */ ]
}
```

### A provider entry

| Field | Required | Meaning |
|---|---|---|
| `id` | yes | Stable identifier, e.g. `hetzner`. Machines record it; changing it orphans them. |
| `displayName` | yes | Shown in the UI. |
| `blurb` | no | One line under the name. |
| `tokenHelpURL` | no | Linked from the credential field. |
| `sshUser` | no | Login user on the cloud's stock Ubuntu image. Default `root`. |
| `managesSSHKey` | no | `false` when the cloud rejects duplicate public keys, so the key must be registered through its API first. Default `true`. |
| `supportsPause` | no | Whether the machine can be stopped and started. Default `true`. |
| `provider` | yes | `{ "source": "hetznercloud/hcloud", "version": "~> 1.48", "body": "" }`. `body` is the inside of the `provider "x" { … }` block; usually empty, because credentials come from the environment and stay out of the state file. |
| `credentials` | yes | What to ask the user for. |
| `environment` | yes | Environment the OpenTofu provider reads, as templates. |
| `machineHCL` | yes | HCL creating exactly one machine, plus its outputs. Inline string, or `{url, sha256}` — see below. |
| `catalogHCL` | no | Data sources and outputs only, to fill the New machine form. Must create nothing. Same two forms. |
| `catalog` | no | How to read that run's outputs. |
| `fallback` | yes | Lists used when there is no catalog, or it fails. |
| `extraVariables` | no | Extra `variable` blocks this module needs, and their values. |

### Credentials

```jsonc
{
  "key": "token",                          // referenced as {{secret.token}}
  "label": "API token",
  "secret": true,                          // secrets go to the keychain, never to disk
  "environmentVariable": "HCLOUD_TOKEN",   // read from the shell if already exported
  "help": "Console → Security → API tokens, Read & Write."
}
```

### Inline or remote HCL

A bare string is inline HCL, which keeps a small provider readable in one file:

```jsonc
"machineHCL": "resource \"hcloud_server\" \"machine\" { ... }"
```

Anything real is easier to read, diff and reuse as its own `.tf` file, so a source can
instead be a URL — and then it **must** carry a SHA-256:

```jsonc
"machineHCL": {
  "url": "https://raw.githubusercontent.com/me/registry/main/aws/main.tf",
  "sha256": "9f2c…64 hex chars"
}
```

The hash is not bureaucracy. This HCL runs against your cloud credentials. Without a hash,
whoever serves that URL — or whoever takes over that domain in two years — can change what
gets applied, silently, long after the registry was reviewed. The hash pins the file to the
bytes that were reviewed, which is what makes it safe for a registry to point at a file it
does not itself host. A remote source with no `sha256`, or a malformed one, is refused.

Generate it with:

```bash
shasum -a 256 main.tf
```

### Why JSON and not YAML

YAML is nicer for multi-line text, and multi-line HCL inside JSON is genuinely unpleasant —
that was the strongest argument for it. Remote sources remove that argument: the HCL lives
in a real `.tf` file where it belongs, and what stays in the registry is short. JSON also
needs no parser beyond the one already in the app, and a registry is a security boundary
where "no extra dependency" is worth something. If you find yourself wanting YAML, that is
usually a sign the HCL should be a separate file.

### Templates

Three namespaces, expanded wherever a template is allowed:

- `{{secret.<key>}}` — a secret credential
- `{{field.<key>}}` — a non-secret credential
- `{{request.<name|region|size|image>}}` — the machine being created

An unknown placeholder expands to empty rather than failing: a provider ignoring a variable
it does not need is normal. The language is deliberately this small — a registry should be
readable by someone who has never seen the codebase, and an expression language would turn
a JSON file into a program.

### The HCL contract

`machineHCL` is given these variables:

`name`, `region`, `size`, `image`, `ssh_public_key`, `ssh_key_ids`, `user_data`, `tags`

and must declare these outputs:

| Output | Notes |
|---|---|
| `instance_id` | String. Required. |
| `public_ipv4` | Required — this is how the machine is reached. |
| `instance_name` | |
| `public_ipv6` | `""` when the cloud gives none. |
| `private_ipv4` | `""` when there is none. |
| `state` | The cloud's own word for running/stopped. |

### Catalog mapping

`catalogHCL` outputs lists of objects; `catalog` says which output holds what, and which
keys are the id and the label:

```jsonc
"catalog": {
  "regions": { "output": "datacenters", "id": "name", "label": "description" },
  "sizes":   { "output": "server_types", "id": "name", "label": "description" },
  "images":  { "output": "images",      "id": "name", "label": "description" }
}
```

Anything omitted falls back to the static list.

### Fallback

```jsonc
"fallback": {
  "regions": [{ "id": "nbg1", "label": "Nuremberg, DE" }],
  "sizes":   [{ "id": "cx23", "label": "2 vCPU · 4 GB" }],
  "images":  [{ "id": "ubuntu-26.04", "label": "Ubuntu 26.04" }],
  "defaultRegion": "nbg1",
  "defaultSize": "cx23",
  "defaultImage": "ubuntu-26.04"
}
```

## Hosting your own

Any URL that returns the JSON works — GitHub Pages, a gist's raw URL, a file server on your
network. Set it in **Settings → Providers → Registry**. The app fetches it, validates it,
and shows you what it found before it replaces what you had.

To start from ours:

```bash
curl -O https://codexremote.io/registry.json
```

Edit, host, point the app at it. To contribute a cloud back, open a pull request against
`site/registry.json`.
