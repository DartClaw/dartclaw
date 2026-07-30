---
version: alpha
name: DartClaw
description: "Afterglow — DartClaw's terminal-aesthetic design language. Catppuccin Mocha (dark) / Latte (light) palette, monospace typography, terminal-green accent, phosphor glows, 8-bit crab-mascot brand (assets/logo-*-8bit.png) with a pixel claw-mark signature."
colors:
  # Surface ladder — dark theme (default). 7 levels darkest → brightest.
  # bg-pit and bg-sub-base are derived at runtime via color-mix(); resolved hex below.
  bg-pit: "#06060c"
  bg-crust: "#11111b"
  bg-mantle: "#181825"
  bg-base: "#1e1e2e"
  bg-sub-base: "#2c2c3e"
  bg-surface0: "#313244"
  bg-surface1: "#45475a"
  bg-surface2: "#585b70"
  # Plane roles – which rung each of the three planes occupies. Per-theme aliases,
  # because dark and light map the planes to different rungs (see § Surface ladder).
  bg-chrome: "#11111b"
  bg-card: "#2c2c3e"
  # Foreground
  fg: "#cdd6f4"
  fg-sub1: "#bac2de"
  fg-sub0: "#a6adc8"
  fg-overlay: "#9ea3bb"
  # Accent
  accent: "#a6e3a1"
  accent-dim: "#40a060"
  # Semantic
  success: "#a6e3a1"
  error: "#f38ba8"
  warning: "#fab387"
  info: "#89b4fa"
  # Extended palette — decorative/categorical only (gradients, ambient glows,
  # data-viz categories). Never used for state.
  mauve: "#cba6f7"
  teal: "#94e2d5"
  sky: "#89dceb"
  pink: "#f5c2e7"
  lavender: "#b4befe"
  # Syntax highlighting — categorical (chart-ramp family), never state.
  # Raw Catppuccin hues, not the tuned semantic tokens (see § Code highlighting).
  syntax-keyword: "#cba6f7"
  syntax-string: "#a6e3a1"
  syntax-number: "#fab387"
  syntax-comment: "#9ea3bb"
  syntax-function: "#89b4fa"
  syntax-type: "#f9e2af"
  syntax-builtin: "#94e2d5"
  syntax-punct: "#a6adc8"
  # Light-theme overrides (Catppuccin Latte). Semantic values are tuned darker
  # than raw Latte so badges/pills stay readable on light surfaces.
  bg-pit-light: "#e8eaf0"
  bg-crust-light: "#dee1e9"
  bg-mantle-light: "#eceff5"
  bg-base-light: "#e4e7ef"
  bg-sub-base-light: "#d8dbe4"
  bg-surface0-light: "#ccd0da"
  bg-surface1-light: "#bcc0cc"
  bg-surface2-light: "#acb0be"
  bg-chrome-light: "#eceff5"
  bg-card-light: "#ffffff"
  fg-light: "#4c4f69"
  fg-sub1-light: "#5c5f77"
  fg-sub0-light: "#62677d"
  fg-overlay-light: "#585d6f"
  accent-light: "#24661c"
  accent-dim-light: "#3d7d36"
  success-light: "#24661c"
  error-light: "#a40a2b"
  warning-light: "#933d00"
  info-light: "#0f4ebf"
  mauve-light: "#8839ef"
  teal-light: "#0d686d"
  sky-light: "#04a5e5"
  pink-light: "#ea76cb"
  lavender-light: "#7287fd"
  syntax-string-light: "#40a02b"
  syntax-number-light: "#fe640b"
  syntax-function-light: "#1e66f5"
  syntax-type-light: "#df8e1d"
typography:
  metric-value:
    fontFamily: JetBrains Mono
    fontSize: 32px
    fontWeight: 600
    lineHeight: 1.15
    letterSpacing: -0.02em
  display:
    fontFamily: JetBrains Mono
    fontSize: 24px
    fontWeight: 600
    lineHeight: 1.2
    letterSpacing: -0.02em
  page-title:
    fontFamily: JetBrains Mono
    fontSize: 20px
    fontWeight: 600
    lineHeight: 1.3
  heading-md:
    fontFamily: JetBrains Mono
    fontSize: 18px
    fontWeight: 600
    lineHeight: 1.3
    letterSpacing: -0.02em
  body-md:
    fontFamily: JetBrains Mono
    fontSize: 14px
    fontWeight: 400
    lineHeight: 1.6
  label-md:
    fontFamily: JetBrains Mono
    fontSize: 14px
    fontWeight: 500
    lineHeight: 1.3
  caption:
    fontFamily: JetBrains Mono
    fontSize: 12px
    fontWeight: 400
    lineHeight: 1.6
spacing:
  base: 4px
  sp-1: 4px
  sp-2: 8px
  sp-3: 12px
  sp-4: 16px
  sp-5: 20px
  sp-6: 24px
  sp-8: 32px
  sp-10: 40px
  sp-12: 48px
  sidebar-w: 260px
  topbar-h: 48px
  input-h: 80px
  container-max: 900px
  container-wide: 1280px
  measure: 72ch
rounded:
  sm: 4px
  lg: 6px
  full: 9999px
components:
  button:
    backgroundColor: "{colors.bg-surface0}"
    textColor: "{colors.fg}"
    typography: "{typography.body-md}"
    rounded: "{rounded.sm}"
    padding: 6px 12px
  button-primary:
    backgroundColor: "{colors.accent}"
    textColor: "{colors.bg-crust}"
    typography: "{typography.body-md}"
    rounded: "{rounded.sm}"
    padding: 6px 12px
  button-ghost:
    backgroundColor: transparent
    textColor: "{colors.fg}"
    typography: "{typography.body-md}"
    rounded: "{rounded.sm}"
    padding: 6px 12px
  button-danger:
    backgroundColor: transparent
    textColor: "{colors.error}"
    typography: "{typography.body-md}"
    rounded: "{rounded.sm}"
    padding: 6px 12px
  button-danger-fill:
    backgroundColor: "{colors.error}"
    textColor: "{colors.bg-crust}"
    typography: "{typography.body-md}"
    rounded: "{rounded.sm}"
    padding: 6px 12px
  button-sm:
    # Size tier only — padding + min-height. Colour, radius and type come from
    # whichever button variant it composes onto; it sets none of them itself.
    padding: 4px 12px
  card:
    backgroundColor: "{colors.bg-card}"
    textColor: "{colors.fg}"
    typography: "{typography.body-md}"
    rounded: "{rounded.lg}"
    padding: "{spacing.sp-4}"
  card-sunken:
    backgroundColor: "{colors.bg-crust}"
    textColor: "{colors.fg}"
    rounded: "{rounded.lg}"
    padding: "{spacing.sp-4}"
  card-elevated:
    backgroundColor: "{colors.bg-surface0}"
    textColor: "{colors.fg}"
    rounded: "{rounded.lg}"
    padding: "{spacing.sp-4}"
  well:
    backgroundColor: "{colors.bg-base}"
    rounded: "{rounded.sm}"
    padding: "{spacing.sp-3}"
  well-deep:
    backgroundColor: "{colors.bg-crust}"
    rounded: "{rounded.sm}"
    padding: "{spacing.sp-3}"
  panel-accent:
    backgroundColor: "{colors.bg-card}"
    textColor: "{colors.fg}"
    rounded: "{rounded.lg}"
    padding: "{spacing.sp-4}"
  panel-info:
    backgroundColor: "{colors.bg-card}"
    textColor: "{colors.fg}"
    rounded: "{rounded.lg}"
    padding: "{spacing.sp-4}"
  panel-error:
    backgroundColor: "{colors.bg-card}"
    textColor: "{colors.fg}"
    rounded: "{rounded.lg}"
    padding: "{spacing.sp-4}"
  panel-warning:
    backgroundColor: "{colors.bg-card}"
    textColor: "{colors.fg}"
    rounded: "{rounded.lg}"
    padding: "{spacing.sp-4}"
  input:
    backgroundColor: "{colors.bg-base}"
    textColor: "{colors.fg}"
    typography: "{typography.body-md}"
    rounded: "{rounded.lg}"
    padding: "{spacing.sp-3}"
  form-input:
    backgroundColor: "{colors.bg-base}"  # + inset-sm depth; element-qualified rule
    textColor: "{colors.fg}"
    typography: "{typography.body-md}"
    rounded: "{rounded.sm}"
    padding: 8px 12px
  form-select:
    backgroundColor: "{colors.bg-base}"  # chevron painted via background-image, see § Native selects
    textColor: "{colors.fg}"
    typography: "{typography.body-md}"
    rounded: "{rounded.sm}"
    padding: 8px 40px 8px 12px
  form-textarea:
    backgroundColor: "{colors.bg-base}"
    textColor: "{colors.fg}"
    typography: "{typography.body-md}"
    rounded: "{rounded.sm}"
    padding: 8px 12px
  form-checkbox:
    backgroundColor: "{colors.bg-base}"  # accent fill when :checked; radio is the same box, round
    textColor: "{colors.fg}"
    rounded: "{rounded.sm}"
  form-toggle:
    backgroundColor: "{colors.bg-surface2}"  # accent track when :checked
    rounded: "{rounded.full}"
  composer:
    backgroundColor: "{colors.bg-base}"  # the input object; quiet focus (green caret + send wake, no ring)
    textColor: "{colors.fg}"
    typography: "{typography.body-md}"
    rounded: "{rounded.lg}"
    padding: 8px 12px
  status-badge:
    backgroundColor: "{colors.bg-surface0}"
    textColor: "{colors.fg}"
    typography: "{typography.caption}"
    rounded: "{rounded.full}"
    padding: 2px 8px
  status-badge-muted:
    backgroundColor: "{colors.bg-base}"  # + 5% fg-sub0 tint; neutral, never a semantic hue
    textColor: "{colors.fg-sub1}"  # sub0 lands under AA on its own tint in light
    typography: "{typography.caption}"
    rounded: "{rounded.full}"
    padding: 2px 8px
  status-pill:
    backgroundColor: "{colors.bg-surface0}"
    textColor: "{colors.bg-crust}"
    typography: "{typography.caption}"
    rounded: "{rounded.full}"
    padding: 2px 10px
  meter:
    backgroundColor: "{colors.bg-crust}"
    rounded: "{rounded.full}"
    height: 6px
  terminal-frame:
    backgroundColor: "{colors.bg-crust}"
    textColor: "{colors.fg}"
    rounded: "{rounded.lg}"
  skeleton:
    backgroundColor: "{colors.bg-surface0}"
    rounded: "{rounded.sm}"
  kbd:
    backgroundColor: "{colors.bg-surface0}"
    textColor: "{colors.fg-sub1}"
    typography: "{typography.caption}"
    rounded: "{rounded.sm}"
    padding: 0 8px
  card-glass:
    backgroundColor: "{colors.bg-mantle}"  # at 60% alpha + 14px backdrop blur
    textColor: "{colors.fg}"
    rounded: "{rounded.lg}"
    padding: "{spacing.sp-4}"
  dialog:
    # The frame composes card + card-glass, so surface and material come from
    # there; this family owns the width contract and the header/body/footer
    # split only. Padding is 0 on the frame — the sub-elements carry their own.
    backgroundColor: "{colors.bg-mantle}"  # via card-glass
    textColor: "{colors.fg}"
    rounded: "{rounded.lg}"
    padding: 0
    width: min(92vw, 680px)  # --sm and --confirm take min(92vw, 480px)
  identicon:
    backgroundColor: "{colors.mauve}"  # dual-hue gradient, variant by entity-id hash
    textColor: "{colors.bg-crust}"
    typography: "{typography.caption}"
    rounded: "{rounded.sm}"
  tool-call:
    backgroundColor: "{colors.bg-base}"  # well-tier; 3px left edge encodes state
    textColor: "{colors.fg}"
    typography: "{typography.body-md}"
    rounded: "{rounded.sm}"
    padding: 8px 12px
  approval-card:
    backgroundColor: "{colors.bg-card}"  # Card family + warning left edge while waiting
    textColor: "{colors.fg}"
    typography: "{typography.body-md}"
    rounded: "{rounded.lg}"
    padding: "{spacing.sp-4}"
  run-card:
    backgroundColor: "{colors.bg-card}"  # Card family + amber attention ring
    textColor: "{colors.fg}"
    typography: "{typography.body-md}"
    rounded: "{rounded.lg}"
    padding: "{spacing.sp-4}"
  chip:
    backgroundColor: "{colors.bg-surface0}"  # neutral reference token, never state
    textColor: "{colors.fg-sub1}"
    typography: "{typography.caption}"
    rounded: "{rounded.sm}"
    padding: 2px 8px
  notif-item:
    backgroundColor: transparent  # hover bg-surface0; unread adds accent edge + bg-sub-base
    textColor: "{colors.fg-sub1}"
    typography: "{typography.body-md}"
    rounded: "{rounded.sm}"
    padding: 8px 12px
  palette-item:
    backgroundColor: transparent  # --active adds bg-surface0 + accent left edge
    textColor: "{colors.fg-sub1}"
    typography: "{typography.body-md}"
    rounded: "{rounded.sm}"
    padding: 8px 12px
  pipeline-node:
    backgroundColor: "{colors.bg-base}"  # state fills the node (done/running/failed/blocked)
    textColor: "{colors.fg}"
    rounded: "{rounded.full}"
  tab:
    backgroundColor: transparent  # active adds accent text + 2px accent underline
    textColor: "{colors.fg-sub0}"
    typography: "{typography.label-md}"  # composed via .t-label; the rule sets font: inherit only
    padding: 8px 12px
  tabs-sticky:
    # 85% tint of the --bg-ground-edge gradient stop + 14px backdrop blur.
    # bg-ground-edge is a gradient endpoint, not a plane, so it has no entry in
    # the colors map above; bg-base is the plane it fades from.
    backgroundColor: "{colors.bg-base}"
  list-toolbar:
    backgroundColor: transparent  # layout only: search field grows, actions keep their width
  pager:
    backgroundColor: transparent  # layout only: controls are .btn.btn-ghost
    textColor: "{colors.fg-sub0}"
    typography: "{typography.caption}"
