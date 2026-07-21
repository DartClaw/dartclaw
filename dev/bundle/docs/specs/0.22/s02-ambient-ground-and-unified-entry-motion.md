# Ambient ground & unified entry motion

**Plan**: plan.json
**Story-ID**: S02

## Feature Overview and Goal

**Intent**: Make the Web UI feel like one atmospheric, deliberately-crafted surface by landing the canonical body ground everywhere it should show and giving every arriving piece of content a single, shared entry motion instead of an inconsistent or missing one.

**Expected Outcomes** (each `[OC<NN>]`-tagged; scenarios anchor here):

- [OC01] The atmospheric ground (3-stop gradient + ambient glows + film-grain `body::before`) renders correctly across the shell content areas, dialogs, and SSE-swapped regions in both themes — no banding on large viewports, grain layered behind content and above the gradient.
- [OC02] A single `print-in` arrival motion is the entry treatment for newly-arrived message fragments, HTMX-swapped page content, task cards, and workflow run cards — no other content-entry animation competes with it (the sanctioned toast slide aside).
- [OC03] Under `prefers-reduced-motion: reduce`, no entry or lift motion is perceptible: `print-in` arrives statically, micro-lifts are neutralized, and the ambient ground stays static.


## Required Context

### From `prd.md` – "FR3: Atmospheric ground & unified entry motion"
<!-- source: prd.md#fr3-atmospheric-ground--unified-entry-motion -->
<!-- extracted: 7d948b65 -->
> **Description**: Apply the canonical body ground (3-stop gradient + ambient glows + film-grain `body::before`) and a single `print-in` arrival motion to message fragments and HTMX-swapped content. All motion respects `prefers-reduced-motion`.
>
> **Acceptance Criteria**:
> - Body ground renders without banding on large viewports; grain layer sits correctly behind content and above the gradient; verified against the shell grid, dialogs, and SSE swaps in both themes.
> - `print-in` is the single arrival treatment (messages, swapped fragments, cards); no competing entry animations.
> - `prefers-reduced-motion` disables ambient/print-in/loader animation and micro-lifts.

### From `prd.md` – "Edge Cases" (ground/motion rows)
<!-- source: prd.md#edge-cases -->
<!-- extracted: 7d948b65 -->
> | Film-grain / ambient ground causes banding or stacking issues on large viewport | Grain sits behind content, above gradient; no banding | Tune `--noise-opacity` per theme; verify `z-index`/`background-attachment` against shell grid, dialogs, SSE swaps |
> | `prefers-reduced-motion` user | Claw-loader, print-in, micro-lifts disabled; static fallbacks | n/a (handled by reduced-motion block) |
> | Light theme | Ambient glow percentages tuned for Latte (darker hues); contrast preserved | Per-theme token values; validate both themes per story |

### From `prd.md` – "US04" (both-theme + reduced-motion acceptance)
<!-- source: prd.md#user-stories -->
<!-- extracted: 7d948b65 -->
> As an operator on mobile or in light theme, I want every page to render correctly so I can use DartClaw on any device/theme. **Acceptance**: Every modified page passes visual validation in dark + light at desktop and 768px; touch targets ≥48px; inputs ≥16px; `prefers-reduced-motion` disables claw-loader/print-in/micro-lifts.

### From `prd.md` – Binding Constraint: one entry motion / scarcity
<!-- source: prd.md#constraints -->
<!-- extracted: 7d948b65 -->
> **Design-system compliance + scarcity doctrine**: one claw moment per view; CRT on the login hero only; glass only over live content; one entry motion.

### From `prd.md` – Binding Constraint: zero-npm / server-first
<!-- source: prd.md#constraints -->
<!-- extracted: 7d948b65 -->
> **Zero-npm / server-first**: plain CSS + Trellis + HTMX + Stimulus + SSE; no build step; no new runtime JS dependencies.

### From `prd.md` – Binding Constraint: mobile parity
<!-- source: prd.md#constraints -->
<!-- extracted: 7d948b65 -->
> **Mobile parity**: 768px breakpoint, 48px touch targets, 16px minimum input font.

