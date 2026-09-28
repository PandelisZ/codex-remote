<!-- Copied from docs/mcp.md by Scripts/sync-site-docs.sh. Edit the repo, not this. -->

# Letting an agent manage its own machines

Codex Remote can run as an MCP server, so the agent you are already talking to can look at
your machines and — if you allow it — build and change them itself.

The reason is that the agent usually knows what it needs better than you do at the moment
you are filling in a form. "This needs more memory than my laptop has." "Restore last
week's database dump and run the migration against it." "Install the toolchain and try the
build on Linux." Those are easier to say than to translate into a size dropdown.

## Connecting it

```bash
codex-remote mcp config      # prints the snippet for your agent
```

For Claude Code:

```bash
claude mcp add codex-remote -- /path/to/codex-remote mcp serve
```

For Codex, add it to the `[mcp_servers]` table in `~/.codex/config.toml`.

It speaks JSON-RPC 2.0 over stdio, which is what both expect. Reading works as soon as it
is connected; the rest is off until you turn it on in **Settings → General → Agent access**.

## What it can do, and what has to be allowed

| Tool | Needs | |
|---|---|---|
| `list_machines` | — | Every machine, with health, running sessions, CPU and memory |
| `machine_status` | — | Everything known about one machine |
| `list_providers` | — | Clouds available, and which have an account |
| `list_sizes` | — | Regions, sizes and images **with prices** |
| `run_command` | changes | Any shell command on a machine, as root |
| `sync_project` | changes | Put a local project on a machine |
| `create_machine` | changes | **Bills to your cloud account** |
| `set_power` | changes | Stop or start |
| `repair_machine` | changes | Re-run the remote setup |
| `destroy_machine` | destroy | **Cannot be undone** |

## Why the defaults are what they are

These tools spend money and can delete servers, and an agent will call a tool in a loop
without the hesitation a person would have. Three things follow.

**Reading is always allowed; changing is not.** With changes off, an agent can see
everything and alter nothing. That is genuinely useful on its own — "which of my machines
is idle", "what is this one costing me", "why is that one unhealthy" — and it is the
setting most people should stay on.

**Destroying is separate from changing.** Turning on changes does not grant deletion,
because the two mistakes are not the same size. Creating the wrong machine costs pence and
is undone by deleting it. Deleting the right machine loses whatever was on the disk.

**`destroy_machine` needs the name twice.** It takes a `confirm` argument that must equal
the machine name exactly. This is a guard against the specific failure where a model
produces a plausible name it has not verified — a name that is wrong fails the check
instead of deleting something real.

Beyond that, the tool descriptions carry the warnings an agent reads before choosing:
`create_machine` says it costs money and to check prices first, `destroy_machine` says it
cannot be undone and to confirm with the user in their own words.

## What this does not protect you from

`run_command` runs as root on the machine with no sandbox, which is the point of it — an
agent that cannot install things cannot set up its own environment. Machines are
disposable; treat what runs on them accordingly, and keep anything you would mind losing
in git rather than only on a box.

Nor does any of this substitute for reading what the agent proposes. The settings decide
what is *possible*, not what is *sensible*, and an agent with changes enabled can create
machines until you notice. If you want a machine that only ever does what you asked, leave
changes off and create it yourself from the menu bar.
