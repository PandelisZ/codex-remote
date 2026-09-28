# Design

Two surfaces, deliberately unlike each other.

The **app** follows Apple's Human Interface Guidelines, because it lives in a menu bar
beside every other Mac app and any personality there would read as noise. Its decisions are
in [docs/design.md](docs/design.md).

The **site** is the operator's guide that used to ship in the box with a workstation. This
file describes that world.

## Why a manual

The site's job is to make someone trust a tool that provisions servers on their own cloud
account. The honest version of that pitch includes what will go wrong: the build is ad-hoc
signed and macOS will call it damaged; an agent with write access can spend money; a
registry runs HCL against your credentials.

In most page forms those facts are small print fighting the layout. In a manual they are
the native voice — a CAUTION box is *where a warning goes*, and numbered procedures are
*how you are told to do a thing*. The form carries the product's honesty instead of
resisting it.

It also refuses what this page had been: mono eyebrows over headings, same-size feature
cards, cool-grey systems palette. That is the arrangement models produce for a developer
tool, and it is what the previous build landed on.

## Palette

Committed, not restrained: one saturated colour owns whole regions rather than accenting a
neutral ground. The board red carries the masthead and the colophon end to end.

| Token | Light | Dark | Role |
|---|---|---|---|
| `--cover` | `#8c1d2c` | `#a8253a` | The manual's board. Masthead, colophon, procedure numerals, selection |
| `--cover-text` | `#8c1d2c` | `#d65a6e` | Legible board red for text on dark stock |
| `--stock` | `#edebe6` | `#171513` | Paper. Neutral warm-grey, deliberately not cream |
| `--stock-2` | `#e4e1da` | `#1f1c19` | A tinted panel on the same sheet: command blocks |
| `--ink` | `#1a1714` | `#eae4da` | Body |
| `--ink-2` | `#524c44` | `#b6ac9e` | Secondary |
| `--ink-3` | `#7c746a` | `#8b8174` | Section numbers, captions, the plate |
| `--rule` / `--rule-2` | `#c9c4ba` / `#d9d5cc` | `#37322c` / `#272320` | Heavy and light hairlines |
| `--caution` | `#8a4f07` | `#d59a3e` | The CAUTION rule and label. Never used decoratively |
| `--ok` | `#2f6b3f` | `#6fae7d` | The "Codex Remote" side of a comparison |

Dark mode is the same manual under a desk lamp, not an inversion: darker stock, the same
board red brightened enough to hold contrast, warm ink.

## Type

Three faces, each with one job.

- **Archivo** — headings, furniture, labels, the masthead. A grotesque with enough width and
  weight range to set a cover at 104px and a table label at 12px.
- **Source Serif 4** — body. Manual body text is serif; it also separates prose from every
  machine-facing string on the page.
- **JetBrains Mono** — commands, part numbers, section numbers, table keys. Only for things
  that are literally code, an identifier, or a measurement. Never as a costume for
  "technical".

Tracking: `-0.025em` on headings, `-0.035em` on the cover. Letterspaced uppercase
(`0.26em`) is reserved for the edition line and the small labels, which is how a manual
sets them.

## Furniture, which is the component language

There are no cards. Structure comes from the manual's own devices:

- **Numbered sections** in the left margin, mono, at `--ink-3`. These are a real sequence,
  not decoration.
- **Procedures** as an ordered list with hanging mono numerals in the board red, ruled
  heavily top and bottom and lightly between.
- **Figures** numbered with the caption beneath, separated by a hairline. `<b>Figure 1.</b>`
  leads the caption.
- **CAUTION boxes**: a 2px rule in `--caution` above, a bold letterspaced label, prose
  beneath. Used for the notarisation caveat and for the agent permission model.
- **Tables** ruled top and bottom only, with a hairline between rows.
- **The plate** — version, platform, licence — set mono and right-aligned in the cover, where
  a part number goes.
- **Comparison rows**, two columns divided by a hairline, each side carrying a small
  letterspaced mark rather than an icon.

## Rules this world keeps

- No eyebrow or kicker above any heading.
- No icons. There is no icon system here; a manual sets its labels in type.
- Elevation is declared once, always as a border. No shadows anywhere on the page.
- Browser surfaces are themed: selection takes the board red, focus rings are board red at
  3px offset, scrollbars use the rule and panel tokens, numerals in the plate and tables are
  tabular.
- The install command may wrap rather than clip. It is the primary action, and a clipped
  command is a broken one.

## Where this does not reach

The app keeps HIG. The registry JSON, the CLI's output and the docs are plain text and stay
that way. This world is the site.