---

# DartClaw Design System — "Afterglow"

Terminal-aesthetic design language for a developer-focused AI agent runtime. Catppuccin Mocha/Latte palette, monospace typography, terminal-green accent, phosphor glows, claw-scratch signature.

**Companion files** (same directory):

- `tokens.css` — CSS custom properties for runtime use
- `components.css` — component class rules
- `icons.css` — Lucide icon set as CSS mask-image data URIs
- `showcase.html` — interactive component reference
- `assets/` — local copies of the brand logos so the folder is self-contained (canonical originals: repo-root `assets/`)

**Source-of-truth scope** – `tokens.css`, `components.css`, and `icons.css` are canonical. Their served counterparts under `packages/dartclaw_server/lib/src/static/` are byte-identical beneath a two-line SHA-256 provenance header; live-only extensions in those three served files are drift. `DESIGN.md` and `showcase.html` are prose and demo artifacts that are never synced. The icon-inventory test in `packages/dartclaw_server/test/static/design_system_icons_sync_test.dart` is an additional completeness check, not a different sync policy.

## Overview

DartClaw is an AI agent runtime aimed at developers and operators. The UI should feel like a high-quality terminal application: dense but readable, instrumented but calm, with deliberate use of color to communicate state rather than to decorate.

- **Tone** — terminal-native, instrumented, restrained. Not "consumer SaaS". Not "skeuomorphic IDE". Aim for the polish of a top-tier developer dashboard (Linear, Vercel, Raycast) rendered through a Catppuccin-mocha lens.
- **Aesthetic primitives** — monospace type throughout, a layered surface ladder for depth, hue-aware shadows that match the palette's blue-violet tint, a single terminal-green accent, semantic colors only for state (success/error/warning/info), and an extended decorative palette (mauve/teal/sky/pink/lavender) reserved for gradients, ambient glows, and data-viz.
- **Density** — information-dense by default; whitespace is earned, not assumed. The reading rhythm is set by tight, rectangular cards on an atmospheric ground: a base gradient with faint off-axis color glows and film-grain noise, so empty regions never read as dead flat panels.
- **Modes** — first-class dark and light themes via `data-theme="light"` on `<html>`. Dark is default and the reference theme; light values are tuned for contrast, not just inverted.

## Identity

DartClaw's brand is the **pixel-art crab mascot**: a crab whose body is a CRT terminal showing a green `>_DC` prompt, with green→blue gradient claws. The design language is called **Afterglow** — what a CRT phosphor does after the beam passes — and it is literally the mascot's world rendered as UI: phosphor glow on dark glass, terminal green, and 8-bit edges where the brand peeks through. When extending the system, two tests: *does this read as light persisting on glass?* (chrome, depth, motion) and *would it fit in the mascot's universe?* (brand moments).

### Brand assets

Canonical raster assets live in `assets/` at the repo root:

| Asset | File | Use for |
|---|---|---|
| Mascot avatar (512×512) | `logo-avatar-512-8bit.png` | Favicon/avatar, masthead, empty states, about screens |
| Banner lockup (1280×246) | `logo-banner-1280-8bit.png` | README, docs headers, marketing surfaces |

Rules: always render scaled pixel art with `.pixel-art` (`image-rendering: pixelated`) — browser smoothing turns it to mush. Never recolor, redraw, restyle, or drop-shadow the mascot. Both assets have transparent backgrounds and work on dark and light surfaces. This folder carries copies under `dev/design-system/assets/` so the showcase is self-contained — if the brand assets ever change, refresh the copies.

### The ownable elements, in priority order

1. **The mascot** — the identity itself. It appears at brand moments: masthead, empty states, onboarding. It is a *character*, not an icon — never shrink it below ~32px where the pixels stop reading.
2. **The pixel claw mark** (`.claw-mark`) — the mascot's claw-swipe abstracted into three stepped strokes of true pixel cells, in the claw gradient (green → teal → blue). Theme-aware CSS, scales with font-size. For logo lockups, empty states, and at most one hero moment per view.
3. **The pixel claw loader** (`.claw-loader`) — the claw, scratching: the same strokes pulsing in sequence with `steps()` easing. The signature indeterminate indicator for agent "thinking" moments — where users stare longest, so the brand lives there. The scanning bar remains the anonymous in-place sweep.
4. **The prompt glyph** (`❯`) — terminal heritage, echoing the mascot's `>_` screen. Used in text contexts (tool indicators, empty-state copy). Never decorate body content with it.
5. **Print-in motion** (`.print-in`) — content *prints* into place (rise + fade), the way terminal output arrives. One entry treatment for everything: cards, messages, swapped fragments.

