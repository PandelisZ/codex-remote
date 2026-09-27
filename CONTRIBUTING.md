# Contributing

Thanks for looking. The most valuable contribution by some distance is **a new cloud
provider**, because that needs no Swift and no release — see below.

## Getting set up

```bash
git clone https://github.com/PandelisZ/codex-remote.git
cd codex-remote
swift build
swift test
./Scripts/bundle.sh        # builds build/CodexRemote.app
```

Swift 6, macOS 15 or later. There are no package dependencies and there is no code
generation step; `swift build` is the whole story.

To run the app against your own changes without installing it:

```bash
CODEX_REMOTE_SHOW_IN_DOCK=1 "build/CodexRemote.app/Contents/MacOS/Codex Remote"
```

That flag makes it a regular app with a window instead of a menu-bar-only one, which is
how you get at it when your menu bar is full and how screen recorders can see it.

The CLI is the same binary the app bundles, so `swift build -c release --product codex-remote`
then `.build/release/codex-remote` exercises everything the UI can do.

## Adding a cloud provider

**You do not need to touch this repository, and you do not need to wait for a release.**

A provider is data: some OpenTofu HCL, the environment its credentials map onto, and the
lists that fill the New machine form. The whole catalogue is a JSON file the app fetches at
runtime from <https://codexremote.io/registry.json>.

So there are two ways in:

**Host it yourself.** Copy the registry, add your provider, put it anywhere that serves
JSON, and point Codex Remote at it in **Settings → Providers**. This is the right route for
a homelab, an internal cloud, or anything you do not want in a public list.

```bash
curl -O https://codexremote.io/registry.json
```

**Or open a pull request** against [`site/registry.json`](site/registry.json) to add it for
everyone. That is a data change; it ships the next time the site deploys, and existing
installs pick it up on their next refresh without updating the app.

The format, the HCL contract, and what the loader validates are in
[docs/registry.md](docs/registry.md). Check your entry before opening the PR:

```bash
swift test --filter ProviderRegistryDocumentTests
```

One of those tests validates the shipped `site/registry.json` itself, so a malformed entry
fails locally rather than in review.

### What a provider entry needs

- A concrete `Host` block's worth of connection detail — the module gets `name`, `region`,
  `size`, `image`, `ssh_public_key`, `ssh_key_ids`, `user_data` and `tags`
- Outputs named `instance_id` and `public_ipv4` at minimum; without those a machine comes
  up with no way to reach it
- A **pinned** provider version, so a machine built today matches one built next month
- Fallback lists of regions, sizes and images, because the catalog query can fail
- HCL either inline, or in a `.tf` file referenced by URL **and pinned to a SHA-256**

That hash is not ceremony. Registry HCL runs against someone's cloud credentials, and
without a hash whoever serves that URL — or takes the domain over later — can change what
gets applied long after the entry was reviewed.

## Working on the app

### Tests

```bash
swift test
```

Tests describe behaviour that was worth protecting, usually because it broke once. Prefer
a test that names the failure over one that names the function: `testAnUnsampledMachineNeverClaimsToBeIdle`
tells the next person why the branch exists in a way `testActiveSessions` does not.

If you are changing something that talks to a real machine, say so in the PR and describe
what you ran it against. Several things here can only really be verified that way.

### Comments

Explain the decision, not the mechanism. A comment saying what the code does is noise; one
saying why it does it that way stops someone undoing it. Most comments in this codebase
exist because a plausible-looking alternative is wrong — a copied Claude credential
invalidates both installs, `install /dev/stdin` fails on the second run, an `Include` in
the SSH config is invisible to Codex.

### Things that will surprise you

Worth knowing before you spend an afternoon on them:

- Codex finds a machine by reading **concrete host aliases from `~/.ssh/config`**. It parses
  that file with a library that does not expand `Include`, so entries must be written into
  the file itself.
- The Codex desktop app rewrites its own state file from memory, so edits made underneath a
  running app are silently lost. `CodexAppRegistrar` refuses to write while it is open
  rather than pretending to succeed.
- Claude Code needs its **own** login on each machine. A copied credential authenticates but
  its refresh token is single-use, so the two installs invalidate each other.
- macOS ships **openrsync**, not GNU rsync. It rejects `--info`, `--partial` and most long
  options.
- The menu bar app holds the machine registry in memory, so CLI commands that mutate it
  require the runtime lock.

## Pull requests

Small and focused is easier to review than complete. Include what you tested and how. If it
changes behaviour someone could reasonably depend on, say so plainly in the description.

Bugs and ideas: <https://github.com/PandelisZ/codex-remote/issues>.

## Licence

MIT. By contributing you agree your work ships under it.
