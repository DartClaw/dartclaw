---
version: alpha
name: DartClaw
description: "Afterglow — DartClaw's terminal-aesthetic design language. Catppuccin Mocha (dark) / Latte (light) palette, monospace typography, terminal-green accent, phosphor glows, 8-bit crab-mascot brand (assets/logo-*-8bit.png) with a pixel claw-mark signature."
colors:
  # Surface ladder — dark theme (default). 7 levels darkest → brightest.
  # bg-pit and bg-sub-base are derived at runtime via color-mix(); approximate hex below.
  bg-pit: "#0c0c13"
  bg-crust: "#11111b"
  bg-mantle: "#181825"
  bg-base: "#1e1e2e"
  bg-sub-base: "#27283b"
  bg-surface0: "#313244"
  bg-surface1: "#45475a"
  bg-surface2: "#585b70"
  # Foreground
  fg: "#cdd6f4"
  fg-sub1: "#bac2de"
  fg-sub0: "#a6adc8"
  fg-overlay: "#7f849c"
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
  # Light-theme overrides (Catppuccin Latte). Semantic values are tuned darker
  # than raw Latte so badges/pills stay readable on light surfaces.
  bg-pit-light: "#e6e9f0"
  bg-crust-light: "#dce0e8"
  bg-mantle-light: "#e6e9ef"
  bg-base-light: "#eff1f5"
  bg-sub-base-light: "#dde0e7"
  bg-surface0-light: "#ccd0da"
  bg-surface1-light: "#bcc0cc"
  bg-surface2-light: "#acb0be"
  fg-light: "#4c4f69"
  fg-sub1-light: "#5c5f77"
  fg-sub0-light: "#62677d"
  fg-overlay-light: "#7b8094"
  accent-light: "#24661c"
  accent-dim-light: "#3d7d36"
  success-light: "#24661c"
  error-light: "#a40a2b"
  warning-light: "#933d00"
  info-light: "#0f4ebf"
  mauve-light: "#8839ef"
  teal-light: "#179299"
  sky-light: "#04a5e5"
  pink-light: "#ea76cb"
  lavender-light: "#7287fd"
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
    fontSize: 16px
    fontWeight: 600
    lineHeight: 1.3
  body-md:
    fontFamily: JetBrains Mono
    fontSize: 14px
    fontWeight: 400
    lineHeight: 1.6
  body-sm:
    fontFamily: JetBrains Mono
    fontSize: 13px
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
  card:
    backgroundColor: "{colors.bg-mantle}"
    textColor: "{colors.fg}"
    typography: "{typography.body-sm}"
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
    backgroundColor: "{colors.bg-mantle}"
    textColor: "{colors.fg}"
    rounded: "{rounded.lg}"
    padding: "{spacing.sp-4}"
  panel-info:
    backgroundColor: "{colors.bg-mantle}"
    textColor: "{colors.fg}"
    rounded: "{rounded.lg}"
    padding: "{spacing.sp-4}"
  panel-error:
    backgroundColor: "{colors.bg-mantle}"
    textColor: "{colors.fg}"
    rounded: "{rounded.lg}"
    padding: "{spacing.sp-4}"
  panel-warning:
    backgroundColor: "{colors.bg-mantle}"
    textColor: "{colors.fg}"
    rounded: "{rounded.lg}"
    padding: "{spacing.sp-4}"
  input:
    backgroundColor: "{colors.bg-base}"
    textColor: "{colors.fg}"
    typography: "{typography.body-md}"
    rounded: "{rounded.lg}"
    padding: "{spacing.sp-3}"
  status-badge:
    backgroundColor: "{colors.bg-surface0}"
    textColor: "{colors.fg}"
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
    backgroundColor: "{colors.bg-mantle}"  # at 72% alpha + 14px backdrop blur
    textColor: "{colors.fg}"
    rounded: "{rounded.lg}"
    padding: "{spacing.sp-4}"
  identicon:
    backgroundColor: "{colors.mauve}"  # dual-hue gradient, variant by entity-id hash
    textColor: "{colors.bg-crust}"
    typography: "{typography.caption}"
    rounded: "{rounded.sm}"
---

# DartClaw Design System — "Afterglow"

