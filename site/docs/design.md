<!-- Copied from docs/design.md by Scripts/sync-site-docs.sh. Edit the repo, not this. -->

# Design notes

Codex Remote follows Apple's current Human Interface Guidelines for macOS 26. The parts that
actually constrained decisions are written down here, because the temptation with a new
material is to use it everywhere and the guidance says the opposite.

## Where Liquid Glass is, and where it is not

Apple's rule is a layer rule. Liquid Glass "forms a distinct functional layer for controls
and navigation elements … that floats above the content layer", and the guidance is
explicit: **don't use Liquid Glass in the content layer**, and **use Liquid Glass effects
sparingly** — "Limit these effects to the most important functional elements in your app."

So glass appears in exactly three places:

| Surface | Why it qualifies |
|---|---|
| The popover's action bar | The control layer of the popover, grouped in one `GlassEffectContainer` |
| A machine's **Open** button | The single most important functional element in the app |
| Window toolbars | The system applies it; Codex Remote only adds `scrollEdgeEffectStyle(.soft)` so content blurs under them |

Everything else — the machine list, the forms, the activity log — is content, and sits on
standard materials with semantic colours. The popover's own background is already a system
material, so the rows need nothing added.

Codex Remote uses the **regular** variant throughout, never **clear**. Clear is for components
floating over visually rich backgrounds like photos or video; Codex Remote's surfaces are text,
and the guidance points text-heavy components at regular.

`Theme.swift` holds the policy. `glassSurface(_:tint:interactive:)` applies glass on
macOS 26, a `.thinMaterial` on macOS 15, and an opaque `.regularMaterial` whenever
**Reduce Transparency** is on — Apple notes glass changes appearance under that setting and
under Increase Contrast, and dropping to an opaque fill is the safe reading for a custom
control.

## Status is never colour alone

The machine list previously showed state as a coloured dot, which is information carried by
colour only and unusable for anyone who cannot separate the hues. Every state now has a
distinct SF Symbol *and* a colour *and* a spoken description:

| State | Symbol | Colour |
|---|---|---|
| Online | `checkmark.circle.fill` | green |
| Not responding | `exclamationmark.circle.fill` | orange |
| Paused | `pause.circle.fill` | secondary |
| Offline | `moon.circle.fill` | secondary |
| Setting up | `arrow.triangle.2.circlepath`, rotating | accent |
| Failed | `exclamationmark.triangle.fill` | red |

`MachinePresentation` is the single place this is decided, so the menu bar glyph, the row
and VoiceOver cannot drift apart.

## Other things the guidelines settled

- **Icon-only controls get a name.** Every `IconButton` carries both `.help()` and
  `.accessibilityLabel`, and a 28×28 hit target — the smallest comfortable pointer target
  on macOS. The menu bar item has its own label, since a glyph and a number read as nothing.
- **Concentric corners.** `Theme.Radius` keeps a control's radius inside its container's, so
  the curves stay parallel rather than crowding.
- **Native shapes over hand-rolled ones.** Settings uses `Form` with `.formStyle(.grouped)`
  and the macOS 15 `Tab` API; detail rows use `LabeledContent`; the Activity filters live in
  a real toolbar instead of a custom header strip.
- **Dialog button order.** Cancel then the default action, bottom-trailing, with the cost
  note on the leading side as a footnote — and `.keyboardShortcut(.cancelAction)` /
  `.defaultAction` so Escape and Return do what they should.

## Deployment target

macOS 15 is the floor — it is what the modern `Tab` API needs. Liquid Glass is applied at
run time where macOS 26 provides it, so a Mac on 15 still gets a native-looking app rather
than a broken one.

## Sources

- [Materials — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/materials)
- [Applying Liquid Glass to custom views — SwiftUI](https://developer.apple.com/documentation/SwiftUI/Applying-Liquid-Glass-to-custom-views)
- [Meet Liquid Glass — WWDC25](https://developer.apple.com/videos/play/wwdc2025/219/)