### From `audit-design-system-compliance.md` – adoption map: `.print-in` + ambient ground (placement contract; line numbers STALE — locate by selector/content)
<!-- source: audit-design-system-compliance.md#2-new-component-adoption-map -->
<!-- extracted: 7d948b65 -->
> **`.print-in`**: Message fragments (user/assistant msg roots); HTMX-swapped page content `#main-content` swaps (sidebar nav targets); task cards; workflow run cards; toast already has its own slide — leave it. Apply via the shared fragment roots, not per-page.
>
> **Ambient ground + film grain**: Free with sync (`body` + `body::before`). Verify against `.shell` full-viewport grid — sidebar/topbar are opaque mantle, so the ground shows only in `.messages`/content scroll areas; check banding and the `z-index: -1` grain layer with the app's stacking contexts.


## Acceptance Scenarios

- [x] **S01 [OC01] [TI05] Ground renders without banding in both themes**
  - **Given** the app is loaded on a large (~2560px-wide) viewport with a sparse content page
  - **When** it is viewed in dark theme and then in light theme (`data-theme="light"` on `<html>`)
  - **Then** the 3-stop gradient plus the three ambient glows render with no visible banding, the film-grain layer sits behind in-flow content and above the gradient, and the light theme shows the Latte-tuned glows/opacity — with `design-system.css` and `tokens.css` left byte-identical to canon

- [x] **S02 [OC02] [TI01,TI03] Messages and swapped page content arrive via print-in**
  - **Given** an active chat session and the sidebar navigation
  - **When** a new assistant message fragment is inserted into the thread, and separately a sidebar link swaps `#main-content` to another page
  - **Then** each newly-inserted root plays the `print-in` rise+fade once and carries the `print-in` class, and no second entry animation plays on it

- [x] **S03 [OC02] [TI02] Task cards and workflow run cards arrive via print-in**
  - **Given** the tasks page and the workflow list page
  - **When** their card lists render
  - **Then** each task card root and each workflow run-card root carries `print-in` as its arrival treatment

- [x] **S04 [OC02] [TI04] The legacy view-transition cross-fade no longer competes on main-content swaps**
  - **Given** an HTMX navigation that swaps `#main-content`
  - **When** the swap occurs
  - **Then** the content arrives via `print-in` only — `app.css` defines no `::view-transition-old/new(main-content)` animation and no `vt-fade-in`/`vt-fade-out` keyframes, so no cross-fade competes with print-in

- [x] **S05 [OC03] [TI06] Reduced-motion yields static arrival and lifts**
  - **Given** the user agent reports `prefers-reduced-motion: reduce`
  - **When** a message/page/card arrives and a hoverable surface (`.btn`/`.card`) is hovered
  - **Then** no motion plays — `print-in` resolves instantly with no translate, micro-lifts are neutralized, and the ambient ground remains static

- [x] **S06 [OC01] [TI05] Ground stacks correctly under dialogs and live SSE content**
  - **Given** a dialog open over live content and a chat streaming via SSE
  - **When** rendered in both themes
  - **Then** the film-grain/ground shows correctly behind content (grain at `z-index: -1` not clipped or covered by the shell grid or dialog stacking contexts) with no grain bleeding above in-flow content


## Structural Criteria

- [x] `static/design-system.css` and `static/tokens.css` remain byte-identical to canon (drift check green) — this story edited only `static/app.css` and templates.
- [x] The canonical `prefers-reduced-motion` rule that neutralizes `.claw-loader` animation is present in the synced `design-system.css` (keeps the loader-disable path intact for S03).
- [x] No new runtime JS dependency is introduced; `print-in` (via `@starting-style`) and the ground (gradient + inline SVG noise) are CSS-only.
- [x] Exactly one content-entry motion (`print-in`) exists app-wide; the toast slide is the only other sanctioned arrival animation.


## Scope & Boundaries