Terminal-aesthetic design language for a developer-focused AI agent runtime. Catppuccin Mocha/Latte palette, monospace typography, terminal-green accent, phosphor glows, claw-scratch signature.

**Companion files** (same directory):

- `tokens.css` — CSS custom properties for runtime use
- `components.css` — component class rules
- `icons.css` — Lucide icon set as CSS mask-image data URIs
- `showcase.html` — interactive component reference
- `assets/` — local copies of the brand logos so the folder is self-contained (canonical originals: repo-root `assets/`)

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

- **Surfaces** form a 7-level ladder from `bg-pit` (deepest inset) to `bg-surface2` (border-level). Use `color-mix(in oklab, ...)` to derive intermediate values rather than introducing new hex constants.
- **Foreground** has four steps from `fg` (primary text) to `fg-overlay` (placeholders/disabled). `fg-overlay` is intentionally low-emphasis — never use it for essential metadata.
- **Accent** is terminal-green (`#a6e3a1` Mocha, `#24661c` Latte). It is the only "branding" color. Reserve it for primary actions, the streaming cursor, active selection, and the success state.
- **Semantic** colors are reserved for state: `success` (green), `error` (pink/red), `warning` (orange), `info` (blue). Light-theme semantics are intentionally darker than raw Latte swatches so pills, badges, and active states remain readable on light surfaces.
- **Extended palette** — `mauve`, `teal`, `sky`, `pink`, `lavender` exist so the system isn't monochrome-plus-green. They are **decorative/categorical only**: multi-hue gradients (logo, featured cards, `.text-gradient`), the ambient body glows, identicons, and data-viz category colors. They never carry state — a user must never have to ask whether purple means failure.
- **Chart ramp** — `--chart-1` through `--chart-6` is the *ordered* categorical ramp (accent, info, mauve, teal, pink, sky). Assign by series index, never by hand-picking — the order keeps adjacent series distinguishable and charts consistent across views.

### Surface ladder (7 levels)

| Token | Dark | Light | Usage |
|---|---|---|---|
| `bg-pit` | `color-mix(#11111b, #000)` | `color-mix(#dce0e8, #fff)` | Deepest inset (below crust) |
| `bg-crust` | `#11111b` | `#dce0e8` | Code blocks, deep wells, input bg |
| `bg-mantle` | `#181825` | `#e6e9ef` | Cards, sidebar, topbar |
| `bg-base` | `#1e1e2e` | `#eff1f5` | Page background, standard wells |
| `bg-sub-base` | `color-mix(#1e1e2e, #313244)` | `color-mix(#eff1f5, #ccd0da)` | Between base and surface0 |
| `bg-surface0` | `#313244` | `#ccd0da` | Elevated cards, hover states |
| `bg-surface1` | `#45475a` | `#bcc0cc` | Active states, stronger hover |
| `bg-surface2` | `#585b70` | `#acb0be` | Borders, scrollbar thumb |

## Typography

The entire system is set in **JetBrains Mono** (with `Fira Code` and system monospace as fallbacks). Monospace throughout is deliberate: it reinforces the terminal aesthetic, gives consistent column alignment in dense tables and tool indicators, and reduces font loading to a single family.

- **Base size** — 14px (`body-md`). Larger sizes are reserved for page title (20px), display moments (24px), and metric values (32px). Smaller sizes carry metadata and pill text (12–13px).
- **Weights** — three only: `400` (normal body), `500` (medium — session titles, UI labels), `600` (bold — headings, role labels).
- **Line height** — `1.6` for body and code; `1.3` for headings and tight UI like the input textarea; tighter still (≤1.2) at display sizes.
- **Tracking** — monospace gets airy at large sizes and cramped at tiny uppercase sizes, so both ends are corrected: `-0.02em` (`tracking-tight`) on display/metric text, `+0.08em` (`tracking-caps`) on uppercase micro-labels (section labels, role labels, table headers).

| Token | Size | Usage |
|---|---|---|
| `caption` | 12px | Timestamps, metadata, role labels, pill text |
| `body-sm` | 13px | Sidebar items, secondary text, banners, card body |
| `body-md` | 14px | Body text, code, messages |
| `label-md` | 14px / 500 | UI labels, session titles |
| `heading-md` | 16px / 600 | Section headings |
| `page-title` | 20px / 600 | App name, page title |
| `display` | 24px / 600, tight tracking | Hero/empty-state moments, gradient text |
| `metric-value` | 32px / 600, tight tracking | Dashboard KPI numbers |

