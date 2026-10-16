# Architecture Diagrams

Hand-written SVG figures embedded in the architecture documents one directory up. The `.svg` file is the source of
truth: edit it as text, with no drawing tool or export step. Recipe figures for the user guide follow the same rules
and live in `docs/guide/recipes/diagrams/`.

## Files

- Name: `<doc>-<figure>.svg`, where `<doc>` is `system`, `protocol`, `security`, `data`, `channels`, `sessions`,
  `tasks`, `workflow`, `config`, `cli-api`, `observability`, `context-map`, or `governance`.
- One idea per figure, about 15 nodes at most. Split a crowded figure in two rather than shrinking text.
- Embed with a link to the file, so a click opens the SVG itself:
  `[![Package topology: tier order](diagrams/system-package-topology.svg)](diagrams/system-package-topology.svg)`.
- The prose next to a figure says what the figure cannot: invariants, failure modes, the why. A figure that only
  repeats a nearby table or list does not earn its place.

## Rules

- **Root element**: `viewBox="0 0 W H" width="W" height="H"` with W at most 1000, plus `role="img"`, `<title>` and a
  `<desc>` that states the figure's point in one or two sentences.
- **Self-contained and static-complete.** No scripts, web fonts, `<foreignObject>`, or external references. GitHub
  and IDE previews render SVG through `<img>`, which disables interaction, so the static render must carry
  everything a reader needs.
- **Interaction is a bonus for direct viewing.** Opened directly in a browser, CSS `:hover` highlighting, per-node
  `<title>` tooltips, and `<a href>` links to doc sections work. Put a node's outgoing edges inside its `<g
  class="node">` so hover can highlight them.
- **Theme.** Copy the `<style>` block from `system-package-topology.svg`: Catppuccin Latte colours by default, Mocha
  under `prefers-color-scheme: dark`, matching `dev/design-system/tokens.css`. Paint a full-size `.bg` rect first so
  the figure reads on any page background. Use the CSS variables, never literal colours in elements.
- **Colour means kind**, set by a class on the node group: `k-host` (DartClaw code), `k-ext` (external process or
  binary), `k-store` (persistent store), `k-sec` (security boundary or guard), `k-chan` (channel or outside
  service), `k-dev` (dev only, dashed). Explain anything else in a legend.
- **Text**: 11–13px body, 18px title, system font stacks from the style block. Names from code (classes, files,
  config keys) in `.mono`, spelled exactly as in code.
- **Edges** end on a box edge with the `#arrow` marker; no edge crosses a box or a label.

## Check before committing

Render both themes and look at them; fix clipped or overlapping text, edges through boxes, and unreadable arrows.

```bash
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
xmllint --noout fig.svg
"$CHROME" --headless=new --hide-scrollbars --window-size=W,H --screenshot=light.png "file://$PWD/fig.svg"
"$CHROME" --headless=new --hide-scrollbars --force-dark-mode --window-size=W,H --screenshot=dark.png "file://$PWD/fig.svg"
```
