# Codex and Claude Code on a machine

A machine can run either agent or both. They reach you in opposite directions, and that
decides almost everything else about how Codex Remote handles them.

|  | Codex | Claude Code |
|---|---|---|
| How you reach it | the Codex app SSHes in | it dials out to Anthropic |
| Where it appears | Codex app Connections | claude.ai/code, your phone, any Claude session |
| Local state needed | a host block in `~/.ssh/config` | none |
| Credentials | this Mac's `auth.json` is copied | **the machine signs in itself** |
| Pause/resume | yes | yes (it is the same server) |

## Codex

Codex has two unrelated remote mechanisms, and only one of them is the thing people mean
by "my machine shows up in Codex".

**Remote connections — the supported one, and what Codex Remote targets.** The Codex desktop app
reads concrete host aliases out of `~/.ssh/config`, then **starts `codex app-server` on the
machine itself over SSH**, in the remote user's login shell. Nothing listens; there is no
tunnel and no port. What a machine needs is only:

1. a concrete `Host` block in `~/.ssh/config` (no wildcards),
2. `codex` on the remote login shell's `PATH`,
3. Codex authenticated on the machine.

Codex Remote does all three, and `codex-remote status` reports Codex health by checking exactly
those over SSH — not by pinging a tunnel, which a healthy machine may not have.

**The host block has to be in `~/.ssh/config` itself.** It used to live in
`~/.ssh/config.d/codex-remote` behind an `Include`. OpenSSH expands that; the Codex app does not
— it parses the file with the `ssh-config` npm package, which treats `Include` as an opaque
directive. A machine behind an Include is invisible to Codex, so the block is written
inline, inside markers, at the top of the file (above any `Host *`, because OpenSSH takes
the first value it sees).

Codex Remote also writes the machine into the app's own
`codex-managed-remote-connections`, which additionally pre-seeds the project folder — but
only when the Codex app is **not running**. The app keeps that state in memory and writes
the whole file back on its own schedule, so an edit made underneath it is silently
overwritten. Nothing is lost by skipping it: the machine is discovered from the SSH config
on the next launch either way.

**Control other devices — the dial-out path.** `codex remote-control start` on the machine
makes it connect to OpenAI itself and register an `environmentId`, so it appears under
**Connections → Control other devices** and is reachable from this Mac *or* the phone. No
SSH host block, no inbound port, and no relaunch of the Codex app — the same shape as
Claude's Remote Control. Codex Remote exposes this as **Pair with Codex…** on the machine row,
and `codex-remote codex-pair <name> [--open]`.

Pairing stays manual, and that is a deliberate choice rather than a missing feature. The
client POSTs `{client_id, manual_pairing_code}` to `/wham/remote/control/client/pair`, and
Codex Remote holds the account token it would need to call that itself — but the same client
first checks `/wham/remote/control/mfa_requirement`, because a paired device can execute
code under the user's account. That prompt is the security control; automating past it
would defeat it, and would fail outright for anyone who has MFA on. So Codex Remote does the
parts that are safe to automate — turning remote control on, minting the code, putting it
on the clipboard, and opening `codex://settings/connections` at the right pane — and leaves
the authorisation to the person.

Turning it on installs `codex-remote-control.service` rather than leaving the daemon
running loose. `codex remote-control start` bootstraps a daemon that Codex supervises by
pid, and nothing brings that back after a reboot — a machine you powered off would quietly
drop out of "Control other devices" on the way up. The unit is `Type=oneshot` with
`RemainAfterExit`, because the command bootstraps and returns rather than staying in the
foreground; that means systemd tracks whether the *start* succeeded, not the daemon's
health. Supervising the daemon properly would mean invoking codex's internal
`--managed-daemon` form, which is undocumented and would break the moment they change it.

All three units — `codex-remote-app-server`, `codex-remote-claude` and
`codex-remote-control` — are `systemctl enable`d, so `systemctl status 'codex-remote-*'`
shows everything Codex Remote put on the box and a stop/start brings it all back.

Two caveats. `codex remote-control` is marked `[experimental]` by the CLI, and OpenAI's
docs do not mention it at all: they describe only the desktop route and say remote control
"supports hosts running the ChatGPT desktop app on macOS and Windows". A headless Linux box
works today but is outside the envelope the docs commit to.