## Layout

The shell is a **CSS Grid two-column layout**: a 260px sidebar and a flexible main column. The content column constrains to `container-max` (900px) for reading comfort. Spacing follows a strict **4px base unit** (`sp-1` through `sp-12`).

- **Rhythm** — small gaps use `sp-2` (8px); component internal padding uses `sp-3` (12px) or `sp-4` (16px); page padding uses `sp-6` (24px); major section separation uses `sp-8` (32px).
- **Shell** — `.shell` is the app frame, `.sidebar` is the primary nav rail, `.topbar` is the page header, `.content-area` / `.content-inner` is the scrollable body and width-constrained inner column.
- **Responsive** — below 768px the sidebar becomes an off-canvas drawer (`.sidebar.open` + `.sidebar-scrim`) toggled by `.menu-toggle`. Above 768px the full two-column grid applies.

### Spacing scale

4px base unit. `sp-1` (4px), `sp-2` (8px), `sp-3` (12px), `sp-4` (16px), `sp-5` (20px), `sp-6` (24px), `sp-8` (32px), `sp-10` (40px), `sp-12` (48px).

### Layout primitives

| Token | Value | Usage |
|---|---|---|
| `sidebar-w` | 260px | Sidebar width |
| `topbar-h` | 48px | Top bar height |
| `container-max` | 900px | Max content / message width |

### Body background

The ground is atmospheric, not flat:

1. **Base gradient** — fixed 3-stop `linear-gradient(170deg, crust → base → mantle)`.
2. **Ambient glows** — three faint radial gradients bleeding in from off-screen (accent top-left, mauve top-right, info bottom), each ≤7% mix so they tint without competing with semantic color. Tokens: `--ambient-a/-b/-c`.
3. **Film grain** — an SVG-turbulence noise overlay (`--noise`, `--noise-opacity`) on a fixed `body::before`, painted above the gradient but below all content. Its job is killing gradient banding on large monitors; it should be felt, not seen.

### Mobile sidebar contract

