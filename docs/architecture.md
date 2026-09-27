# How Codex Remote is put together

```
CodexRemoteApp (SwiftUI MenuBarExtra)     codex-remote (CLI)
            └───────────┬───────────────────┘
                   MachineManager
        ┌──────────────┼──────────────┬─────────────────┐
  ProvisionPipeline  TunnelManager  HealthMonitor  CodexAppRegistrar
        │
  ComputeProvider
        ├── TofuProvider ── TofuModule × Hetzner · DigitalOcean · EC2 · Linode · Vultr · Scaleway
        │        └── TofuRunner ── bundled OpenTofu binary
        ├── native API clients (Hetzner · DigitalOcean · EC2) as runtime delegates
        └── StaticHostProvider · MockProvider
        │
  SSHClient · BootstrapScript · CodexRegistrar
```

`MachineManager` is the only object holding state. The app and the CLI are both thin shells
over it, which is why everything the menu bar can do is scriptable and vice versa.

## Why an SSH tunnel

Note this is about the *terminal* path, not how the machine reaches the Codex app. The app
finds a host in `~/.ssh/config` and starts `codex app-server` on it over SSH itself, with no
tunnel and no listening socket — see [agents.md](agents.md). What follows is the separate,
experimental "remote terminal UI" mode, which attaches a local `codex --remote` to a remote
app-server. A machine can be perfectly usable from the Codex app with none of it running.

`codex app-server --listen ws://…` binds loopback only and says so on startup:

```
note: binds localhost only (use SSH port-forwarding for remote access)
```

So the agent on the machine is unreachable from the internet by construction. Codex Remote holds
one `ssh -N -L 127.0.0.1:<local>:127.0.0.1:1456` per machine, supervised with exponential
backoff. The tunnel process is deliberately excluded from SSH multiplexing
(`ControlMaster=no`, `ControlPath=none`) — a persisted master would keep holding the
forwarded port after Codex Remote quits and the next launch could not bind it.

A 256-bit bearer token per machine sits behind that: `--ws-auth capability-token` with the
token in a root-only file on the machine and in the login keychain here. It never appears
in a config file, a launcher script, a log line, or a command line.

## Single ownership

Tunnels bind fixed loopback ports and the registry is a shared file, so exactly one process
may own the running side. `RuntimeLock` is a `flock` on `~/.codex-remote/owner.lock`;
whoever holds it runs the tunnels, the health polling and the Codex app sync. It is
released automatically when the holder exits, even on a crash.

Without it, the menu bar app and a `codex-remote` run both bind port 14560 and produce an
endless "Address already in use" reconnect loop.

## Why OpenTofu, and what it does not do

Every machine is created and destroyed by OpenTofu, applying a per-cloud `TofuModule` in
its own workspace under `~/.codex-remote/tofu/machines/<machine-id>/`. The binary ships
inside the app bundle; if it is missing the runner downloads a pinned release and verifies
it against OpenTofu's published checksums before using it.

Two properties come free with this and are worth naming:

- **Re-running is safe.** A provision that fails after the server exists can simply be run
  again: the apply is a no-op against the recorded state rather than a second server. That
  is what makes `repair` cheap.
- **The provider ecosystem is the product.** Adding a cloud is a data file, not an API
  client.

What it does not give us is power state. OpenTofu describes what should exist, not whether
it is switched on, so pause and resume go through the cloud's own API — which is why a
native client, where Codex Remote has one, is kept as a *runtime delegate* rather than deleted.
The delegate also serves status polling and the New machine form, neither of which should
wait on a provider plugin download.

Because most clouds cannot be exercised live without an account on each,
`codex-remote tofu validate` checks every module's generated HCL against that provider's real
schema. It creates nothing, and it caught three genuine errors the first time it ran.

## Idempotence

Every bootstrap stage can be re-run: that is what makes `repair` work and what makes it
safe to retry a stage when the SSH connection drops. Installing packages on a fresh cloud
image restarts services — sometimes sshd — and the session dies even though the work
finished. `SSHClient.runScript` tells a dropped link apart from a failed script and retries
only the former.

The base stage also stands `unattended-upgrades` down for the duration and tells
`needrestart` never to bounce sshd, because the stock Ubuntu cloud image will otherwise do
both while you are installing.

## Files Codex Remote owns, and files it borrows

It owns `~/.codex-remote/` outright.

This used to be `~/.codex/codex-remote`, inside Codex's own directory. That was the wrong
place: `~/.codex` belongs to Codex, so `codex` could not clean up after itself without
taking our state, and our uninstall could not remove its own directory without touching
theirs. `Paths.migrateLegacyHome()` moves anything still at the old path on first use, and
repoints a shell profile that sourced the old `shell.sh`.

The move is one-way and the destination is never merged into: if `~/.codex-remote` already
exists, the old directory is left alone rather than combined, because silently merging two
histories is worse than an orphan the user can delete. One consequence during a version
transition: a copy of Codex Remote from before the move, still running, will recreate
`~/.codex/codex-remote` and write to it. Its writes are not picked up. Quit the old copy
before relying on the new one.

It borrows two files belonging to someone else and touches only its own region of each:

- `~/.ssh/config` gets one `Include config.d/codex-remote` line inside sentinel comments; every
  host entry lives in Codex Remote's own file. `ManagedBlock` does the editing and is covered by
  tests asserting that repeated writes are stable and that user content survives.
- `~/.codex/.codex-global-state.json` is the Codex desktop app's. Codex Remote adds entries whose
  `hostId` encodes the machine's UUID, so it can find exactly its own and never disturbs
  one the user added. The first write takes a backup.

`config.toml` is deliberately *not* written. Codex parses unknown tables but ignores them,
and `codex doctor` reports them as unrecognised settings — so a `[codex-remote]` table there
would be a permanent warning for no benefit.

## Known rough edge: the Codex app owns its state file

The desktop app loads that JSON at launch, holds it in memory, and rewrites it wholesale
when it saves. An entry added while it is running is wiped at its next save, and it cancels
scripted quits, so Codex Remote cannot restart it for you.

What Codex Remote does instead: writes the file, says plainly that Codex needs a restart, and
re-applies its entries (at most every five minutes, so it is not a write fight) so they are
there whenever the app does next launch.