**Remote terminal UI mode — the other one.** `codex app-server --listen ws://…` on the
machine plus `codex --remote ws://…` here attaches a *terminal* to a remote app-server.
The docs mark it experimental and unsupported, and it has nothing to do with the app's
Connections list. Codex Remote still sets it up (unit, capability token, and an
`ssh -N -L` tunnel guarded by a 256-bit bearer token) because it is a genuinely useful way
to work from a terminal — but it is not how the machine reaches the Codex app, and a
stopped tunnel is not a sick machine.

Copying `~/.codex/auth.json` to the machine works and is what lets the remote agent run a
turn. Note this is unlike Claude Code, where a copied credential actively breaks both ends
— see below.

## Claude Code

Started as `claude --remote-control <name>`, it connects outbound and the session shows up
in your account. No tunnel, no port, no local registration.

Two details had to be discovered the hard way and are worth keeping written down:

**It needs a pty.** Without a terminal `claude --remote-control` falls through to `--print`
and exits with "Input must be provided either through stdin or as a prompt argument". The
systemd unit therefore runs it under `script -qfec … /dev/null`.

**It needs its own login — copying this Mac's does not work.** The copied credential
authenticates for inference (the machine reports "Claude Max"), but its access token is
usually expired and refreshing consumes a single-use refresh token. Whichever install
refreshes first wins; the other is left with a spent token, falls back to API billing, and
Remote Control disconnects with `/login`. So Codex Remote does not copy it. Instead
`claude auth login` on the machine prints an authorize URL, Codex Remote opens it here, and the
code goes back over SSH — the machine ends up with its own refresh token and nothing is
shared.

That sign-in is a one-off per machine. Until it happens the machine is still fully useful:
Codex works, SSH works, and the row offers **Sign in**.

```bash
codex-remote claude-login <machine>     # or the Sign in button in the menu bar
```

Two smaller things the first-run wizard would otherwise block on — the theme picker and the
"trust this folder" prompt — are pre-answered in `~/.claude.json` during bootstrap.

**It runs as `claude`, not root.** Bootstrap creates a `claude` account with a locked
password, and the systemd unit runs as it (`User=claude`, `HOME=/home/claude`). The account
has passwordless sudo, because an agent on a disposable box has to be able to install
things to be useful — so this is not a sandbox. What it buys is that the agent's own files
are its own, its most permissive mode does not imply root, and a mistake stays inside the
account until it deliberately escalates. Codex Remote's SSH key is copied across, so
`ssh claude@<machine>` shows you the machine as the agent sees it.

The login lives in `/home/claude/.claude/.credentials.json`. A machine set up before this
existed has it in root's home; repairing that machine stops the old service and moves the
credential over rather than asking you to approve a second browser sign-in for a machine
that is already authorised.

The workspace follows the account. `/srv/workspace` is the default and is group-writable
and setgid so both agents can share it; a machine whose saved workspace is still under
`/root` — mode 700, which the `claude` account cannot enter — uses
`/home/claude/workspace` for Claude instead.

## MCP servers

`syncMCPServers` carries this Mac's MCP setup across: the server definitions, the enabled
plugins and their marketplaces, and the OAuth logins for connected servers.

Not everything can travel, and copying it all would leave a machine full of servers that
fail to start. Codex Remote classifies each one and reports both lists:

- **Remote servers** (`https://mcp.linear.app/mcp` and friends) go over and, with their
  tokens, are connected immediately.
- **Local stdio servers** go over only if their command is a portable launcher (`npx`,
  `uvx`, `node`, `bash`…) *and* nothing it runs lives on this Mac. A server pointing at
  `/opt/homebrew/...`, a path under `/Users`, or inside a `.app` bundle stays behind.

```bash
codex-remote mcp     # what would travel, and why the rest would not
```

The OAuth tokens are merged into the machine's credentials file **after** it has its own
login, never as part of it — and with `claudeAiOauth` written first, because Claude Code
only reads the file when that key comes first. Writing it with sorted keys puts `mcpOAuth`
in front and silently signs the machine out, which is pinned by a test.

Plugins can bring hooks that shell out to binaries the machine does not have; a missing one
shows up as a non-blocking `SessionStart` hook error in the Claude log and does not stop
the agent.
