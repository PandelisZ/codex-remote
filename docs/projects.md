# Getting a project onto a machine

You have a repo open. You make a machine. The machine knows nothing about it.

```bash
codex-remote push <machine> [path]
```

Defaults to the current directory. It picks how to send the project, tells you what it is
doing, and prints where it landed.

## Clone or copy

**Clone**, when the work is committed and pushed. The machine pulls from the origin itself,
which is faster than copying and leaves it able to fetch and push afterwards.

**Copy**, when it is not. Uncommitted work, a scratch directory, a repo with no remote —
none of that exists anywhere but your Mac, and a clone would quietly produce a machine with
last week's code on it. A dirty tree therefore stops being cloneable, rather than cloning
and losing the difference.

Force either with `--clone` or `--copy`.

## The files a clone cannot carry

The whole point of a `.gitignore` is that git will not move those files. Which means a
clone gives you a project that does not run, and the reason is invisible — the code is all
there.

So the untracked configuration is sent separately and written `0600`:

```
.env  .env.local  .env.development  .env.production  .env.test
.envrc  .npmrc  .netrc
```

Matched by name rather than by reading `.gitignore`, because the question is not "is this
ignored" — `node_modules` is ignored too — but "would the project fail without it".
Everything on that list is small and hand-written.

## What is left behind

`node_modules`, `.venv`, `__pycache__`, `dist`, `build`, `target`, `.next`, `.gradle`,
editor directories and logs.

`node_modules` in particular is not an optimisation: copying it from macOS to Linux ships
native modules built for the wrong platform, and the failures are confusing. Run your
install on the machine.

There is no `--delete`. The machine may have build output, a database, or work an agent
did there, and a flag that removes anything not present on your Mac has no business running
against a working directory by default.

## Letting the machine reach your git host

A cloned private repo needs credentials, and so does pushing back.

```bash
codex-remote push <machine> --forward-agent    # your SSH agent, for this command only
codex-remote push <machine> --gh-token         # your gh token, written to the machine
```

**Agent forwarding** is the better one where it works. The machine authenticates as you for
the duration of the command and no key is ever written to it, so there is nothing left
behind to leak or revoke.

**A `gh` token** does persist on the machine, scoped to whatever that token can do. It is
read from `gh auth token` at the moment you run the command and sent over stdin — not in
the command line, not in the script, so it stays out of `ps` and out of shell history. Use
it when agent forwarding is not an option, and remember the machine can then act as you on
GitHub until the token is revoked.

Neither is the default. With no flag, nothing is set up and a public clone still works.

## From an agent

With changes enabled, the MCP server exposes the same thing as `sync_project` — see
[mcp.md](mcp.md).
