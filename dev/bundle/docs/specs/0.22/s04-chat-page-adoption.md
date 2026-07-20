# Chat Page Adoption

**Plan**: dev/bundle/docs/specs/0.22/plan.json
**Story-ID**: S04

## Feature Overview and Goal

**Intent**: Bring the chat page to "good" design-system compliance so its floating composer overlays, shortcut hints, and message treatments compose canonical Afterglow primitives instead of bespoke opaque panels and inline visibility hacks.

**Expected Outcomes** (each `[OC<NN>]`-tagged; scenarios anchor via `[OC<NN>]`):

- [OC01] The composer command and reference palettes read as glass — translucent + backdrop-blur floating over the live message thread — by composing the canonical `.card-glass` primitive rather than an opaque `var(--bg-mantle)` panel.
- [OC02] Composer keyboard affordances (the `/`-opens-commands hint and the Ctrl/⌘+Enter send hint) render as `kbd` keycaps.
- [OC03] The chat page carries no `style="display:none"` toggle; hidden UI uses the `hidden` attribute (honored by the app `[hidden]` reset).
- [OC04] Message tints, the streaming cursor, and the input focus ring render with canonical tokens (`--accent`/`--info`) and pass visual validation in both themes at desktop + 768px, with glass never bleeding onto in-flow content.


## Required Context

### From `prd.md` – "FR5: Per-page component adoption"
<!-- source: dev/bundle/docs/specs/0.22/prd.md#fr5-per-page-component-adoption -->
<!-- extracted: 7d948b65 -->
> **Description**: Bring every page to "good" compliance by composing canonical primitives: glass (`.card-glass`) for overlays above live content (toasts, dialogs, composer palettes), `kbd` for shortcut hints, identicons for entity identity (sessions, channels, task agent badges — never state), terminal frames for diff/raw/step-output views, and `metric-value`/`display` type for KPIs/headers. Clear the violations inventory: purge inline styles into classes/utilities, delete the `settings.html` `<style>` block, collapse the three parallel layout-container families into the canonical one, fix non-token hovers, and convert `display:none` toggles to the `hidden` attribute.
>
> **Acceptance Criteria**:
> - [ ] Page-by-page compliance table (audit §5) reads "good" for all pages.
> - [ ] ≤5 justified inline `style` attributes remain app-wide; no template-local `<style>` block remains.
> - [ ] Glass is used only over live content (never in-flow); identicons encode entity identity only, never state.
> - [ ] Each page passes visual validation in both themes (desktop + 768px) before its work is considered done.

### From `plan.json` – Binding Constraint FR5 (glass discipline)
<!-- source: dev/bundle/docs/specs/0.22/prd.md#fr5-per-page-component-adoption -->
<!-- extracted: 7d948b65 -->
> Glass is used only over live content (never in-flow); identicons encode entity identity only, never state.

### From `plan.json` – Binding Constraint NFR (scarcity doctrine)
<!-- source: dev/bundle/docs/specs/0.22/prd.md#constraints -->
<!-- extracted: 7d948b65 -->
> **Design-system compliance + scarcity doctrine**: one claw moment per view; CRT on the login hero only; glass only over live content; one entry motion.

### From `plan.json` – Binding Constraint NFR (zero-npm / server-first)
<!-- source: dev/bundle/docs/specs/0.22/prd.md#constraints -->
<!-- extracted: 7d948b65 -->
> **Zero-npm / server-first**: plain CSS + Trellis + HTMX + Stimulus + SSE; no build step; no new runtime JS dependencies.

### From `plan.json` – Binding Constraint NFR (mobile parity)
<!-- source: dev/bundle/docs/specs/0.22/prd.md#constraints -->
<!-- extracted: 7d948b65 -->
> **Mobile parity**: 768px breakpoint, 48px touch targets, 16px minimum input font.


## Deeper Context