```html
<div class="shell">
  <aside id="app-sidebar" class="sidebar">...</aside>
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
| `shadow-sm` | Subtle elevation (default cards) |
| `shadow-md` | Medium elevation (hover, dropdowns) |
| `shadow-lg` | Strong elevation (modals, popovers) |
| `inset-sm` | Inset shadow (wells, sunken cards, input fields) |
| `glass-bg` + `glass-blur` | Glass tier — translucent surface + backdrop blur (`.card-glass`, toasts) |

The depth ladder tops out at **glass**: surfaces that float over *live content* (modals, command palettes, toasts) go translucent with backdrop blur instead of opaque-with-bigger-shadow. Glass only reads as glass when content moves behind it — never use it for in-flow cards.

Cards and similar surfaces also carry a 1px **luminous top-edge highlight** (`rgba(255, 255, 255, 0.08)` in dark, `rgba(0, 0, 0, 0.06)` in light). This catches the eye and reinforces that the surface sits on top of, rather than inside, the background. Buttons get the same treatment as an inset highlight, and `btn-primary` adds a subtle top-lit vertical gradient — raised surfaces read as lit from above.

**Micro-lifts** complete the depth story: cards and buttons translate up 1px on hover (recessed surfaces — wells, sunken cards — never lift). The lift is capped at 1–2px and uses only `transform`; anything larger turns polish into bounce.

In light mode, shadows shift to neutral `rgba(0, 0, 0, ...)` — the blue-violet tint is a dark-theme artifact, not a brand element.

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
| `.card` | `bg-mantle` + top highlight | accent glow + border tint | any standalone content block |
| `.card-sunken` | `bg-crust`, inset shadow | none | code wells, form fields, embeds |
| `.card-elevated` | `bg-surface0`, stronger shadow | large shadow + accent glow | modals, dropdowns, popovers |
| `.card-glass` | translucent + backdrop blur | none (anchored) | overlays above live content: modals, command palettes |
| `.card-active` | persistent accent border + glow | — | selected list item, focused card |
| `.card.panel-{color}` | mantle + 3px left border + gradient bleed | gradient intensifies | severity-bearing content (guards, status, alerts) |
| `.card.card-metric--{color}` | mantle, compact KPI layout | radial glow from center | dashboard KPIs |
| `.card.card-tint-{color}` | mantle, hover-only color shift | bg shifts toward semantic color | lists of categorized items |
| `.card.card-featured-{color}` | gradient border, max emphasis | — | primary active tasks, hero cards |

Card sub-elements:

| Class | Use |
|---|---|
| `.card-header` | Bold title with `1px` border-bottom. Flex row with gap. |
| `.card-header-gradient` | Bold title with accent gradient underline. Higher emphasis. |
| `.card-body` | Content area. `body-sm`, `fg-sub1`. |
| `.card-footer` | Metadata row. `caption`, `fg-sub0`. Flex row with gap. |

### Status indicators

**Status dots** — inline colored circles with optional pulsing animation.

| Class | State | Animation |
|---|---|---|
| `.status-dot--live` | Running/active | Expanding ring pulse + core glow |
| `.status-dot--error` | Failed | Static glow |
| `.status-dot--warning` | Pending/warning | Static glow |
| `.status-dot--idle` | Idle/inactive | No glow |

**Status badges** — subtle semantic chip with embedded dot. Low visual weight, slightly tinted background, thin border so they still read in light mode.

**Status pills** — gradient-filled pill. More weight than badges. Use in card footers, table cells, compact status summaries. Variants: `--live` (green→blue), `--error` (red), `--warning` (amber), `--info` (blue).

**Scanning bar** — animated gradient sweep, 2px high. Terminal-native spinner alternative. Not the same as gradient dividers (1px and static).

**Meters** — determinate progress: recessed 6px track (`.meter`) + gradient fill (`.meter-fill`, semantic variants `--info`/`--warning`/`--error`) with a soft matching glow. Budget consumption, turn progress, uploads. Always pair with a visible label or percentage — the color shift alone must not carry the reading.

**Skeletons** — indeterminate loading: shimmer placeholders (`.skeleton`, `.skeleton-text`) shaped like the eventual content. Use for initial page/fragment loads; once content is in flight, the scanning bar takes over.

**Claw loader** — see § Identity. The branded indeterminate indicator for agent "thinking" states; everything else uses scan-bar or skeletons.

### Identicons

`.identicon` + `.identicon--1`…`--6` — deterministic dual-hue gradient avatars for agents, sessions, and channels. Pick the variant as `hash(entityId) % 6 + 1` so the same entity always renders the same colors; content is 1–2 initials. Sized via `font-size` on the element. Identicons are the sanctioned place where the extended palette appears as a fill — they identify *which* entity, never *what state* it's in.

### Buttons

- `.btn` — default (surface bg + border + inset top-edge highlight)
- `.btn-primary` — top-lit accent gradient, high-contrast text, glow on hover
- `.btn-ghost` — transparent bg, no border, no highlight
- `.btn-danger` — transparent bg, error border, error glow on hover
- `.btn-icon` — square, icon-only
- `.btn-full` — full-width
- States: hover (lighter bg + border highlight + 1px lift), active (darker, settles back down), disabled (0.4 opacity, no lift)

### Keycaps

`kbd` / `.kbd` — keyboard shortcuts in help text, tooltips, and command hints. Surface chip with a 2px bottom border for keycap depth. Element selector styles bare `<kbd>` in rendered markdown for free.

### Input area

- Textarea + send button, anchored to bottom of the chat surface.
- Background: subtle `crust 30% / mantle` gradient, luminous top border.
- Textarea: `bg-base` background, `inset-sm` shadow, `rounded.lg` corners, symmetric `sp-3` padding.
- Line height: 1.3 — keeps text vertically centered within `min-height: 40px`.
- Focus state: accent border + glow ring (`inset-sm` + `1px accent` + `8px` ambient glow).
- Disabled state: 0.5 opacity during streaming.

### Native selects

- Closed select controls visually match the input family: same surface, inset depth, accent focus ring, and a custom DartClaw chevron rather than the browser-default arrow chrome.
- Extra right padding and a subtle divider before the chevron so the control reads as an intentional picker.
- Safari limitation: closed control can be themed, but the opened option popover stays system-native. If branded option menus, search, or grouped content are required, use an accessible custom listbox/combobox instead of over-styling `<select>`.

### Banners and toasts

| Feedback type | Mechanism | Examples |
|---|---|---|
| Persistent problem | Banner (`.banner-error/-warning/-info`) | Connection lost, API key missing |
| Transient success | Toast (`.toast-success`) | Session renamed, copied to clipboard |
| Transient error | Toast (`.toast-error`) | Failed to rename, failed to delete |
| Destructive confirmation | `confirm()` dialog | Delete session |

Toasts auto-dismiss after 4s, slide in from the right. They use the glass treatment (translucent + backdrop blur) since they float over live content.

### Messages

- `.msg` — base message with left border accent
- `.msg-user` — green left border + faint accent tint bleeding from the border edge
- `.msg-assistant` — blue left border + faint info tint bleeding from the border edge
- `.msg-role` — uppercase label (`caption`, bold)
- `.msg-content` — markdown-rendered content (headings, lists, code, tables, blockquotes supported)

### Tool indicators

- `.tool-indicator` — monospace one-liner with `> ` prefix
- `.pending` — muted + animated `...`
- `.success` — green + checkmark
- `.error` — red + cross

### Streaming cursor

`.streaming::after` — blinking block cursor (`▊`) in accent color with phosphor glow.

### Gradient dividers

Static 1px section separators.

| Class | Pattern | Use for |
|---|---|---|
| `.divider.divider-fade` | Accent → transparent (left to right) | Section boundaries |
| `.divider.divider-center` | Transparent → accent → transparent | Content breaks |

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
- **Do** keep monospace throughout. The terminal feel depends on it.
- **Don't** introduce a second typeface "for headings" or "for body". One family, three weights, one shared size scale.
- **Do** keep radius minimal: `rounded.sm` (4px) and `rounded.lg` (6px) cover almost everything; `rounded.full` is for badges/pills only.
- **Don't** mix soft and sharp corners on the same surface or layer different radii within a single component family.
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
| `chevron-down` | `chevron-down` | `--icon-chevron-down` | Collapse toggle |
| `chevron-right` | `chevron-right` | `--icon-chevron-right` | Expand toggle |
| `pencil` | `pencil` | `--icon-pencil` | Edit button |
| `square` | `square` | `--icon-square` | Stop button |
| — | `check` | `--icon-check` | Success/confirm |
| — | `circle-check` | `--icon-circle-check` | Health status OK |
| — | `circle-x` | `--icon-circle-x` | Error/fail status |
| — | `shield-alert` | `--icon-shield-alert` | Guard block |
| — | `hash` | `--icon-hash` | Channel indicator |
| — | `sun` | `--icon-sun` | Theme toggle (dark) |
| — | `moon` | `--icon-moon` | Theme toggle (light) |

### Unicode exceptions

These remain as Unicode characters — text/punctuation, not UI icons:

- `❯` — logo brand identity
- `·`, `•`, `—`, `…`, `&` — text separators/punctuation
- `█` — streaming cursor (text-level with glow animation)
- `> ` — tool indicator prefix (terminal aesthetic)
- `💬`, `📋`, `☐` — decorative empty-state glyphs

### Guidelines

- Always use `mask-image` (not `background-image`) so icons respond to color changes.
- Include `-webkit-mask-*` prefixes for Safari compatibility.
- Size icons with `em` units so they scale with surrounding text.
- SVG format: `viewBox="0 0 24 24"`, `stroke-width="2"`, `stroke-linecap="round"`, `stroke-linejoin="round"`, `fill="none"`.
- Use `stroke='%23000'` (URL-encoded `#000`) in data URIs for mask source.

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

- All interactive elements expose a visible focus treatment; the system uses accent outlines or accent glow rings.
- Representative pairings were tuned to pass WCAG AA in both themes: primary text, card/footer metadata, active nav text, `btn-primary`, status badges, and status pills.
- `fg-overlay` is intentionally low-emphasis; use it for placeholders/disabled/helper text, never for essential metadata or table labels.
- `.sr-only` utility for screen-reader-only text.
- All icon-only buttons must have `aria-label`. Theme toggle and menu toggle need descriptive labels.
- Use semantic controls (`button`, `a`, `input`) for session rows, nav items, dismiss buttons, and drawer controls.
- `@media (prefers-reduced-motion: reduce)` disables all animations and transitions.
