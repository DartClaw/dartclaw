# Architecture Diagrams

Hand-written SVG figures embedded in the architecture documents one directory up. The `.svg` file is the source of
truth: edit it as text, with no drawing tool or export step. Recipe figures for the user guide follow the same rules
and live in `docs/guide/recipes/diagrams/`.

## Files

- Name: `<doc>-<figure>.svg`, where `<doc>` is `system`, `protocol`, `security`, `data`, `channels`, `sessions`,
  `tasks`, `workflow`, `config`, `cli-api`, `observability`, `context-map`, or `governance`.
- One idea per figure, about 15 nodes at most. Split a crowded figure in two rather than shrinking text.
- Embed with a link to the file, so a click opens the interactive SVG:
  `[![System architecture overview](diagrams/system-overview.svg)](diagrams/system-overview.svg)`.
- The prose next to a figure says what the figure cannot: invariants, failure modes, the why. No footnote paragraphs
  inside the figure; a legend explains the notation.

## Visual language

Reference figures: `system-overview.svg` (C4 component view), `tasks-lifecycle.svg` (state machine),
`security-guard-chain.svg` (pipeline). Copy the `<style>` and `<defs>` blocks from `system-overview.svg`, minus its
per-node highlight lines.

- **Header**: a small-caps kicker naming the figure type (`C4 · LEVEL 3 · …`, `STATE MACHINE · …`, `PIPELINE · …`,
  `SEQUENCE · …`), a 21px title, and a one-sentence lede with the figure's point.
- **Colour means kind**, set by a class on the node group: `k-host` (DartClaw code, green), `k-ext` (external process
  or binary, orange), `k-store` (persistent store, teal), `k-sec` (security boundary, guard or failure, red),
  `k-chan` (channel, person or outside service, mauve), `k-neu` (neutral or inactive, grey).
- **Weight means importance**: `solid` for the one or two nodes the figure is about, `tint` by default, `line` for
  secondary nodes, `ghost` (dashed) for optional, reserved or dev-only nodes.
- **Bands** (`.band`, `.band.inner`) draw boundaries: a process, a container, a layer, a phase. Each carries a kicker
  label (`DART HOST PROCESS · dartclaw serve`).
- **Badges** (top right, caps) carry a protocol or fact (`JSONL`, `CRON`). **Chips** (small pills) carry secondary
  edges that would cross the drawing, such as `→ failed`. **Step circles** number a pipeline or sequence.
- **Edges** say what flows on them, in an edge label: `main` (green, the main path), plain (grey, a call or write),
  `bad` (red, failure or deny), `dash` (async, optional or mediated), `join` (no arrowhead, merging lines). End an
  edge on a box edge; no edge crosses a box, a label, or another edge.
- **Text**: 14.5px bold names (13.5px monospace for code identifiers), 11.5px body, 11px edge labels. Names from code
  are spelled exactly as in code.

## Interaction

Opened directly in a browser, a figure is interactive; GitHub and IDE previews render it through `<img>`, which
disables interaction, so the static render must carry everything a reader needs.

- Each node is `<a href="../doc.md#section"><g class="n tint k-host" id="X">…</g></a>`.
- Edges live in one `<g class="edges">` layer under the nodes, each `<g class="e main f-A t-B">` naming its source and
  target ids. One CSS line per node id highlights its connections and dims the rest:
  `svg:has(#X:hover) .edges :is(.f-X,.t-X) { opacity: 1; --ec: var(--hi); --ew: 2.6px; --em: url(#ah-hi); }`.
- Figures with about eight nodes or more get a dark details panel at the bottom, painted before the nodes. Each node
  holds a hidden `<g class="d">` with two lines of detail (responsibility, file or key invariant), shown on hover or
  keyboard focus. Smaller figures use a `<title>` tooltip per node instead.

## Rules

- **Root element**: `viewBox="0 0 W H" width="W" height="H"` with W at most 1000, plus `role="img"`, `<title>` and a
  `<desc>` that states the figure's point in one or two sentences.
- **Self-contained.** No scripts, web fonts, `<foreignObject>`, or external references.
- **Theme.** Catppuccin Latte by default, Mocha under `prefers-color-scheme: dark`, matching
  `dev/design-system/tokens.css`. Paint a full-size `.bg` rect first. Use the CSS variables, never literal colours in
  elements.

## Check before committing

Render both themes and look at them; fix clipped or overlapping text, edges through boxes, and unreadable arrows.
Then open the SVG in a browser and hover a few nodes.

```bash
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
xmllint --noout fig.svg
"$CHROME" --headless=new --hide-scrollbars --window-size=W,H --screenshot=light.png "file://$PWD/fig.svg"
"$CHROME" --headless=new --hide-scrollbars --force-dark-mode --window-size=W,H --screenshot=dark.png "file://$PWD/fig.svg"
```