**8-bit motion rule** — pixel things snap, photons glide. Brand/pixel elements animate with `steps()` (the loader's stepped pulse); glass, glows, and lifts use the smooth easing tokens. Don't mix the two on one element.

**Scarcity doctrine** — signature elements work because they're rare. One claw moment per view. The claw loader replaces spinners, not scan-bars. If the mark appears in three places on one screen, it's wallpaper.

## Colors

The palette is rooted in **Catppuccin Mocha** (dark, default) and **Catppuccin Latte** (light). It was chosen for warmth, readability, and the existence of complete, balanced light/dark variants from the same designer.

- **Surfaces** form a 7-level ladder from `bg-pit` (deepest inset) to `bg-surface2` (border-level). Use `color-mix(in oklab, ...)` to derive intermediate values rather than introducing new hex constants. On top of the ladder sit two **plane roles** – `bg-chrome` and `bg-card` – because the two themes put the same plane on different rungs (see § Surface ladder).
- **Foreground** has four steps from `fg` (primary text) to `fg-overlay` (placeholders/disabled). `fg-overlay` is intentionally low-emphasis – never use it for essential metadata. In **dark** it is the lightest-to-darkest fourth step as the name suggests; in **light** it is pinned to the WCAG AA floor on the surfaces § Accessibility guarantees it against, which lands it at roughly `fg-sub1`'s depth rather than above `fg-sub0`. Light-theme de-emphasis therefore comes from size and weight, not from a lighter grey – do not "correct" the light value upward without re-checking those three contrast pairs.
- **Accent** is terminal-green (`#a6e3a1` Mocha, `#24661c` Latte). It is the only "branding" color. Reserve it for primary actions, the streaming cursor, active selection, and the success state.
- **Semantic** colors are reserved for state: `success` (green), `error` (pink/red), `warning` (orange), `info` (blue). Light-theme semantics are intentionally darker than raw Latte swatches so pills, badges, and active states remain readable on light surfaces.
- **Provider brand** – `--brand-claude` and `--brand-codex` identify the agent provider on provider badges; they never carry state. `--brand-codex` aliases the extended-palette teal and replaces Codex's former borrow of semantic `--info`. Because these two are the only extended-palette hues that render as *text*, their light values are held dark enough to clear 4.5:1 as badge labels – legibility outranks swatch fidelity for them, and the dark values are unconstrained.
- **Extended palette** — `mauve`, `teal`, `sky`, `pink`, `lavender` exist so the system isn't monochrome-plus-green. They are **decorative/categorical only**: multi-hue gradients (logo, featured cards, `.text-gradient`), the ambient body glows, identicons, and data-viz category colors. They never carry state — a user must never have to ask whether purple means failure.
- **Prompt hero** — `.prompt-hero` (+ `-mascot`/`-eyebrow`/`-title`/`-sub`, `--center`, `--fill`) is the typed-glyph greeting: optional mascot crown, teal eyebrow, display-tier line opening with the accent prompt mark, a `.text-gradient` phrase, and the `steps()`-blinking `.cursor-blink` block (pinned visible under reduced motion). It is a **claw moment** — one per view; a mascot-crowned hero counts as that view's single brand moment (the crown belongs on landing surfaces, not status pages). Ships mascot-crowned on the chat landing state and plain on the health dashboard; copy may follow status, but the hero is never the semantic signal — a badge or dot still carries state.
- **Chart ramp** — `--chart-1` through `--chart-6` is the *ordered* categorical ramp (accent, info, mauve, teal, pink, sky). Assign by series index, never by hand-picking — the order keeps adjacent series distinguishable and charts consistent across views.

### Surface ladder (7 levels)

| Token | Dark | Light | Usage |
|---|---|---|---|
| `bg-pit` | `color-mix(crust, #000)` | `color-mix(crust, #fff)` | Deepest inset (below crust) |
| `bg-crust` | `#11111b` | `#dee1e9` | Code blocks, deep wells, input bg – **and the dark chrome plane** |
| `bg-mantle` | `#181825` | `#eceff5` | Chat input strip, terminal frame bar, glass base – **and the light chrome plane** |
| `bg-base` | `#1e1e2e` | `#e4e7ef` | Page ground, standard wells |
| `bg-sub-base` | `color-mix(base, surface0)` | `color-mix(base, surface0)` | Between base and surface0 – **the dark card plane** |
| `bg-surface0` | `#313244` | `#ccd0da` | Elevated cards, hover states, default border |
| `bg-surface1` | `#45475a` | `#bcc0cc` | Active states, stronger hover |
| `bg-surface2` | `#585b70` | `#acb0be` | Borders, scrollbar thumb |

### Three planes: chrome, page ground, card

Chrome (`.sidebar`, `.topbar`), the page ground and `.card` occupy **three mutually distinct planes in both themes**. This is a structural rule, not a preference: when two of them resolve to the same token, cards read as holes or bare outlines and no amount of border or shadow work recovers the separation.

The plane roles are their own tokens because the themes map them to different rungs, in opposite directions:

| Plane | Token | Dark | Light |
|---|---|---|---|
| Chrome | `bg-chrome` | `bg-crust` – **below** the ground | `bg-mantle` – **above** the ground |
| Page ground | `bg-base` (+ ambient glows) | `bg-base` | `bg-base` |
| Card | `bg-card` | `bg-sub-base` – **above** the ground | `#ffffff` – above the ground and above chrome |

Rules that hold in both themes:

- Card-vs-ground contrast is **≥ 1.15:1**, measured against the ground *immediately adjacent to the card* – the ground varies across the viewport, so a page average is not the test.
- The three planes are pairwise **≥ 0.02 ΔE(oklab)** apart, measured at the ground *immediately adjacent to the card* – the ground varies across the viewport, and its far edge is allowed to approach the chrome tone as a vignette. A one-level hex step or a 99% colour-mix satisfies a bare inequality while leaving the planes visually identical; 0.02 is the perceptibility floor.
- **No body-gradient stop ever equals the card fill.** The ground band runs between `bg-base` and `bg-ground-edge` and never reaches the card plane.
- No `:hover` fill sinks a card *neutrally* below its own rest fill. Semantic variants deepening their own tint on hover is the designed amplification, not a violation – the failure this bans is a hover that drops the card's surface toward the page ground.
- Semantically tinted cards (`card-metric--*`, `card-tint-*`) must clear the same 1.15:1 floor. In light this is the binding constraint on how far the ground may be lifted: a tint can only pull a white card *down*, so the ground has to sit low enough that a tinted card still separates from it.

Downstream pages consume these tokens; they never re-tone a card, chrome or ground locally. A surface that reads wrong is a token problem.

## Typography

The entire system is set in **JetBrains Mono** (with `Fira Code` and system monospace as fallbacks). Monospace throughout is deliberate: it reinforces the terminal aesthetic, gives consistent column alignment in dense tables and tool indicators, and reduces font loading to a single family.

**Mono-only, decided.** There is no second family and no `--font-sans` token. Hierarchy comes from the widened size scale below, not from a face change: a sans/mono split would have to be applied consistently across every surface to read as a system, and the scale does the same work without that cost.

- **Base size** — 14px (`body-md`). The root stays at 16px so `rem` tokens resolve to their declared sizes; `body` applies `body-md`. Larger sizes are reserved for section headings (18px), page title (20px), display moments (24px), and metric values (32px). Below body, 12px (`caption`) carries metadata and pill text — it is the only smaller size.
- **Weights** — three only: `400` (normal body), `500` (medium — UI labels), `600` (bold — headings, role labels).
- **Line height** — `1.6` for body and code; `1.3` for headings and tight UI like the input textarea; tighter still (≤1.2) at display sizes.
- **Tracking** — monospace gets airy at large sizes and cramped at tiny uppercase sizes, so both ends are corrected: `-0.02em` (`tracking-tight`) on heading, display and metric text, `+0.08em` (`tracking-caps`) on uppercase micro-labels (section labels, role labels, table headers).
- **Reading measure** — running prose constrains to `measure` (72ch). Top-level code blocks, tables and other non-prose blocks do **not**: they keep their container's full width and scroll horizontally when they need to. The exemption is top-level only — a code block nested inside a list item or blockquote sits within that prose block's measure and is bounded by it.

Every tier has exactly one backing composite class that binds all four typographic properties together. Apply the class; do not re-derive a tier from separate `font-size` + `font-weight` + `line-height` + `letter-spacing` declarations. Raw `--text-*` tokens remain for one-offs only.

| Token | Class | Size | Usage |
|---|---|---|---|
| `caption` | `.t-caption` | 12px | Timestamps, metadata, hints, micro-labels, field labels (as `.t-caption.tracking-caps` — the eyebrow voice) |
| `body-md` | `.t-body` | 14px | Running copy, code, messages, card bodies |
| `label-md` | `.t-label` | 14px / 500 | Tabs, compact named values |
| `heading-md` | `.t-heading` | 18px / 600, tight tracking | Section titles, card headers, dialog titles |
| `page-title` | `.t-page-title` | 20px / 600 | Topbar and shared page headers |
| `display` | `.t-display` | 24px / 600, tight tracking | The once-per-view display/error-code moment |
| `metric-value` | `.t-metric` | 32px / 600, tight tracking | Metric values from the shared `metricCard` fragment |

Uppercase micro-labels — role labels, pill text, table headers — compose caps tracking on top of `.t-caption` rather than getting their own tier. The composition is a class, not a bare token: apply **`.tracking-caps`** alongside `.t-caption`.

```html
<div class="section-label t-caption tracking-caps">SERVICES</div>
```

This is required, not stylistic. Every tier declares `letter-spacing`, so `.t-caption` alone resets an uppercase label to `normal` — and a component rule of equal specificity declared earlier (`.section-label`, `.msg-role`, `.sidebar-section-label`, `.tool-call-io-label`, `.notif-group`, `.palette-section`) loses its own tracking the moment `.t-caption` is applied beside it. `.tracking-caps` restores it order-independently. Rules that already out-specify the tier (`.data-table th`, `.card-metric .metric-label`) keep their tracking without it.

There is no 13px tier. The size that once sat between `caption` and `body-md` was indistinguishable from the body tier, so it was collapsed into it; `body-md` is the floor for running text and `caption` the floor for metadata.

## Layout

The shell is a **CSS Grid two-column layout**: a 260px sidebar and a flexible main column. The content column constrains to `container-max` (900px) for reading comfort. Spacing follows a strict **4px base unit** (`sp-1` through `sp-12`).

- **Rhythm** — small gaps use `sp-2` (8px); component internal padding uses `sp-3` (12px) or `sp-4` (16px); page padding uses `sp-6` (24px); major section separation uses `sp-8` (32px).
- **Shell** — `.shell` is the app frame, `.sidebar` is the primary nav rail, `.topbar` is the page header, `.content-area` / `.content-inner` is the scrollable body and width-constrained inner column.
- **Migration note** — `.content-area` / `.content-inner` is canonical. The parallel app-only `.page-content` / `.page-inner` family intentionally remains until its last consumer migrates: deferred in-scope tasks, task detail, scheduling, projects, and memory dashboard pages, plus the out-of-scope knowledge UI.
- **Responsive** — below 768px the sidebar becomes an off-canvas drawer (`.sidebar.open` + `.sidebar-scrim`) toggled by `.menu-toggle`. Above 768px the full two-column grid applies.

### Spacing scale

4px base unit. `sp-1` (4px), `sp-2` (8px), `sp-3` (12px), `sp-4` (16px), `sp-5` (20px), `sp-6` (24px), `sp-8` (32px), `sp-10` (40px), `sp-12` (48px).

### Layout primitives

| Token | Value | Usage |
|---|---|---|
| `sidebar-w` | 260px | Sidebar width |
| `topbar-h` | 48px | Top bar height |
| `container-max` | 900px | Default content / message width |
| `container-wide` | 1280px | Opt-in width for data-dense surfaces |
| `measure` | 72ch | Reading measure for running prose inside the 900px tier |

Two container tiers, applied through modifiers: `.content-inner--wide` (canonical) and its app-local mirror, page-inner--wide, both raise the column to `container-wide`.

**Which surfaces take which tier.** Wide: tasks, task detail, health (dashboard + audit), memory, scheduling, the workflow list and workflow detail. The 900px measure stays for chat, session info, knowledge results, settings forms, and projects. The modifier is **opt-in, never the default** — a surface not on the wide list keeps 900px unless the sweep documents a deviation.

`measure` binds running prose only. Top-level code blocks, tables and other non-prose blocks keep the full column width; nested inside a list item or blockquote they are bounded by that prose block's measure.

### Shell scrolling contract

A long page scrolls **inside** the shell; the shell itself is exactly `100dvh` and never grows. That takes three cooperating rules, and removing any one of them lets the content push the sidebar, topbar and ground gradient past the viewport bottom:

| Rule | Owner | Declaration | Why |
|---|---|---|---|
| `.shell` | canon | `grid-template-rows: var(--topbar-h) minmax(0, 1fr)` | A bare `1fr` grid track has an automatic minimum size of its content, so a tall child grows the track rather than overflowing it. `minmax(0, 1fr)` lets the row shrink below its content. |
| `.content-area` | canon | `min-height: 0` | Same automatic-minimum rule one level down, for the scroll container itself. |
| `.page-content` | app | `min-height: 0` | The app-local mirror of `.content-area` (see the migration note above) needs the identical release. |

The scroll container is whichever of `.content-area` / `.page-content` the page uses — both carry `overflow-y: auto`, and both need the `min-height: 0` release to actually clip. `.chat-area` already follows the same pattern.

### Page title and skip link

**The topbar owns the page title, and it is the only `<h1>` on a page.** The shared topbar fragments emit it: `pageTopbar`'s `.session-title-static` and `plainTopbar`'s `.session-title` are `<h1 class="… t-page-title">`. A surface that wants its own heading uses a subtitle or a description head — never a second `<h1>`. `sessionTopbar` is the one exception and emits none: its title is an editable `<input class="session-title">`, and its archive variant is that input's read-only twin, not a page title.

The consequence for page bodies: a surface template must not carry its own in-page `<h1>`. Where it needs a visible heading above the content, that is the `pageHeader` fragment's `<h2 class="t-page-title">`, which matches the topbar tier visually without competing for the document's single top-level heading.

**A page with a parent renders back-navigation before the title.** `pageTopbar`
places the app-owned topbar-back control ahead of the `<h1>`, so it is the first thing reached after
`.menu-toggle` and before the heading — a reader who wants out does not tab
through the page's actions to find the way. The label is destination-specific
("Back to Chat", "Back to Tasks"), never a bare "Back": the control is read out
of context by assistive technology, where "Back" alone names no destination. The
control is optional and belongs only to pages that genuinely sit under another
page; a top-level page renders none.

**The skip link is conditional on the target existing.** The shell layout emits `<a class="skip-link" href="#main-content">Skip to content</a>` as the first element in `<body>`, so it is the first Tab stop; canon's `.skip-link` keeps it visually hidden until `:focus-visible`. It is emitted **only when the body actually supplies `#main-content`** — a skip link pointing at a missing target is worse than none, because it is a focusable control that silently does nothing. Bodies that render no `#main-content` (login, the bare error fallback) opt out. Every `#main-content` element carries `tabindex="-1"` so the jump moves focus rather than only scrolling.

### Native shell readiness

The system carries forward-compatibility tokens for a future webview desktop shell: `--safe-top/-right/-bottom/-left` (from `env(safe-area-inset-*)`) and `--titlebar-drag-h`. In a browser they resolve to `0`; the desktop shell supplies real values so chrome can inset past rounded corners and reserve a drag region. They are defined in canon now but **not yet wired into layout rules** — adoption is deferred to the Afterglow overhaul milestone.

### Body background

The ground is the **aurora** — the afterglow rendered as northern lights, and the page's single largest carrier of atmosphere. It must *read as coloured light at arm's length*, not merely measure as non-flat:

1. **Deep band** – a fixed 3-stop `linear-gradient(170deg, …)` that dives toward `--bg-ground-edge` (below the crust in dark). The deep band is what buys the washes their luminance headroom: cards keep their contrast floor because the ground drops, not because the colour mutes. It **never terminates on the card tone**.
2. **Aurora washes** – four radial gradients centred *inside* the viewport (pushed off-canvas, only their tails landed and the ground read flat). Tokens: `--ambient-a/-b/-c/-d` — **visible alpha washes at 10–16%** (the ui-polish-audit's prescribed strength), cool-led: blue (`a`, top-right), mauve (`b`, centre), teal (`c`, bottom-right), and the green kicker (`d`) in the brand corner. Do not re-architect these into near-ground opaque tints: that is precisely the 0.22.1 regression this section replaces — a mechanism that protected a card-contrast floor by deleting the atmosphere. In light every Latte hue is darker than the ground, so light carries the same geometry as hue-at-matched-lightness tints.
3. **Film grain** — an SVG-turbulence noise overlay (`--noise`, `--noise-opacity`) on a fixed `body::before`, painted above the gradient but below all content. Its job is killing gradient banding on large monitors; it should be felt, not seen.

Corner-to-corner the ground varies by a **target of 0.10–0.15 ΔE(oklab) in dark** (hue-led, ~0.02–0.04 in light) – these are *design targets*, not detection floors. A value that merely clears a just-noticeable-difference floor is a defect here: JND is where flatness stops being measurable, not where atmosphere starts. **No change to this section's tokens or recipe ships on numeric gates alone — a rendered screenshot is reviewed against the Phosphor Aurora reference before it lands.**

The two thresholds differ because the themes have very different room to move. Dark can spend real luminance: the ground runs between the chrome plane below it and the card plane above it. Light is boxed in from both sides – `fg-sub0` helper text needs the *darkest* ground to stay above its 4.5:1 floor, and a semantically tinted white card needs the *lightest* ground to stay 1.15:1 below it, which leaves under 0.005 of oklab L between them. Light therefore carries its variation as **hue at matched lightness** rather than as luminance, and 0.02 is what that yields. Do not "restore" light to 0.04 by widening the luminance band: it lands directly on either the text-contrast floor or the card-contrast floor.

### Mobile sidebar contract

```html
<div class="shell">
  <aside id="app-sidebar" class="sidebar">
    <div class="sidebar-header">
      ...
      <button class="sidebar-close" type="button" aria-label="Close sidebar"></button>
    </div>
  </aside>
  <button class="sidebar-scrim" type="button" aria-label="Close sidebar"></button>

  <header class="topbar">
    <button
      class="btn btn-ghost btn-icon menu-toggle"
      type="button"
      aria-controls="app-sidebar"
      aria-expanded="false">☰</button>
    <div class="session-title-static">Settings</div>
  </header>
</div>
```

**Behaviour.** The markup above is half the contract; a drawer that opens over the
page must also contain focus, or Tab walks straight through the scrim into
content the reader cannot see.

On open:

- Focus moves to `.sidebar-close`.
- The body-first `.skip-link` and the shell's right-column wrapper both become
  `inert`. The wrapper holds the topbar, the restart-banner slot and the main
  content, so a visible restart banner's actions fall inside the inert boundary
  automatically — inert the region, never a hand-maintained list of controls.
  The wrapper is an app-level layout element, not a canon component; what is
  normative here is that *one* region containing all of the page behind the
  scrim is inerted, not the selector naming it.
- `.sidebar-scrim` stays pointer-only. It is never a sequential Tab stop, in
  either state: dismissal by keyboard is Escape and `.sidebar-close`.
- `.menu-toggle` tracks the state through `aria-expanded`.

On close — Escape, a scrim click, or `.sidebar-close` — `inert` is removed from
the same two regions and focus returns to `.menu-toggle`. Escape reaches the
drawer first when one is open; with the drawer closed it keeps its other
meanings. Move focus only on a real open/close transition, so a re-render that
re-asserts the current state does not pull focus to a control nobody touched.

A banner's own dormant or dismissed `inert` state is independent of this and
survives the drawer closing.

### Controller template attributes

Browser behavior is expressed as Stimulus controllers on server-rendered templates. Technical research shared decision #7 standardizes the template attribute vocabulary so design examples, Trellis fragments, and controller code stay aligned.

Use the `dc-*` controller prefix for DartClaw-owned behavior:

```html
<form
  data-controller="dc-chat"
  data-dc-chat-session-id-value="${sessionId}"
  data-action="submit->dc-chat#send">
  <textarea data-dc-chat-target="input"></textarea>
</form>
```

Attribute conventions:

- `data-controller="dc-name"` attaches one or more Stimulus controllers to the element.
- `data-action="event->controller#method"` wires local DOM events to controller methods.
- `data-{controller}-target="name"` marks elements owned by that controller.
- `data-{controller}-{name}-value="..."` passes typed values from Trellis-rendered data into the controller.
- Retired legacy delegated attributes must not be reintroduced; new browser behavior belongs in `dc-*` controllers.

## Elevation & Depth

Depth is conveyed by **the surface ladder + hue-aware shadows**, not by tonal layers alone. Shadows use `rgba(9, 9, 26, ...)` — a blue-violet tint matching Mocha's ~264° hue angle — instead of pure black. This avoids harsh contrast and lets shadows sit naturally against the palette.

| Token | Usage |
|---|---|
| `shadow-sm` | Subtle elevation (default cards). Two layers – a tight key shadow plus a wider ambient one – so a resting card casts a readable band of **≥ 3 pixel rows**, not the single row a one-layer recipe produced |
| `shadow-md` | Medium elevation (hover, dropdowns) |
| `shadow-lg` | Strong elevation (modals, popovers) |
| `inset-sm` | Inset shadow (wells, sunken cards, input fields) |
| `glass-bg` + `glass-blur` | Glass tier — translucent surface + backdrop blur (`.card-glass`, toasts) |

The depth ladder tops out at **glass**: surfaces that float over *live content* (modals, command palettes, toasts) go translucent with backdrop blur instead of opaque-with-bigger-shadow. Glass only reads as glass when content moves behind it — never use it for in-flow cards.

Cards and similar surfaces also carry a 1px **luminous top-edge highlight** (`rgba(255, 255, 255, 0.08)` in dark, `rgba(0, 0, 0, 0.06)` in light). This catches the eye and reinforces that the surface sits on top of, rather than inside, the background. Buttons get the same treatment as an inset highlight, and `btn-primary` adds a subtle top-lit vertical gradient — raised surfaces read as lit from above.

**Micro-lifts** complete the depth story: cards and buttons translate up 1px on hover (recessed surfaces — wells, sunken cards — never lift). The lift is capped at 1–2px and uses only `transform`; anything larger turns polish into bounce.

In light mode, shadows shift to neutral `rgba(0, 0, 0, ...)` — the blue-violet tint is a dark-theme artifact, not a brand element.

### Stacking order

Anything that stacks against the app layers picks a **named tier**, never a fresh literal. The ladder is defined in `tokens.css` and ascends:

| Token | Tier |
|---|---|
| `--z-base` | In-flow content |
| `--z-sticky` | Bars that pin while their own content scrolls (`.tabs--sticky`) |
| `--z-scrim` | The dimmer behind the mobile sidebar |
| `--z-sidebar` | The mobile sidebar drawer itself |
| `--z-dropdown` | Menus and popovers anchored to chrome |
| `--z-overlay` | Skip link, full-screen blockers, non-modal floats |
| `--z-toast` | Top of the ladder — no other tier is above it |

Each row says what *belongs* at that tier, not what currently sits there. Canon consumes the sticky, scrim, sidebar, overlay and toast tiers today; app-side surfaces still carry their own literals until they are migrated onto the ladder, so until then a raw literal can out-rank any tier here.

Component-local micro-stacking — one child painted over its own sibling, like the film grain or a node on its spine — stays a literal. Those stack inside their own component and never compete with the app layers, so giving them a named tier would imply a relationship they do not have.

**The `showModal()` exception.** A `<dialog>` opened with `showModal()` is promoted into the browser **top layer**, which is above every z-index there is — `--z-toast` included. A toast raised while a modal is open still lays out at the top of the ladder, but it paints *beneath* the dialog's `::backdrop` and the modal renders the rest of the document inert, so it arrives dimmed and unclickable — effectively lost. No change to the ladder can fix this: the top layer is not part of the z-index system at all. That is also why `.dialog` carries no tier of its own.

When a modal has to report something, either re-parent the toast container into the open `<dialog>` so it shares the top layer, or report inline with a `.form-error` beside the control that failed. Raising `--z-toast` is not an option — it is precisely the dead end this note exists to stop someone rediscovering as a bug.

## Shapes

The shape language is **tight and engineered**, not soft. Two radius values cover the entire system.

- **`rounded.sm` (4px)** — buttons, inputs, wells, status pills' fallback. Terminal-feel rectangles with just enough softness to avoid feeling brutalist.
- **`rounded.lg` (6px)** — larger containers: cards, demo shells, modal frames.
- **`rounded.full` (9999px)** — status badges and pills only.

Borders are first-class:

- **`border`** — `1px solid var(--bg-surface0)`. Default container border.
- **`border-highlight`** — luminous top-edge (`rgba(255, 255, 255, 0.08)`).
- **`border-active`** — `1px solid var(--accent)`. Focused/selected state.

## Components

DartClaw uses two **container families** — Wells (structural grouping) and Cards (semantic content) — plus a small vocabulary of status indicators, dividers, and interactive atoms. Pick by intent, not visual preference.

### Container decision flowchart

```
Need a container?
│
├─ Just grouping related content visually?
│  ├─ Code/terminal output? ──────────── .well-deep
│  ├─ Message thread / form section? ──── .well-content
│  ├─ Stacked items (own padding)? ────── .well-flush
│  └─ Everything else ────────────────── .well
│
└─ Standalone content unit with meaning?
   ├─ Has a severity/level? ──────────── .card .panel-{color}
   ├─ Is a numeric KPI? ─────────────── .card .card-metric--{color}
   ├─ Needs maximum emphasis? ────────── .card .card-featured-{color}
   ├─ In a categorized list? ─────────── .card .card-tint-{color}
   ├─ Is selected/focused? ──────────── .card .card-active
   ├─ Floating overlay? ─────────────── .card .card-elevated
   ├─ Recessed content pit? ─────────── .card .card-sunken
   └─ General purpose ───────────────── .card
```

### Wells (grouping containers)

Lightweight recessed containers. No card structure, no hover effects, no semantic meaning. **Wells nest freely.**

| Class | Background | Padding | Use for |
|---|---|---|---|
| `.well` | `bg-base` | `sp-3` | Tool indicator groups, form field clusters, sidebar sections |
| `.well-deep` | `bg-crust` | `sp-3` | Code output, terminal regions, nested wells |
| `.well-content` | `bg-base` | `sp-4` | Message thread wrappers, form sections, multi-element groups |
| `.well-flush` | `bg-base` | none | Stacked list items that manage their own padding |

Common nesting patterns:

- `well-content` > `card` > `well` (message thread > agent card > tool output)
- `card` > `well-deep` (card > code block)
- `well-content` > `card` > `well` > `well-deep` (full depth)

**Well vs Card Sunken** — both are recessed, but wells are structural (grouping) while sunken cards are semantic (content with inset treatment). Wells have no hover, no transitions, no glow.

**Terminal frame** (`.terminal-frame`) — a `well-deep` presented as a terminal *window*: title bar (`.terminal-frame-bar`) with traffic-light dots (`.terminal-frame-dots`) and a recessed body (`.terminal-frame-body`). Use where the terminal should read as an object — hero demos, live log views, session replays. Routine inline output stays `.well-deep`; if every code block gets a title bar, none of them pop.

The `--crt` modifier (`.terminal-frame.terminal-frame--crt`) adds scanlines and a corner vignette over the body. Maximum nostalgia, maximum scarcity: hero/landing/empty-state terminals only, one per view.

### Cards (content containers)

Standalone content units with hover effects, optional structure (`card-header`, `card-body`, `card-footer`), and semantic meaning.

| Variant | Background | Hover | Use for |
|---|---|---|---|
| `.card` | `bg-card` + top highlight + prismatic hairline (a centred 1.5px light-catch in `--card-hue`, accent by default; metric/tint variants refract their own hue) | accent glow + border tint, hairline brightens | any standalone content block |
| `.card-sunken` | `bg-crust`, inset shadow | none | code wells, form fields, embeds |
| `.card-elevated` | `bg-surface0`, stronger shadow | large shadow + accent glow | modals, dropdowns, popovers |
| `.card-glass` | translucent + backdrop blur | none (anchored) | overlays above live content: modals, command palettes |
| `.card-active` | persistent accent border + glow | — | selected list item, focused card |
| `.card.panel-{color}` | `bg-card` + 3px left border + gradient bleed | gradient intensifies | severity-bearing content (guards, status, alerts) |
| `.card.card-metric--{color}` | `bg-card` + resting semantic wash, compact KPI layout | wash amplifies | dashboard KPIs |
| `.card.card-tint-{color}` | `bg-card` + resting semantic tint | tint deepens | lists of categorized items |
| `.card.card-featured-{color}` | gradient border, max emphasis | — | primary active tasks, hero cards |

**Colour rests, hover amplifies.** `card-metric--*` and `card-tint-*` carry their semantic hue **at rest** – hover deepens what is already there rather than introducing it. A resting dashboard must read as coloured; a page whose entire chroma budget lives in `:hover` is a grey page for every user who is not currently pointing at something. Both the rest tint (against a plain `.card`) and the hover step (against that variant's own rest) clear 0.02 ΔE(oklab).

**Featured-card border grammar.** The gradient border uses the two-layer `background-clip` idiom, and the fill layer must be an **image**, not a bare colour:

```css
background:
  linear-gradient(var(--bg-card), var(--bg-card)) padding-box,
  linear-gradient(135deg, …) border-box;
```

A bare `<color>` is only valid in the `<final-bg-layer>` of the `background` shorthand, so `var(--bg-card) padding-box, …` makes the **whole declaration** invalid and it is dropped – leaving only `border: 1px solid transparent` and a featured card strictly *less* visible than a plain one. Wrapping the fill in a two-stop `linear-gradient` makes it an image and the declaration parses.

Card sub-elements:

| Class | Use |
|---|---|
| `.card-header` | Title on the `heading-md` tier with `1px` border-bottom. Flex row with gap. |
| `.card-header--sm` | Dense variant of `.card-header` at `body-md` / 600, for list rows and stacked cards. |
| `.card-header-gradient` | Bold title with accent gradient underline. Higher emphasis. |
| `.card-header-actions` | Trailing slot inside `.card-header`; pushes buttons to the right edge. Claims free space only — the title baseline and the header's `border-bottom` are untouched, and a header without the slot renders exactly as before. |
| `.card-body` | Content area. `body-md`, `fg-sub1`. |
| `.card-footer` | Metadata row. `caption`, `fg-sub0`. Flex row with gap. |

### Status indicators

**Status dots** — inline colored circles with optional pulsing animation.

| Class | State | Animation |
|---|---|---|
| `.status-dot--live` | Agent working, no action needed | Expanding ring pulse + core glow (2s) |
| `.status-dot--attention` | Blocked on you | Expanding amber ring pulse (2.8s) |
| `.status-dot--success` | Finished OK | Static glow |
| `.status-dot--error` | Failed | Static glow |
| `.status-dot--warning` | Degraded / pending-external | Static glow |
| `.status-dot--idle` | Idle/inactive | No glow |

**Status vocabulary and the motion rule** — six states, exactly two of them animated. `--live` (green pulse) means *the agent is working*; `--attention` (amber pulse, slower and more patient) means *it is blocked on you*. Motion attracts the eye, so it is rationed to those two readings and nothing else: a pulse in this system always means "working" or "needs you". `--success` (green static) and `--error` (red static) report terminal outcomes; `--warning` (amber static) marks a degraded or pending-external condition; `--idle` (gray) is inactive. Because `--attention` and `--warning` share the amber hue, any attention treatment must also carry a text cue ("waiting") so it reads without motion or color — see § reduced motion and the Do's and Don'ts.

**Status badges** — subtle semantic chip with embedded dot. Low visual weight, slightly tinted background, thin border so they still read in light mode.

`.status-badge-muted` is the **neutral** badge, for disabled / unavailable / not-applicable states — a switched-off channel, a guards-disabled row. It derives its text, tint and border from neutral foreground tokens and carries no success, warning or error hue: borrowing `--warning` would report a degraded system where there is only a switched-off one. It is static, per the motion rule above. Pair it with the existing `.status-dot--idle`; there is no `--muted` dot, and a dot variant must not be inferred from a badge suffix.

**Status pills** — gradient-filled pill. More weight than badges. Use in card footers, table cells, compact status summaries. Variants: `--live` (green→blue), `--error` (red), `--warning` (amber), `--info` (blue).

**Scanning bar** — animated gradient sweep, 2px high. Terminal-native spinner alternative. Not the same as gradient dividers (1px and static).

**Meters** — determinate progress as the **phosphor beam**: a dark recessed 7px channel (`.meter`) + a luminous fill with a two-layer glow (`.meter-fill`, semantic variants `--info`/`--warning`/`--error`). The default runs the claw's green→blue; `--warning` ramps from a deep ember root so it reads with equal authority. Progress *is* the live trace, so meters are deliberately among the brightest resting elements on a page. Budget consumption, turn progress, uploads. Always pair with a visible label or percentage — the color shift alone must not carry the reading. Add `.meter--empty` at 0%: a full-strength track with no fill reads as a solid rule — an emphatic line reporting no data — so the empty case drops the depth and lightens the track until it reads as an unfilled slot.

**Skeletons** — indeterminate loading: shimmer placeholders (`.skeleton`, `.skeleton-text`) shaped like the eventual content. Use for initial page/fragment loads; once content is in flight, the scanning bar takes over.

**Claw loader** — see § Identity. The branded indeterminate indicator for agent "thinking" states; everything else uses scan-bar or skeletons.

### Identicons

`.identicon` + `.identicon--1`…`--6` — deterministic dual-hue gradient avatars for agents, sessions, and channels. Pick the variant as `hash(entityId) % 6 + 1` so the same entity always renders the same colors; content is 1–2 initials. Sized via `font-size` on the element. Identicons are the sanctioned place where the extended palette appears as a fill — they identify *which* entity, never *what state* it's in.

### Buttons

- `.btn` — default (surface bg + border + inset top-edge highlight)
- `.btn-primary` — top-lit accent gradient, high-contrast text, glow on hover
- `.btn-secondary` — info-tinted fill and ring, info-glow lift on hover. The orchestration action (run workflow, open studio): sits deliberately between primary (accent = create) and danger (error = destroy)
- `.btn-ghost` — transparent bg, no fill, no highlight, but a **resting boundary**
- `.btn-danger` — transparent bg, error border, error glow on hover
- `.btn-danger-fill` — filled error bg. The committed destructive step (confirmation dialogs, delete bars); outlined `.btn-danger` stays the default
- `.btn-icon` — square, icon-only
- `.btn-full` — full-width
- States: hover (lighter bg + border highlight + 1px lift), active (darker, settles back down), disabled (0.4 opacity, no lift)

**Size tier.** `.btn-sm` and `.btn-icon-sm` differ from their base by **compact padding and a smaller `min-height` only**. Neither declares a `font-size` — a size modifier that also shrinks the label is how 12px button text spread across dozens of call sites, and the label tier belongs to the type layer (§ Typography), not to a button modifier.

**Ghost buttons keep a resting boundary.** A ghost button with no border at rest reads as prose until it is hovered — unusable without a pointer, and invisible in a screenshot review. The rest-state border holds **≥3:1** (WCAG 1.4.11 non-text minimum) against both planes a ghost button actually sits on, the card and the page ground, in both themes. The mix fraction is pinned by the worst of those four combinations; lowering it drops the light-theme-on-ground case below the minimum.

### Keycaps

`kbd` / `.kbd` — keyboard shortcuts in help text, tooltips, and command hints. Surface chip with a 2px bottom border for keycap depth. Element selector styles bare `<kbd>` in rendered markdown for free.

### Composer & input area

Two roles, split cleanly. **`.input-area`** is the *anchored strip* — the `crust 30% / mantle` gradient with a luminous top border that pins the input to the bottom of the chat surface. **`.composer`** is the *input object* it contains: one card holding the textarea on top and a toolbar row inside it. The bare "textarea + Send button side by side" layout is superseded for chat — a 40px send button bottom-aligned against a growing textarea is exactly the misalignment the object shape removes.

The composer carries the input-family treatment on the *container* – `bg-base`, `inset-sm`, `rounded.lg` – with the textarea bare and transparent inside it. **Focus is terminal-native and quiet, but quiet is bounded**: no rings and no glow, and every persistent focus cue still clears the WCAG 1.4.11 non-text minimum of **3:1**. Three cues compose it: the **caret is terminal green** (`caret-color: accent` – the blinking cursor is the focus signal, exactly as in a terminal), the **send button rests on a dimmed fill and wakes to the full accent gradient** on `:focus-within` (also on hover, keyboard focus, and while streaming – the stop button never sleeps), and the container border takes an accent mix into `surface0` held at ≥ 3:1 against `bg-base` in both themes. A textarea can never carry its own border here (it has no margin against the container), so the container + caret + send do all the work. The textarea grows from `min-height: 40px` to `max-height: 40vh` at `leading-tight`.

> The send button's resting dim lives on the **fill**, never on element-level `opacity`. Opacity composites the glyph and the fill together toward the ground, which collapsed glyph-vs-fill to 1.72:1 in light – an enabled control below the non-text minimum. Dimming the fill and holding the glyph at full strength keeps the same "asleep" reading while staying legible. Genuinely disabled controls are exempt (WCAG 1.4.11) and keep `.btn:disabled { opacity: 0.4 }`.

> The composer caret goes full old-school where the platform allows: `caret-shape: block` renders a true terminal block caret (green, natively blinking); browsers without support fall back to the green bar caret. No JS caret emulation — native or nothing. The streaming message keeps its own block cursor (`.streaming::after`); the two never appear at once (streaming disables the composer).

Anatomy:

```html
<div class="input-area">
  <div class="composer">
    <textarea name="message" placeholder="Message DartClaw..." rows="1"></textarea>
    <div class="composer-toolbar">
      <button type="button" class="btn btn-ghost btn-icon" data-icon="plus" aria-label="Attach"></button>
      <span class="status-badge"><span class="icon icon-shield-alert" aria-hidden="true"></span> guards: standard</span>
      <div class="composer-meta">
        <button type="button" class="composer-model">claude · high</button>
        <button type="button" class="btn btn-primary btn-icon composer-send" data-icon="arrow-up" aria-label="Send"></button>
      </div>
    </div>
  </div>
</div>
<div class="composer-context">
  <span class="chip"><span class="icon icon-folder-kanban" aria-hidden="true"></span> <span class="chip-name">dartclaw-core</span></span>
</div>
```

- `.composer-toolbar` — the inside row: attach/mode on the left, `.composer-meta` (model/effort + send) pushed right with `margin-left: auto`.
- `.composer-model` — a quiet text button (the composer's only chrome) with a trailing chevron; opens the model/effort picker.
- `.composer-send` — a **square** `btn-primary` icon button (the shape language holds — no circular send buttons); streaming swaps its glyph to `square` (stop), an app behavior, not a CSS state.
- `.composer-context` — a chip + metadata row adjacent to the composer (above or below).

Composition rules (no new vocabulary): the permission/guard **mode** is a `.status-badge` (neutral default; `status-badge-warning` for elevated modes — badges carry state, chips never do); **attachments/refs** are chips, placed in a `.chip-row` inside the composer above the toolbar or in `.composer-context`; **streaming** adds `.composer--streaming` (disables the textarea at 0.5 opacity) while the app swaps send→stop.

### Forms

Native elements under canonical classes. Any DartClaw form — settings, task, scheduling, guard editor, pairing — is expressible from this vocabulary alone.

| Class | Use |
|---|---|
| `.form-field` | One label + control + message, stacked. The unit a form is built from. |
| `.form-field--inline` | Label left, control trailing. Toggle rows and other control-follows-label cases. **Compose onto `.form-field`.** |
| `.form-field--checkbox` | Control first, label after, `sp-2` gap. **Compose onto `.form-field`.** |
| `.form-row` | Multi-field horizontal group; fields share the row and stack when they run out of width. |
| `.form-label` | Field label in the **eyebrow voice**: the rule uppercases; markup composes `.t-caption.tracking-caps` for size and tracking. The eyebrow rhythm is what keeps a resting form from reading as a gray stack. Flex row so an icon or badge can sit beside the text. |
| `.form-input` | Text input. Recessed well (a step below `bg-base` toward the crust) + `inset-sm` depth + accent caret. Focus adds the phosphor ring — a soft accent glow on top of the recess; the `:focus-visible` outline stays the guaranteed a11y cue. |
| `.form-select` | Native `<select>` — see § Native selects. |
| `.form-textarea` | Multi-line input; vertical resize only. |
| `.form-error` | Validation message. Floors a filled message at one line; an empty one takes no height. It does not pre-reserve the line, so a layout that must not reflow when an error appears has to reserve the slot itself. |
| `.form-hint` | Helper text below a control. |
| `.form-checkbox` / `.form-radio` | Native inputs, `appearance: none`. Checked = top-lit accent gradient + micro-glow. |
| `.form-toggle` + `.form-toggle-slider` | Switch presentation of a checkbox. CSS-only, state from `:checked`; the on state runs the accent gradient with a micro-glow, the off track is recessed. |

**Control rules are element-qualified** — `input.form-input`, not `.form-input`. The app stylesheet loads after the design system, so a bare class rule loses every shared property to the app's own copy and lands half-applied. Qualification also keeps the family class-bound: an unqualified `input {` here would re-skin every unadopted template at once.

Controls do not inherit the document font, so each control rule sets `font: inherit`. That is a reset, not a type tier — no control rule declares a `font-size`. Compose `.t-caption.tracking-caps` on labels (the eyebrow voice), `.t-label` on tabs, `.t-caption` on hints and errors.

**Invalid state.** `[aria-invalid="true"]` and `:user-invalid` are **equivalent hooks** — both are keyed, so a controller setting the ARIA attribute and the browser's own validity state cannot render differently. The validity pseudo-class is deliberately `:user-invalid` and never the plain one: the plain form also matches an empty `required` field on page load, which would paint an error before the user has typed a character.

Status is never carried by colour alone, so **an invalid control always renders its `.form-error` message** — that message is the non-colour signal, and an invalid boundary without one does not satisfy the accessibility contract. The error boundary also survives `:focus-visible`: a focused invalid field that reads as valid is worse than no state at all.

**Field width scale.** Controls are `width: 100%` by default, which turns a two-character port number into an 866px input. Two modifiers cap them, and cap rather than set, so an unmodified control in the same `.form-row` still fills its column:

| Modifier | Cap | Reach for it when |
|---|---|---|
| `.form-input--num` | `12ch` | The value is a number or short token — port, timeout, count, percentage. |
| `.form-input--short` | `32ch` | The value is short text — host, identifier, key name. |

Anything longer (paths, prompts, URLs) takes the unmodified full-width control. `ch` is exact here because the control family is `--font-mono`.

At `≤768px` the canonical `input.form-input`, `select.form-select` and `textarea.form-textarea` all hold a `16px` floor — below it iOS zooms the viewport on focus. The textarea was held out until the same native case was evidenced on a real control; it since was, so all three text-entry controls now share the floor.

**Touch targets.** At `≤768px` `.form-toggle` takes a `48px` box, matching the floor `.btn` and `.sidebar-nav-item` already hold. The slider stays `36×20` and centres inside it — the switch does not get bigger, its target does. A `36×20` target is 20px tall, under WCAG 2.5.8's 24px minimum, and the box has to *reserve* the space rather than just claim it: enlarging only the (out-of-flow) input would buy the target for free but let stacked toggle rows overlap, so a tap near a row boundary would flip the wrong setting. Expect toggle rows to be taller on mobile; that is the trade.

### Native selects

- Closed select controls visually match the input family: same surface, inset depth, accent focus ring, and a custom DartClaw chevron rather than the browser-default arrow chrome. **Backed by `select.form-select`** — this section describes shipped CSS, not an aspiration.
- Extra right padding and a subtle divider before the chevron so the control reads as an intentional picker.
- The chevron is painted with the `background-image` / `-position` / `-repeat` **longhands**, because `::before`/`::after` do not render on a `<select>` and a `mask-image` on the control would clip the whole element. Painting it as an image means the stroke colour is baked into the URI rather than resolved through `currentColor`, so `--icon-chevron-down-control` is a theme-aware pair in `icons.css` — the one pre-coloured icon token in the system.
- Safari limitation: closed control can be themed, but the opened option popover stays system-native. If branded option menus, search, or grouped content are required, use an accessible custom listbox/combobox instead of over-styling `<select>`.

### Tabs

One tab component: `.tabs` (bar) + `.tab` (item) + `.tabs-actions` (trailing slot), with `.tabs--sticky` for bars that pin.

**The bar scrolls; it never wraps.** Ten settings tabs at 768px is the case that decides it, and a wrapping variant alongside a scrolling one is exactly the divergence this component replaces. `.tab` is `white-space: nowrap`, so a long label never breaks inside a tab.

Active state is keyed on **both** `.active` and `[aria-selected="true"]`, so a server-set class and an ARIA state cannot disagree about which tab is current. The active tab carries an accent underline as well as accent text — never colour alone.

**Overflow contract.** Reachable is not discoverable: a tab sitting off-screen behind an overlay scrollbar means the bar simply reads as fewer tabs. A `.tabs` bar therefore **signals its own overflow** with a right-edge indicator, plus a scrollbar whose thumb is raised to a foreground tone and inline scroll-snapping so a flicked bar lands on a tab boundary. Three things follow from how the indicator is built, and a consumer should count on all three:

- It appears **only on real overflow**. The indicator is driven by a scroll-progress timeline, and a bar with nothing to scroll drives no timeline, so it holds its hidden base state. A four-tab bar shows nothing at any scroll position.
- It **darkens rather than covers**, so it does not have to match the surface behind the bar, and it is pulled out of flow, so the `border-bottom` runs unbroken to the right edge.
- On engines without scroll-driven animations it **degrades to hidden** — the same behaviour as today, never worse. The styled scrollbar is the universally-supported baseline signal.

Do not re-invent a wrapping bar or a `mask-image` edge fade to get the same affordance; the fade masks the element, which takes the `border-bottom` with it.

**Sticky material.** `.tabs--sticky` fills with a tint of the ground token plus a backdrop blur, not a flat opaque slab. The bar pins over the body gradient, whose ambient washes vary across the viewport, so any fixed opaque fill lands as a hard-edged rectangle somewhere — in light theme at scroll-top most visibly.

**Touch targets.** At `≤768px` `.tab` holds a `48px` `min-height`, the same floor `.btn` takes. Padding alone leaves a tab 36px tall — clear of WCAG 2.5.8's minimum, but meaner than every other control on the screen, and a tab bar is primary navigation. `.tab` centres its label with `inline-flex` rather than relying on the line box, because a `<button>` centres its own content and an `<a>` does not; without it the two tab forms would sit differently once the floor raises the box.

### List toolbar and pager

| Class | Use |
|---|---|
| `.list-toolbar` | Search field + actions above a list or table. The field takes the slack, the actions keep their width, and the row stacks rather than crushing the input. |
| `.form-input--search` | The toolbar's search field. Reserves left padding for a leading `.icon-search`, which is a real element because a native `<input>` renders no pseudo-element. |
| `.pager` | Previous / Next around a page indicator. Layout only — the controls are plain `.btn.btn-ghost`. |
| `.pager-label` | The "Page 1 of 5" indicator between them. |

Paging is server-rendered (`hx-get?page=N`); there is no client-side pager state.

**Search input type.** `type="search"` is the canonical markup — it carries the `searchbox` role and the platform's
Escape-to-clear. WebKit and Blink then paint a native `::-webkit-search-cancel-button` inside the field once it holds
text and takes focus: unstyled UA chrome sitting in a branded control. The affordance is reset rather than the element
downgraded to `type="text"`, so the role and Escape behaviour survive. The reset currently lives app-side
(`app.css`, keyed on `input.form-input--search`) because canon was frozen when it was found — it is a hoist candidate
for `components.css`.

### Feedback

| Feedback type | Mechanism | Examples |
|---|---|---|
| Persistent problem | Banner (`.banner-error` / `-warning` / `-info`) | Connection lost, API key missing |
| Transient success / error | Toast (`.toast-success` / `.toast-error`) | Session renamed, failed to delete |
| Modal confirmation | `.dialog.dialog--confirm.card.card-glass` | Delete session, delete project, restart the server |
| Row-scoped destructive | `.delete-confirm-bar` | Deleting one scheduled job from its own row |
| Needs structured input | `.dialog` + width modifier + `.card.card-glass`, hosting real form controls | New task, rename with validation |

**Native `alert()`, `confirm()` and `prompt()` are banned.** They cannot be themed or brand-styled, they block the event loop, and they are threadbare on their own terms — one line of text, OS-chrome buttons, and for `prompt()` a single unvalidated field. Every row above names a class backed by CSS in `components.css`; reach for one of those instead. Same rule, same reason as the § Native selects limitation: where the platform control cannot be made to belong, replace it rather than over-style it.

**Danger is a markup choice, not a second frame.** `.dialog--confirm` serves both destructive and non-destructive confirmations — there is no dialog-danger variant. The severity lives entirely in what the markup puts inside the frame:

| | Destructive (`danger: true`) | Non-destructive (`danger: false`) |
|---|---|---|
| Leading glyph | `.icon.icon-triangle-alert` in `.dialog-body` | none |
| Confirm button | `.btn.btn-danger-fill` | `.btn` |

Both compose the identical `dialog dialog--confirm card card-glass` frame. Keeping one frame is what stops a second modal implementation appearing the first time something needs a confirmation that is not a delete.

**Modal vs in-place.** A destructive action that belongs to one row confirms *in that row* with `.delete-confirm-bar` — a modal would hide the thing being deleted behind the question about deleting it. Reserve `.dialog--confirm` for actions whose object is the whole page or an off-screen entity.

Toasts auto-dismiss after 4s and slide in from the right. They use the glass treatment (translucent + backdrop blur) since they float over live content. Severity is carried by a **leading glyph as well as the edge colour** — `circle-check`, `circle-x`, `triangle-alert`, `info` — so the set stays readable in greyscale and for colour-blind users. The glyph lives on `.toast::before` with `info` as the base, so a variant the CSS does not recognise still renders a shape rather than an empty box.

### Dialogs

One frame shape covers every modal: **`dialog` + its applicable width modifier + `card card-glass`**. The dialog family owns the width contract, the scrim and the three-part split; the card supplies the surface, border and glass material, so a dialog is a card that happens to float. There is no second modal recipe.

| Class | Use |
|---|---|
| `.dialog` | The frame. Bare, it takes the `--md` width, so a frame that forgets its modifier is still bounded rather than sized by its own content. |
| `.dialog--sm` | `min(92vw, 480px)` — confirmations and other single-question modals. |
| `.dialog--md` | `min(92vw, 680px)` — the form-dialog measure. Same as bare `.dialog`. |
| `.dialog--confirm` | Modal confirmation, destructive or not. Takes the `--sm` width and lays its body out as one row, so a leading glyph sits beside the message. Severity comes from the markup — see § Feedback. |
| `.dialog-header` | Title row. Composes `.t-heading` on the title; the rule carries layout and the chrome edge only. |
| `.dialog-body` | The only part that scrolls. |
| `.dialog-footer` | Chrome band holding the actions, tinted a step off the frame. |
| `.dialog-actions` | Right-aligned button row inside the footer. |

**Only the body scrolls.** The header and footer hold their height so the title and the actions stay reachable on a short viewport — that is the entire reason the frame is split in three, and a frame whose own box scrolls has failed. A tab strip between header and body counts as chrome too, and `.dialog .tabs` drops its bottom border so the frame draws one chrome edge rather than two.

**Buttons come from the button family**, never from this one: a confirm dialog composes `.btn.btn-ghost` to cancel and `.btn.btn-danger-fill` to commit. The dialog defines no button of its own.

The frame carries **no `z-index`**. `showModal()` promotes the element into the browser top layer, which already sits above every tier of the ladder — see § Elevation & Depth for what that means for anything raised while a dialog is open.

### Empty and absent states

`.empty-state` is the page- or panel-level "there is nothing here yet" block: centred, muted body copy, one `.btn-primary` action. Its parts:

| Class | Use |
|---|---|
| `.empty-state-title` | The headline, at `--fg` against the muted body copy. A real class rather than an inline colour override on a `<strong>`. |
| `.empty-state .btn` | The action slot — spaced off the copy above it. One primary action; more than one means the state is not actually empty. |
| `.value-absent` | A single missing value inside otherwise-present content — a table cell, a metadata row. |

**Empty state vs absent value.** `.empty-state` answers "this whole list is empty" and gets a title, an explanation and a way forward. `.value-absent` answers "this one field has no value" and gets a dash. Reaching for the block treatment on a single missing cell is how a table turns into a wall of apologies.

**The leading mark comes in two forms, and they are not interchangeable.** The mascot image is the branded shape; a typed glyph (the `❯_` prompt mark) is the lighter one. `.empty-state .icon` styles the typed glyph as *text* — accent colour and a phosphor glow — so a bare `.icon` there opts out of the icon system's mask fill and its 1em box. Add an `.icon-<name>` modifier and it is a real masked icon again, keeping both. This is why a bare `.icon` in an empty state renders a glyph rather than a filled square: the two paths are told apart by the presence of the modifier, not by what the element contains.

`.value-absent` renders the dash as **generated content on an empty element**, so an empty cell still occupies its row and reads as "no value" rather than as a rendering failure. An element that does carry content keeps its own text, muted.

### Messages

- `.msg` — base message with left border accent
- `.msg-user` — green left border + faint accent tint bleeding from the border edge
- `.msg-assistant` — blue left border + faint info tint bleeding from the border edge
- `.msg-role` — uppercase label (`caption`, bold)
- `.msg-content` — markdown-rendered content (headings, lists, code, tables, blockquotes supported)

**The thread bottom-anchors.** `.messages` is a column flex container and its first child takes `margin-top: auto`, so a short conversation sits against the composer instead of stranding the last message most of a viewport above it; the last child drops its bottom margin so the gap is exactly one `sp-4`. Use this idiom, **not** `justify-content: flex-end` – once the thread overflows, `flex-end` pushes content above the scroll origin where it can never be reached.

**Thinking slot** (`.msg-thinking`) — the sanctioned pre-stream composition state, and *the* claw moment of the chat view: an assistant message showing the `.claw-loader` plus a muted "thinking" label with an animated ellipsis (reusing the `.tool-indicator.pending` blink, not a new keyframe). It is replaced entirely by streamed content on the first token, so there is at most one per view — this is where users stare longest, which is exactly why the brand lives here. Under reduced motion it degrades to the static claw-mark + text.

### Tool indicators

- `.tool-indicator` — monospace one-liner with `> ` prefix
- `.pending` — muted + animated `...`
- `.success` — green + checkmark
- `.error` — red + cross

### Tool calls

`.tool-call` is the structured, timeline sibling of `.tool-indicator`: the line stays the transient/inline atom, the card is the durable conversation record. Same monospace voice and `> ` prefix, now with a name, a detail path, a duration, and an expandable result well — built on `<details>`/`<summary>` so disclosure is zero-JS. A leading `::before` `> ` and a trailing chevron (rotating on `[open]`) frame the summary; the body holds `args`/`result` wells (`.tool-call-io-label` + `.well-deep`, capped at 320px and scrollable).

State lives on the 3px left edge and the name glyph, never on a badge:

| Variant | Left edge | Extra |
|---|---|---|
| `--pending` | `bg-surface1` | scan-bar swept along the summary's bottom edge (reuses `.scan-bar`) |
| `--success` | success-tinted | — |
| `--error` | `error` | name colored `error` |
| `--blocked` | `warning` | summary prepends `.icon-shield-alert`; detail carries the guard verdict |

The `--blocked` variant is the glass-box moment — a guard veto rendered as a first-class, legible object rather than a swallowed error. Consecutive calls stack in a `.well-flush` wrapper (`display:grid; gap: var(--sp-1)`); no new class.

### Streaming cursor

`.streaming::after` — blinking block cursor (`▊`) in accent color with phosphor glow.

### Gradient dividers

Static 1px section separators.

| Class | Pattern | Use for |
|---|---|---|
| `.divider.divider-fade` | Accent → transparent (left to right) | Section boundaries |
| `.divider.divider-center` | Transparent → accent → transparent | Content breaks |

**Bare `<hr>` is reset at the element level** – `hr { border: 0; border-top: var(--border); }`. Without it the browser default (`border-style: inset`) renders a beveled 3D groove, including on dividers injected by controllers that no stylesheet selector reaches by class. `.divider` out-specifies a bare element selector regardless of source order, so the gradient dividers above are unaffected.

### Data tables

`.data-table` – full-width, collapsed borders, `body-md`. `th` carries caption typography (uppercase, `tracking-caps`, `fg-sub0`) over a stronger bottom rule, and `white-space: nowrap` so header labels hold one line.

**`thead` is banded.** The band is derived as `color-mix(in oklab, var(--bg-card) 94%, var(--fg))` – a trace of the theme's own ink mixed into the card plane. Mixing toward `--fg` rather than toward a fixed surface token is what makes one declaration work everywhere: `--fg` is the contrasting colour in each theme, so the band always moves *away* from whatever sits behind the body rows, whether the table is on a card or directly on the page ground. The band clears 0.02 ΔE(oklab) against the first body row, and the `th` label stays ≥ 4.5:1 on it.

Without a band a table reads as one undifferentiated block – the header samples identically to the rows. This selector is canon-owned; tables must not re-author a `thead` fill page-side.

### Approval gates

`.approval-card` makes the plan-approval / HITL gate a first-class object rather than a line in the log — governance rendered as UX. It builds on the Card family with a severity treatment while waiting: `--waiting` gets a `warning` left edge and a faint gradient bleed from that edge (the `.panel-warning` recipe), a `.status-dot--attention` in the header, an `.approval-card-plan` well (rendered plan markdown, capped at 400px), and an `.approval-card-actions` footer (Approve / Reject / Comment). **The dot pulses; the card does not** — attention is expressed once, never stacked. On narrow screens (≤768px) the actions stack full-width at ≥48px tall.

Resolved variants drop the pulse and actions for a single `.approval-card-resolution` line (caption, leading icon): `--approved` (success edge, `.icon-check`), `--rejected` (error edge, `.icon-circle-x`), `--expired` (neutral edge, whole card at 0.75 opacity, overlay-toned text).

### Chips

`.chip` is a neutral reference/content token for the composer and metadata rows — like identicons, it answers "what is attached or referenced", **never "did it work"**. That is the whole rule: chips stay neutral-surface with an icon hint and carry no semantic tint (state belongs to badges and pills). They are rectangular (`rounded.sm`) so they read engineered, not pill-like, and cap at 240px with the name ellipsized (`.chip-name`).

- `.chip--ref` — an actionable context reference (interactive `button`/`a`): its icon may take a dim accent hint (`accent-dim`), matching the accent's "active selection" usage; the body text stays neutral. Interactive chips hover to `bg-surface1` and take a focus ring — no lift (chips are too small; lifts are for cards and buttons).
- `.chip-row` — a wrapping flex container for composer attachment rows.
- **Toggle chips (filters)** — a `button.chip` with `aria-pressed="true"` takes an accent tint (14% mix on the fill, 40% on the border). This marks active *selection* — the sanctioned accent family — not outcome state: a pressed "Failed" filter chip is accent-tinted, never error-tinted.

### Notifications

Rows for the attention center; the panel container is `.card-glass` (canon). `.notif-group` is an uppercase section header; `.notif-item` is a three-column grid (dot · body · time) with a status dot from the vocabulary, a bold `.notif-item-title`, an ellipsized `.notif-item-detail`, and a `.notif-item-time`. Rows are ≥44px for touch, hover to `bg-surface0`, and take an accent focus ring. `.notif-item--unread` carries a 2px accent left edge and a `bg-sub-base` tint; read rows keep a transparent 2px edge so titles stay aligned.

### Command palette

Rows inside the glass palette (`.card-glass` container + the canonical input at top are existing canon). `.palette-section` is a section header sharing the `.notif-group` recipe (kept a separate class because the contexts differ). `.palette-item` is a four-column grid (icon · label · context · `kbd`): `.palette-item-label` in `fg`, an ellipsized `.palette-item-context` in overlay, and a trailing keycap. Rows are ≥40px (48px on ≤768px). `.palette-item--active` is the keyboard cursor — `bg-surface0` plus an accent left edge, with the icon brightening to `fg`; hover matches active minus the accent edge.

### Orchestration

Run-board cards and the workflow-detail pipeline — both composition-first.

`.run-card` is a `.card` with documented anatomy (status dot, name, `.run-card-step` counter, a `.tool-indicator`/`.meter` body, and a footer with identicon + `.status-pill`). The only new treatment is `.run-card--attention`: an amber ring (`box-shadow` glow + tinted border) that is the sibling of `.card-active`. As with approval cards, the dot pulses and the card does not.

`.pipeline` is a vertical `<ol>` step list — the workflow-detail spine. Each `.pipeline-step` pairs a `.pipeline-node` with a `.pipeline-step-body` (name + meta), joined by a connector line drawn with `::before`:

| Step state | Node | Connector to next |
|---|---|---|
| `--done` | success fill + glow | success-tinted |
| `--running` | accent ring + `pulse-ring` (green = working) | default |
| `--failed` | error fill + glow | default |
| `--blocked` | warning fill + glow (pair with `.status-dot--attention` in the meta) | default |
| `--pending` | hollow (default) | dashed (not yet reached) |

Color never stands alone: the step name row always carries a status word or a time, and the running step name takes the accent. Expanded steps may embed `.tool-call` stacks or `.well-deep` output (app-level).

### Code highlighting

Syntax coloring is **categorical, like the chart ramp — never state**. The `--syntax-*` token group (tokens.css) themes highlight.js output and server-rendered diffs wherever code appears (`.well-deep`, `.terminal-frame-body`, `.msg-content pre`). Two deliberate choices:

- **Raw Catppuccin hues, not semantic tokens.** The light theme's semantic values are tuned darker for badges and pills; code text on crust wants the true Latte palette — so `--syntax-string` is Latte green, not the darkened `--success`. In dark mode several syntax hues *coincide* with semantic values by palette, not by role.
- **Diffs are the exception.** Added/removed lines (`.diff-line--add`/`--del`, and hljs's `addition`/`deletion`) genuinely carry meaning, so they take a faint `success`/`error` wash (10% mix) with the text pulled 60% toward the semantic hue; hunk headers get an `info` wash. Server-rendered diffs and highlight.js diff grammar share the one treatment.

Mapping: keyword→mauve · string→green · number→peach · comment→overlay · function/title→blue · type→yellow · builtin/attr→teal · operator/punctuation→sub0. Code inside wells renders at `body-md`, matching tool-call cards.

Every code-bearing surface takes the theme — an unhighlighted code block is a drift bug, not a style choice. (Shell *transcripts* are the one exception: prompt lines and program output aren't code and stay plain.)

## Do's and Don'ts

- **Do** reserve the accent color for primary actions, active selection, the streaming cursor, and success. Treat it as scarce.
- **Don't** use the accent decoratively (no green icons, no accent dividers between unrelated sections).
- **Do** pick container variants by intent — Wells for grouping, Cards for semantic content with hover or meaning.
- **Don't** mix Wells and Cards as if they're interchangeable, and don't add hover effects to Wells.
- **Do** use semantic colors (`success`, `error`, `warning`, `info`) only for state. State of *something*, not visual flavor.
- **Don't** use raw Catppuccin palette hex values in `components.css`. Use tokens or derive with `color-mix()` so theme switches stay centralized in `tokens.css`.
- **Do** use the extended palette (`mauve`, `teal`, `sky`, `pink`, `lavender`) for multi-hue gradients, ambient glows, and data-viz categories — that's what it exists for.
- **Don't** let extended-palette hues carry state or fill solid UI surfaces. If a color answers "did it work?", it must be a semantic token.
- **Do** keep micro-interactions tiny: hover lifts of 1–2px, `transform`/`opacity` only, snappy easing. Raised surfaces lift; recessed surfaces (wells, sunken cards) never do.
- **Don't** animate layout properties (size, padding, position) or stack multiple attention effects (lift + pulse + glow sweep) on one element.
- **Do** ration signature elements: one claw moment per view, CRT on hero terminals only, glass only over live content. Scarcity is what makes them land.
- **Don't** turn the claw mark into a bullet point, list marker, or repeated ornament — the moment it's everywhere, DartClaw has no mark.
- **Do** render the mascot and banner with `.pixel-art` and keep them intact — the 8-bit crab is the brand, not raw material.
- **Don't** recolor, redraw, smooth-scale, or shrink the mascot below legibility (~32px).
- **Do** apply `.print-in` consistently to arriving content (cards, messages, swapped fragments) — one entry motion is an identity; five are noise.
- **Don't** hand-pick chart colors — assign `--chart-1`…`--chart-6` by series index so charts look related across views.
- **Do** theme code with the `--syntax-*` tokens only — syntax hues are categorical (chart-ramp family), and diffs' added/removed wash is the sole place code color means anything.
- **Don't** read state into syntax colors or restyle hljs classes ad hoc — a green string is not a success, and a second syntax theme is a second design system.
- **Do** keep monospace throughout. The terminal feel depends on it.
- **Don't** introduce a second typeface "for headings" or "for body". One family, three weights, one shared size scale.
- **Do** keep radius minimal: `rounded.sm` (4px) and `rounded.lg` (6px) cover almost everything; `rounded.full` is for badges/pills only.
- **Don't** mix soft and sharp corners on the same surface or layer different radii within a single component family.
- **Do** reserve pulsing for `--live` and `--attention` only — a pulse always means "working" or "needs you". Every other state is static.
- **Don't** tint chips with semantic colors — chips *reference* things, badges and pills *state* things. If a color would answer "did it work?", it doesn't belong on a chip.
- **Do** pair every attention treatment with a text cue (e.g. "waiting") — amber attention and amber warning share a hue, so it must read under reduced motion and for color-blind users.
- **Don't** put more than one attention-treated object per row or card. The dot pulses; the card doesn't.
- **Do** maintain WCAG AA contrast — representative pairings were tuned for both themes; `fg-overlay` is helper/disabled text only.
- **Don't** rely on color alone for state. Pair dots, icons, or text labels with semantic color so status reads without color cues.
- **Do** use `color-mix(in oklab, ...)` to derive intermediate shades from existing tokens rather than inventing new constants.
- **Don't** paste runtime shadow recipes into components — use the `shadow-sm`/`-md`/`-lg`/`inset-sm` tokens so the blue-violet tint stays consistent.

---

## Icons

**Library** — [Lucide Icons](https://lucide.dev) (ISC license), 24×24 stroke-based SVGs.
**File** — `icons.css`, loaded after `tokens.css`, before or alongside `components.css`.
**Technique** — CSS `mask-image` with inline SVG data URIs. No icon fonts, no external files, no build step. Icons inherit color via `background-color: currentColor`.

### Two usage patterns

`data-icon` attribute — for nav items, buttons, and controls. Icon injected via `::before`, no HTML structure change:

```html
<a class="sidebar-nav-item" data-icon="health">Health</a>
<button class="btn btn-icon" data-icon="menu" aria-label="Menu"></button>
```

`.icon.icon-*` class — for inline icons in content (warnings, status indicators, text-adjacent icons):

```html
<span class="icon icon-triangle-alert" aria-hidden="true"></span> Restart required
<span class="icon icon-check" aria-hidden="true"></span> Connected
```

### Icon vocabulary (semantic → Lucide)

| Semantic | Lucide | CSS property | Context |
|---|---|---|---|
| `health` | `activity` | `--icon-activity` | Health nav |
| `settings` | `settings` | `--icon-settings` | Settings nav |
| `memory` | `brain` | `--icon-brain` | Memory nav |
| `scheduling` | `calendar-clock` | `--icon-calendar-clock` | Scheduling nav |
| `tasks` | `clipboard-list` | `--icon-clipboard-list` | Tasks nav |
| `projects` | `folder-kanban` | `--icon-folder-kanban` | Projects nav |
| `folder-git` | `folder-git` | `--icon-folder-git` | Repository projects |
| `workflows` | `workflow` | `--icon-workflow` | Workflows nav |
| `database` | `database` | `--icon-database` | Knowledge nav |
| `search` | `search` | `--icon-search` | Research nav |
| `clock` | `clock` | `--icon-clock` | Timeline nav |
| `terminal` | `terminal` | `--icon-terminal` | Workspace/Agent |
| `new-session` | `square-pen` | `--icon-square-pen` | New Session button |
| — | `message-circle` | `--icon-message-circle` | Active session |
| — | `archive` | `--icon-archive` | Archived sessions |
| — | `radio-tower` | `--icon-radio-tower` | Channels section |
| — | `at-sign` | `--icon-at-sign` | DMs subsection |
| — | `users` | `--icon-users` | Groups subsection |
| — | `server` | `--icon-server` | System section |
| — | `messages-square` | `--icon-messages-square` | Sessions section |
| `menu` | `menu` | `--icon-menu` | Hamburger toggle |
| `x` | `x` | `--icon-x` | Close/delete/dismiss |
| `info` | `info` | `--icon-info` | Info button |
| — | `triangle-alert` | `--icon-triangle-alert` | Warnings |
| `arrow-left` | `arrow-left` | `--icon-arrow-left` | Back navigation |
| `arrow-right` | `arrow-right` | `--icon-arrow-right` | Forward links |
| `arrow-up` | `arrow-up` | `--icon-arrow-up` | Upward actions |
| `chevron-down` | `chevron-down` | `--icon-chevron-down` | Collapse toggle |
| `chevron-right` | `chevron-right` | `--icon-chevron-right` | Expand toggle |
| — | `chevron-up` | `--icon-chevron-up` | Expand toggle (expanded state) |
| `pencil` | `pencil` | `--icon-pencil` | Edit button |
| `plus` | `plus` | `--icon-plus` | Add actions |
| `square` | `square` | `--icon-square` | Stop button |
| `file-text` | `file-text` | `--icon-file-text` | Artifact/document |
| — | `file-json` | `--icon-file-json` | Structured-output envelope event |
| — | `file-warning` | `--icon-file-warning` | Structured-output fallback / validation failure |
| — | `layers` | `--icon-layers` | Context compaction event |
| `gauge` | `gauge` | `--icon-gauge` | Token meter |
| `wrench` | `wrench` | `--icon-wrench` | Tool invocation |
| `check` | `check` | `--icon-check` | Success/confirm |
| — | `circle-check` | `--icon-circle-check` | Health status OK |
| `circle-x` | `circle-x` | `--icon-circle-x` | Error/fail status |
| — | `shield-alert` | `--icon-shield-alert` | Guard block |
| — | `hash` | `--icon-hash` | Channel indicator |
| — | `sun` | `--icon-sun` | Theme toggle (dark) |
| — | `moon` | `--icon-moon` | Theme toggle (light) |
| `bell` | `bell` | `--icon-bell` | Notification center trigger/section |
| `search` | `search` | `--icon-search` | Command palette, search inputs |
| `paperclip` | `paperclip` | `--icon-paperclip` | Attachment chips, composer |
| — | `git-branch` | `--icon-git-branch` | Session fork/lineage |
| `workflow` | `workflow` | `--icon-workflow` | Workflows nav / run board |
| — | `clock` | `--icon-clock` | Durations, timestamps |
| — | `corner-down-right` | `--icon-corner-down-right` | Forked-from lineage indicator |

### Unicode exceptions

These remain as Unicode characters — text/punctuation, not UI icons:

- `❯` — logo brand identity
- `·`, `•`, `—`, `…`, `&` — text separators/punctuation
- `█` — streaming cursor (text-level with glow animation)
- `> ` — tool indicator prefix (terminal aesthetic)
- `💬`, `📋` — decorative empty-state glyphs

### Guidelines

- Always use `mask-image` (not `background-image`) so icons respond to color changes.
- Include `-webkit-mask-*` prefixes for Safari compatibility.
- Size icons with `em` units so they scale with surrounding text.
- SVG format: `viewBox="0 0 24 24"`, `stroke-width="2"`, `stroke-linecap="round"`, `stroke-linejoin="round"`, `fill="none"`.
- Use `stroke='%23000'` (URL-encoded `#000`) in data URIs for mask source.

### Pre-coloured control chrome

`--icon-chevron-down-control` is the one exception to the mask + `currentColor` rule, and the only icon token whose stroke colour is baked into the URI. It exists because a native `<select>` can carry neither a pseudo-element nor a `mask-image` (the mask would clip the whole control), leaving `background-image` — which paints the SVG exactly as authored. Because the colour cannot be resolved from a token at paint time, `icons.css` declares the value twice: once in `:root` at `--fg-sub0`'s dark value and once under `[data-theme="light"]` at its light value. Keep the pair in step with `--fg-sub0` if that token moves. Use it only for native control chrome; every other icon takes the mask path.

### Adding new icons

1. Find the icon on [lucide.dev](https://lucide.dev).
2. Copy the inner SVG elements (paths, circles, etc.).
3. URL-encode: `<` → `%3C`, `>` → `%3E`, `"` → `'`, `#` → `%23`.
4. Add a `--icon-{name}` custom property to `icons.css` `:root`.
5. Add `.icon-{name}` class and/or `[data-icon="{name}"]::before` selector.

---

## Composition Patterns

### Dashboard layout

```
┌─ grid-4 ──────────────────────────────────┐
│ card-metric  card-metric  card-metric  ... │  ← KPI row
├─ grid-2 ──────────────────────────────────┤
│ card-featured-accent  │  card (activity)   │  ← Hero + feed
├─ grid-2 ──────────────────────────────────┤
│ panel-error           │  panel-warning     │  ← Alerts
└───────────────────────────────────────────┘
```

### Task list

```
card card-tint-accent    ← running task (green hover)
card card-tint-info      ← research task (blue hover)
card card-tint-error     ← failed task (red hover)
card card-tint-warning   ← queued task (amber hover)
```

### Agent detail card

```html
<div class="card card-featured-accent">
  <div class="card-header-gradient">
    <span class="status-dot status-dot--live"></span> Primary Agent
  </div>
  <div class="card-body">
    <div class="well" style="display:flex; flex-direction:column; gap:4px">
      <div class="tool-indicator success">Reading handler.ts</div>
      <div class="tool-indicator pending">Writing jwt.ts</div>
    </div>
    <div class="scan-bar" style="margin-top:8px"></div>
  </div>
  <div class="card-footer">
    <span class="status-pill status-pill--live">Turn 4/10</span>
  </div>
</div>
```

---

## Theming

Toggle via `data-theme="light"` attribute on `<html>`:

```js
const root = document.documentElement;
const nextTheme = root.dataset.theme === 'light' ? 'dark' : 'light';

if (nextTheme === 'light') {
  root.dataset.theme = 'light';
} else {
  root.removeAttribute('data-theme');
}

localStorage.setItem('dartclaw-theme', nextTheme);

const savedTheme = localStorage.getItem('dartclaw-theme');
if (savedTheme === 'light') {
  root.dataset.theme = 'light';
}
```

Server-side: read theme from cookie, set `data-theme` in HTML template.

---

## Accessibility

- All interactive elements expose a visible focus treatment; the system uses accent outlines or accent glow rings. Every **persistent** focus cue – including the composer's container border, which is deliberately ring-less – clears the WCAG 1.4.11 non-text minimum of 3:1 against the surface behind it, in both themes.
- Non-text contrast also binds **enabled** controls that render in a dimmed rest state: dim the fill, never the whole element, so the glyph stays at full strength. Genuinely disabled controls are exempt.
- Representative pairings were tuned to pass WCAG AA in both themes: primary text, card/footer metadata, active nav text, `btn-primary`, status badges, and status pills.
- `fg-overlay` is intentionally low-emphasis; use it for placeholders/disabled/helper text, never for essential metadata or table labels. It is **guaranteed ≥ 4.5:1 against exactly three surfaces in both themes – the card plane (`bg-card`), the page-ground plane (`bg-base`) and `bg-crust`.** Those three are the contract; a fourth surface is not covered and must be measured before `fg-overlay` is used on it.
- The sidebar rail carries **three distinct text tiers** – section labels (`fg-sub0`), nav items (`fg-sub1`), session titles (`fg`) – pairwise ≥ 0.02 ΔE(oklab) apart and each ≥ 4.5:1 against the chrome plane. It is chrome on 100% of views; one flat colour there is a system-wide legibility defect, not a page-level one.
- `.sr-only` utility for screen-reader-only text.
- One `<h1>` per page, emitted by the topbar, and a skip link only where `#main-content` exists — see § Layout → Page title and skip link.
- All icon-only buttons must have `aria-label`. Theme toggle and menu toggle need descriptive labels.
- Use semantic controls (`button`, `a`, `input`) for session rows, nav items, dismiss buttons, and drawer controls.
- `@media (prefers-reduced-motion: reduce)` disables all animations and transitions.