### Work Areas
- `templates/chat.html` — message fragment roots (`userMessage`, `assistantMessage`, inline user echo, `#streaming-msg`) carry `print-in`.
- `templates/tasks.html` + `templates/workflow_list.html` — task-card and workflow-run-card iteration roots carry `print-in`.
- The 18 page templates' `id="main-content"` swap-target roots carry `print-in` (HTMX-swapped page content arrival).
- `static/app.css` — retire the app-only `::view-transition(main-content)` cross-fade (+ its `vt-fade-*` keyframes and `view-transition-name`); per-theme `--noise-opacity`/stacking overrides only if validation reveals banding.
- Ambient-ground stacking/banding verification across the shell grid, dialogs, and SSE swaps in both themes (visual gate).

### What We're NOT Doing
- Loading/progress indicators — meters, claw-loader, skeletons, scan-bar placement — deferred to S03; only the reduced-motion verification of the already-synced loader rule is in scope here.
- Editing `design-system.css`/`tokens.css`/`icons.css` — the ground/print-in CSS arrives with the S01 sync; per the CSS-layering shared decision this story tunes/applies in `app.css` + templates only.
- The toast slide-in animation — sanctioned by the adoption map ("toast already has its own slide — leave it"); not a competing motion.
- Glass surfaces, identicons, `window.confirm`, per-page component adoption — owned by S03–S13.


## Architecture Decision

**Approach**: Apply the canonical `.print-in` class (synced by S01) to the shared fragment/swap-target roots and retire the app-only `::view-transition(main-content)` cross-fade so print-in is the single arrival treatment; verify the atmospheric ground's stacking/banding and tune per-theme `--noise-opacity` in `app.css` only.
**Why this over alternatives**: Reuses canonical CSS (no new motion authoring) and removes the legacy view-transition rather than keeping two entry treatments racing on the same `#main-content` swap.


## Code Patterns & External References

```
# type | path#anchor or content                                              | why needed (intent)
file   | dev/design-system/components.css#.print-in                          | Canonical print-in (transition + @starting-style); the class S01 syncs — apply, don't re-author
file   | dev/design-system/components.css (body / body::before)              | Canonical ground + grain rules synced by S01 — reference for stacking/z-index expectations
file   | dev/design-system/tokens.css (--noise-opacity / --ambient-a..c)     | Canonical per-theme noise/ambient values (mocha 0.04, latte 0.03) — the baseline before any app.css override
file   | packages/dartclaw_server/lib/src/static/components.css (view-transition block) | The app-only vt-fade(main-content) cross-fade to retire (lands in app.css after S01)
file   | packages/dartclaw_server/lib/src/templates/chat.html                | Message fragment roots (.msg / #streaming-msg) — print-in targets
file   | packages/dartclaw_server/lib/src/templates/sidebar.html             | #main-content swap targets (hx-select="#main-content" hx-swap="outerHTML")
wire   | dev/design-system/showcase.html                                     | Afterglow reference for print-in + ground appearance
```


## Constraints & Gotchas

- **Constraint**: Only `static/app.css` and templates may change — `design-system.css`/`tokens.css`/`icons.css` are S01-synced and drift-checked. Any per-theme `--noise-opacity` or stacking tuning goes in `app.css` (loaded after, so overrides cascade correctly).
- **Avoid**: Applying `print-in` to per-token/per-delta SSE swap targets (`#streaming-content`, `sse-swap="delta"`) — `@starting-style` fires per inserted element and would jitter on every token. Instead: apply only at message/card/page-swap **root** granularity.
- **Critical**: `position: fixed` on `body::before` is relative to the viewport only while no ancestor establishes a containing block via `transform`/`filter`/`will-change`. If the grain appears clipped, the culprit is such a property on a shell/dialog ancestor — fix the stacking context, don't move the grain into app.css re-authoring.
- **Critical**: The synced canonical reduced-motion block already neutralizes `print-in` (a transition) and micro-lifts via the universal `transition-duration: 0.01ms !important`. Do not add duplicate reduced-motion overrides in `app.css` for these; only app-specific animated elements need app.css reduced-motion coverage.


## Implementation Plan

### Implementation Tasks