- `audit-design-system-compliance.md#5-quick-reference--page-by-page-compliance` – Chat row: page is already "Good"; the two S04 fixes are "glass command/reference palettes + kbd hints" and `style="display:none"` → `hidden`. (Fix #1 in that row — claw-loader/print-in — belongs to S03/S02, not here.)
- `audit-design-system-compliance.md#2-new-component-adoption-map` – Glass row (composer palettes float over the thread → glass) and `kbd` row (composer `/`-to-open-commands + Enter-to-send hint). **Line numbers in the audit are stale — locate spots by selector/class name.**


## Acceptance Scenarios

- [ ] **S01 [OC01] [TI01] Command/reference palettes render as glass over the thread**
  - **Given** the `chatArea` fragment is rendered for a writable session
  - **When** the command palette (`[data-dc-chat-target="commandPalette"]`) and reference palette (`[data-dc-chat-target="referencePalette"]`) markup is inspected
  - **Then** each palette element carries the canonical `card card-glass` pairing, and the app `.composer-palette`/`.composer-reference-palette` rules no longer set an opaque `background: var(--bg-mantle)` nor a local `border`/`box-shadow` that would cancel the glass edges; when opened over a populated thread in both themes the panel reads as glass – translucent with backdrop blur, the top-light sheen, and bright edges

- [ ] **S02 [OC02] [TI02] Composer shortcut affordances render as keycaps**
  - **Given** the `chatArea` composer is rendered
  - **When** the shortcut hints are inspected
  - **Then** a `/`-opens-commands hint and a send hint (the real binding is Ctrl/⌘+`Enter`, per `dc_chat_controller.js` — plain Enter does not send) present their key labels as `<kbd>` (or `.kbd`) keycap elements, distinct from the interactive `/` trigger button

- [ ] **S03 [OC03] [TI03] Hidden chat UI uses the `hidden` attribute**
  - **Given** the `sendResponse` fragment is rendered
  - **When** the `#turn-error-target` element is inspected
  - **Then** it uses the `hidden` attribute for its initial hidden state and no `style="display:none"` (or any inline `display:none`) appears anywhere in `chat.html`

- [ ] **S04 [OC04] [TI04] Message treatments read canonically in both themes**
  - **Given** the chat page in dark and light theme at desktop and 768px
  - **When** a user message and a streaming assistant message are shown
  - **Then** `.msg-user` tints to `var(--accent)`, `.msg-assistant` tints to `var(--info)`, the streaming cursor (`.streaming::after`) is the `var(--accent)` block glyph, and the input focus ring (`.input-area textarea:focus`) is the `var(--accent)` ring — all passing visual validation with no hardcoded color

- [ ] **S05 [OC01,OC04] [TI01] Glass stays over live content only**
  - **Given** the rendered message thread (`.messages` with `.msg` cards) and composer row
  - **When** the in-flow content is inspected
  - **Then** no `.msg`/message card and no `.composer-row` carries `card-glass` — glass is confined to the floating palettes (never in-flow)


## Structural Criteria

- [ ] No inline `display:none` (e.g. `style="display:none"`) remains in `chat.html` (grep-clean).
- [ ] Synced `static/design-system.css` is untouched by this story; every CSS change lands in `static/app.css` only (S01 sync contract; drift check stays green).
- [ ] Glass is composed by applying the canonical `.card-glass` class — no bespoke glass recipe (`--glass-bg`/`backdrop-filter`) is duplicated into `app.css`.
- [ ] Existing chat template render tests and the UI smoke test (TC-01…TC-31) still pass.
- [ ] No claw-loader, skeleton, or meter markup is added/changed on the chat page (S03 ownership); the pre-stream slot and load-earlier button are left as-is.


## Scope & Boundaries

### Work Areas
- `packages/dartclaw_server/lib/src/templates/chat.html` — `chatArea` composer palettes (glass class + `kbd` hints) and `sendResponse` `#turn-error-target` (`hidden` attribute). [TI01, TI02, TI03]
- `packages/dartclaw_server/lib/src/static/app.css` — composer-palette rules (drop opaque background, keep positioning), and verification of `.msg-user`/`.msg-assistant`/`.streaming::after`/`.input-area textarea:focus` token cleanliness. [TI01, TI04]
- `packages/dartclaw_server/lib/src/static/controllers/dc_chat_controller.js` — confirm palette open/close continues to drive the `hidden` property (no inline `style.display`) after the glass class lands. [TI01]
- `packages/dartclaw_server/test/templates/render_test.dart` — chat-fragment render assertions for the glass class, `kbd`, and `hidden` attribute. [TI01, TI02, TI03]

### What We're NOT Doing
- Pre-stream claw-loader and the load-earlier skeleton -- owned by S03 (feedback-primitive ownership); this story composes, never re-swaps, loading UI.
- `print-in` arrival motion on message fragments -- owned by S02.
- Identicons (session rows, agent badges) and meters -- owned by S13 / S03; not on the chat composer's scope.
- Layout-container family collapse -- the chat page uses `.chat-area`, not a parallel `.page-*`/`.dashboard-*`/`.info-*` family, so there is nothing to migrate.
- Replacing `window.confirm` -- sanctioned by DESIGN.md and out of scope (and not used in the chat composer).


## Architecture Decision

**Approach**: Compose the canonical `.card-glass` primitive on the two floating composer palettes and use the `kbd` primitive for shortcut hints — both already present in the S01-synced `design-system.css` — editing only the Trellis template and app-only positioning/token rules in `app.css`.
**Why this over alternatives**: Applying the canonical class keeps the sync contract intact (no glass recipe duplicated app-side) and the drift check green, versus re-implementing glass in `app.css`.


## Code Patterns & External References

```
# type | path#anchor                                                        | why needed (intent)
file   | dev/design-system/components.css#card-glass                        | Canonical glass recipe (blur + sheen + edges) — the class to compose on palettes; do NOT copy into app.css
file   | dev/design-system/components.css (kbd, .kbd)                       | Keycap primitive for shortcut hints
file   | packages/dartclaw_server/lib/src/templates/chat.html              | chatArea (composer palettes ~ln 62-77) + sendResponse (#turn-error-target inline display:none) — edit both fragments
file   | packages/dartclaw_server/lib/src/static/app.css                   | .composer-palette/.composer-reference-palette (opaque bg to drop), .msg-user/.msg-assistant tints, .streaming::after, .input-area textarea:focus — post-S01 these live in app.css; locate by selector (audit lines stale)
file   | packages/dartclaw_server/lib/src/static/controllers/dc_chat_controller.js | Palettes toggle via the `hidden` property (renderCommandPalette/hideCommandPalette) — verify glass class does not regress this
file   | packages/dartclaw_server/test/templates/render_test.dart          | renderFileFragment('chat', fragment: 'chatArea'|'sendResponse') seam for scenario assertions
```


## Constraints & Gotchas

- **Constraint**: S01 already split CSS into synced `static/design-system.css` + app-only `static/app.css` and S02/S03 landed the sync contract. -- All edits here go in `app.css`/templates only; never hand-edit the synced file, and route any new generic class upstream-first to `dev/design-system/`.
- **Avoid**: Duplicating the glass recipe (`--glass-bg` / `backdrop-filter`) into `app.css`. -- Instead: apply the canonical `.card-glass` class in the template; `app.css` keeps only palette *positioning* (`position:absolute`, `bottom`, `z-index`).
- **Critical**: The `[hidden] { display:none !important }` reset and the controller's `palette.hidden = true/false` toggling drive palette visibility. -- Adding `.card-glass` (which sets no `display`) must not reintroduce an inline `style.display`, or the `hidden` toggle silently breaks.
- **Constraint**: Glass only over live content. -- Apply it to the two floating palettes only; in-flow `.msg` cards and the `.composer-row` stay opaque.


## Implementation Plan

### Implementation Tasks

- [ ] **TI01** Composer command and reference palettes read as glass floating over the thread
  - Compose the canonical pairing `card card-glass` on `.composer-palette`/`.composer-reference-palette` markup in `chat.html#chatArea` (per DESIGN.md's depth ladder + showcase usage). In `app.css`, drop the opaque `background: var(--bg-mantle)` **and** the local `border`/`box-shadow` declarations from those rules so `.card-glass`'s `border-color`/`border-top-color` and inset-sheen `box-shadow` cascade through – `app.css` loads after `design-system.css`, so a retained same-specificity `border`/`box-shadow` would silently cancel the glass sheen and edges. Keep positioning (`position/left/right/bottom/z-index`). Confirm `dc_chat_controller.js` still opens/closes via the `hidden` property.
  - **Verify**: `Test: renderFileFragment('chat', fragment:'chatArea') output shows commandPalette and referencePalette elements with classes "card card-glass"; grep confirms app.css .composer-palette/.composer-reference-palette no longer set "background: var(--bg-mantle)" and carry no local "border"/"box-shadow" override; no "backdrop-filter"/"--glass-bg" literal added to app.css` (+ visual: over a populated thread in both themes the panel reads as glass – translucent blur plus the top-light sheen and bright edges, not translucency+blur alone)

- [ ] **TI02** Composer shortcut affordances present their keys as keycaps
  - Add `<kbd>` keycap hints in the composer, rendered inside the existing `.composer-suggestions` area (`chat.html#chatArea`, chat.html:70): a `/`-opens-commands hint and a send hint using the real binding Ctrl/⌘+`Enter` (confirmed at `dc_chat_controller.js:115` — `(ctrlKey||metaKey) && key==='Enter'`; plain Enter does not submit). Keep `kbd` presentational — do not wrap the interactive `/` trigger button. Text/token utilities only — no new runtime JS.
  - **Verify**: `Test: renderFileFragment('chat', fragment:'chatArea') output contains "<kbd" keycaps carrying the "/" label and an "Enter" label paired with a Ctrl/⌘ modifier keycap`

- [ ] **TI03** Chat page hides UI via the `hidden` attribute (no inline display)
  - Change `#turn-error-target` in `chat.html#sendResponse` from `style="display:none"` to the `hidden` attribute (works with the existing `htmx:afterSwap` handler and the `[hidden]` reset).
  - **Verify**: `Test: renderFileFragment('chat', fragment:'sendResponse') output shows #turn-error-target with the hidden attribute; grep of chat.html finds zero "display:none"`

- [ ] **TI04** Message tints, streaming cursor, and input focus ring compose canonical tokens
  - Confirm `.msg-user` → `var(--accent)`, `.msg-assistant` → `var(--info)`, `.streaming::after` → `var(--accent)` block glyph, `.input-area textarea:focus` → `var(--accent)` ring in `app.css`; align any off-token value found. No hardcoded hex.
  - **Verify**: `Test: grep of app.css chat rules shows .msg-user/.msg-assistant using var(--accent)/var(--info), .streaming::after and textarea:focus using var(--accent), with no hex literal` (+ visual: both themes, desktop + 768px, "good" compliance)


## Implementation Observations

_No observations recorded yet._
