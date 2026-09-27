# Codex Remote

## What it is

A macOS menu bar app that provisions a cloud server and wires it up as a remote coding
agent — Codex, Claude Code, or both — then hands it to the tools the user already works in.

## The mechanism, in one sentence

It turns "I need a machine for this agent" into one button by treating a cloud as data
(OpenTofu HCL plus the environment its credentials map onto), so the whole catalogue of
providers is a JSON file fetched at runtime rather than code shipped in a release.

## The problem

Renting a server takes a minute. Making a coding agent *live* on one is a pile of chores
that are individually trivial, collectively tedious, and repeated for every machine:

- A host block in `~/.ssh/config` — and it cannot be behind an `Include`, because the Codex
  app parses that file with a library that never expands them. A host behind one is
  invisible and there is no error saying so.
- Installing the CLI, authenticating, and getting past a first-run wizard that blocks
  forever under a service manager because nobody is there to pick a theme.
- Claude Code needs its *own* login. A copied credential authenticates but its refresh
  token is single-use, so the two installs invalidate each other.
- Keeping it alive across a reboot, which means systemd units rather than a terminal.
- Your MCP servers stay on your Mac.
- Your project stays on your Mac. A clone leaves the gitignored `.env` behind, so the
  project arrives looking complete and does not run.

## Who it is for

Developers who already use Codex or Claude Code daily and have hit the limits of their
laptop: long builds, memory, "I want this to keep running while the lid is shut", or work
that should not happen on the machine they take to a café.

They bring their own cloud account and pay the provider directly. There is no service in
the middle and no account to create.

## The real scene

Someone at a desk with Codex or Claude Code already open, mid-task, who has just realised
this job wants a bigger machine. They are not shopping for infrastructure; they want to
keep working. The menu bar is the right surface because it is one click away from whatever
they were doing, and it stays out of the Dock.

## What is true and provable

- One click to a working machine; end to end takes about four minutes on Hetzner
- Runs on Hetzner, AWS, DigitalOcean, Linode, Vultr and Scaleway via bundled OpenTofu
- Claude Code runs as a non-root `claude` account with its own login
- Machine rows show live CPU, memory and running agent sessions over SSH; blue means idle
  and safe to stop, green means work is running
- `codex-remote push` clones or copies a project and carries the untracked `.env` files
- An MCP server lets an agent manage machines; reading is always on, changing is opt-in,
  destroying is a separate switch
- Everything installed is a systemd unit enabled at boot
- 166 tests
- MIT, open source

## Brand commitments

- **Not affiliated with OpenAI or Anthropic.** This must be visible on the site. "Codex",
  "ChatGPT", "Claude" and "Claude Code" are used only to say what it interoperates with.
- Honest about the rough edges rather than polished over them: the build is ad-hoc signed,
  not notarised, and the site says what that means.
- No invented metrics, customers, testimonials or benchmarks. Nothing but what is above.

## Primary action

`brew install --cask pandelisz/tap/codex-remote` — this works today and must be the most
prominent thing on the page after the proposition itself.

## Platform

Static site, no build step, deployed from `site/` by GitHub Actions to codexremote.io.
macOS 15+ app; Swift/SwiftUI.