- [x] **TI01** Chat message fragment roots arrive via `print-in`
  - Add `print-in` to the `userMessage`, `assistantMessage`, inline user-echo, and `#streaming-msg` roots in `templates/chat.html` (the `.msg` roots); never on the `sse-swap="delta"` delta target.
  - **Verify**: `Test: rendered userMessage, assistantMessage, and #streaming-msg roots each include class token "print-in"; #streaming-content does NOT`

- [x] **TI02** Task cards and workflow run cards arrive via `print-in`
  - Add `print-in` to the `tl:each` task-card root in `templates/tasks.html` and the `workflow-run-card` root in `templates/workflow_list.html`.
  - **Verify**: `Test: rendered tasks.html task-card root and workflow_list.html .workflow-run-card root each include class token "print-in"`

- [x] **TI03** HTMX-swapped page content arrives via `print-in`
  - Add `print-in` to every page template's `id="main-content"` swap-target root (the `hx-select="#main-content"` outerHTML swap surface); apply at the shared root, not per-inner-element.
  - **Verify**: `Test/grep: count of templates matching id="main-content" (18) equals count whose #main-content element also carries the print-in class`

- [x] **TI04** `#main-content` swaps have a single arrival treatment
  - Remove the app-only view-transition cross-fade for main-content from `app.css`: the `::view-transition-old/new(main-content)` animations, the `vt-fade-in`/`vt-fade-out` keyframes, and the now-orphaned `view-transition-name: main-content` (leave the canonical toast slide untouched).
  - **Verify**: `grep -nE 'vt-fade|::view-transition[^{]*main-content' packages/dartclaw_server/lib/src/static/app.css` returns no matches; `Test: rendered #main-content arrival treatment is print-in only`

- [x] **TI05** Atmospheric ground renders correctly across shell grid, dialogs, and SSE swaps in both themes
  - Visual-validate the synced `body`/`body::before` ground: no banding on a large viewport; grain (`z-index: -1`) behind content and above the gradient; ground visible in `.messages`/content areas with opaque sidebar/topbar; both themes. Override `--noise-opacity` (or stacking) per theme in `app.css` only if a theme still bands.
  - **Verify**: `Visual: dark + light at desktop (large viewport) + 768px (including the mobile sidebar drawer OPEN over the ground – grain/ground renders correctly behind the drawer scrim) — no gradient banding; grain layered behind in-flow content; dialog-open and SSE-streaming views show ground correctly; design-system.css/tokens.css unchanged (drift check green)`

- [x] **TI06** `prefers-reduced-motion` yields static arrival, lifts, and ground
  - Confirm the synced reduced-motion block neutralizes `print-in`, micro-lifts, and the `.claw-loader` animation; the ground is inherently static (no animation to disable). Add app.css reduced-motion coverage only for app-specific animated elements, if any.
  - **Verify**: `Visual (reduced-motion emulated): print-in resolves with no translate; .btn/.card hover produces no lift; ground static.` `grep -n 'claw-loader' packages/dartclaw_server/lib/src/static/design-system.css` shows the `.claw-loader` animation neutralized inside the reduced-motion block

### Testing Strategy
- Template-level `print-in` placement (TI01–TI04) is provable at Layer 2/3 against rendered output strings per the `dartclaw_server` testing convention — assert the class token on rendered fragment/page roots and its absence on delta targets. Ground rendering, banding, stacking, and reduced-motion (TI05–TI06) are inherently visual and covered by the visual-validation gate (both themes, desktop + 768px), not Dart tests.

### Execution Contract
- Depends on S01 (the synced `design-system.css`/`app.css`/`tokens.css` split and the canonical `.print-in`/ground/reduced-motion rules must exist first). TI04 removes an `app.css` rule that only exists post-S01 sync.


## Final Validation Checklist
- [x] After all tasks, only `static/app.css` and files under `templates/` changed among CSS/synced assets — `design-system.css`, `tokens.css`, `icons.css` untouched (drift check green).


## Implementation Observations

- Applied `print-in` at fragment/card/page roots only; SSE delta targets remain unanimated.
- Visual validation passed in dark and light themes at 2560px and 768px, including the open mobile drawer and reduced-motion mode.
