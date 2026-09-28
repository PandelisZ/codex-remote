# Codex Remote Product Hunt launch kit

These assets are ready for the Product Hunt draft for `https://codexremote.io`.

## Media

| File | Use | Size |
| --- | --- | --- |
| `thumbnail.png` | Product thumbnail, exported from the distributed app icon | 240 × 240 |
| `gallery/01.png` | Lead image: run an agent off your laptop | 1270 × 760 |
| `gallery/02.png` | Choose a cloud provider and coding agent | 1270 × 760 |
| `gallery/03.png` | Keep sessions running and see machine health | 1270 × 760 |
| `gallery/04.png` | Sync a project with `codex-remote push` | 1270 × 760 |
| `gallery/05.png` | First-run setup prompt and provider connection | 1270 × 760 |
| `codex-remote-launch.mp4` | Silent, captioned launch walkthrough | 1920 × 1080, 29.3 s |

The five numbered gallery images form a complete sequence. The video is silent
so its story works on autoplay without sound. Product Hunt's video field
accepts a YouTube or Loom URL; the MP4 must be uploaded to one of those
services before that field can be filled.

The current draft uses the site's OG image as its first gallery item, followed
by `gallery/01.png` and `gallery/05.png`. The other three graphics remain
available if the gallery is expanded later.

## YouTube upload copy

**Title:** Codex Remote — Run Codex and Claude Code on your own cloud machine

**Description:**

> Codex Remote is an open-source macOS menu bar app that sets up coding agents
> on a server in your own cloud account. Choose a provider and machine size,
> install Codex or Claude Code, and manage the server from your Mac.
>
> This 29-second walkthrough shows the machine controls, setup flow, session
> health, project sync, and first-run guide.
>
> Get the app: https://codexremote.io
> Source code (MIT): https://github.com/PandelisZ/codex-remote
> Install: brew install --cask pandelisz/tap/codex-remote
>
> Requires macOS 15 or later. Independent of OpenAI and Anthropic.

The screenshots in the graphics come from the app's real SwiftUI views using
the illustrative local state documented in [`site/img/README.md`](../../site/img/README.md).
No cloud credentials or live machine data appear in them. The graphic's server
name, usage figures, and price are examples, not customer data or a price
promise. The posters use the site's color and type system.

Regenerate the gallery with `./launch/product-hunt/render.sh`, then the video
with `./launch/product-hunt/make-video.sh`. The HTML source is
`launch/product-hunt/cards.html`.

## Draft copy

**Tagline:** Put Codex or Claude Code on your own cloud machine

**Description:** Codex Remote is an open-source Mac menu bar app for putting
Codex and Claude Code on a cloud machine you control. Choose a provider and
size; it provisions the server with OpenTofu, installs the agents, and connects
the machine to the apps you already use. See CPU, memory, and active sessions,
pause idle servers, sync a project, or let an agent manage machines with opt-in
MCP access. Your cloud credentials stay on your Mac. No hosted middleman.
Independent of OpenAI and Anthropic.

**Maker comment:**

> Hi Product Hunt, I'm Pandelis, the maker of Codex Remote.
>
> Renting a VM is quick. Getting a coding agent to live there, survive reboots,
> and appear in the tools you already use is the fiddly part. I built this Mac
> menu bar app to handle that setup against your own cloud account, with no
> hosted control plane.
>
> Choose Codex, Claude Code, or both on Hetzner, AWS, DigitalOcean, Linode,
> Vultr, or Scaleway. See live health and session counts, pause a machine when
> idle, and move a project over with `codex-remote push`. An MCP server lets an
> agent inspect machines; changing and destroying machines are separate opt-in
> permissions.
>
> The app is MIT licensed and independent of OpenAI and Anthropic. Claude Code
> still needs a one-time sign-in on the machine, which the app guides you
> through.
>
> I'd love to hear what feels hardest about moving an agent off your laptop,
> and which provider or workflow you want improved next. Happy to answer
> questions here.
