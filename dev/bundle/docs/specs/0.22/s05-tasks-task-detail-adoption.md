# Tasks & Task Detail Adoption

**Plan**: dev/bundle/docs/specs/0.22/plan.json
**Story-ID**: S05

## Feature Overview and Goal

**Intent**: Bring the Tasks list and Task-detail pages onto the Afterglow canonical primitives so operators see one coherent, on-brand surface instead of the current mix of opaque dialogs, bare `<pre>` artifacts, and hardcoded tints.

**Expected Outcomes** (each `[OC<NN>]`-tagged; scenarios anchor here):

- [OC01] The New-Task and Add-Project dialogs read as translucent glass floating over the live page, with a theme-appropriate dimmed backdrop (no raw black) in both dark and light themes.
- [OC02] Diff and raw-data artifacts on task detail present as framed terminal windows (title bar + traffic-light dots), not bare `<pre>` blocks.
- [OC03] Task cards carry the semantically-correct `card-tint-*` for their status group, and the review-bar Accept/Reject/Push Back actions render on the canonical button base.
- [OC04] No template-local `display:none` toggle remains on the Tasks/Task-detail surface — visibility uses the `hidden` attribute.


## Required Context

> Load-bearing upstream spans inlined verbatim. Binding constraints flow unchanged from `plan.json#bindingConstraints`.

### From `prd.md` – "FR5: Per-page component adoption"
<!-- source: prd.md#fr5-per-page-component-adoption -->
<!-- extracted: 7d948b65 -->
> **Description**: Bring every page to "good" compliance by composing canonical primitives: glass (`.card-glass`) for overlays above live content (toasts, dialogs, composer palettes), `kbd` for shortcut hints, identicons for entity identity (sessions, channels, task agent badges — never state), terminal frames for diff/raw/step-output views, and `metric-value`/`display` type for KPIs/headers. Clear the violations inventory: purge inline styles into classes/utilities, delete the `settings.html` `<style>` block, collapse the three parallel layout-container families into the canonical one, fix non-token hovers, and convert `display:none` toggles to the `hidden` attribute.
>
> **Acceptance Criteria**:
> - Page-by-page compliance table (audit §5) reads "good" for all pages.
> - ≤5 justified inline `style` attributes remain app-wide; no template-local `<style>` block remains.
> - Glass is used only over live content (never in-flow); identicons encode entity identity only, never state.
> - Each page passes visual validation in both themes (desktop + 768px) before its work is considered done.

### Binding Constraint – FR5 (glass discipline)
<!-- source: prd.md#fr5-per-page-component-adoption -->
<!-- extracted: 7d948b65 -->
> Glass is used only over live content (never in-flow); identicons encode entity identity only, never state.

### Binding Constraint – NFR (design-system compliance + scarcity doctrine)
<!-- source: prd.md#constraints -->
<!-- extracted: 7d948b65 -->
> **Design-system compliance + scarcity doctrine**: one claw moment per view; CRT on the login hero only; glass only over live content; one entry motion.

### Binding Constraint – NFR (zero-npm / server-first)
<!-- source: prd.md#constraints -->
<!-- extracted: 7d948b65 -->
> **Zero-npm / server-first**: plain CSS + Trellis + HTMX + Stimulus + SSE; no build step; no new runtime JS dependencies.

### Binding Constraint – NFR (mobile parity)
<!-- source: prd.md#constraints -->
<!-- extracted: 7d948b65 -->
> **Mobile parity**: 768px breakpoint, 48px touch targets, 16px minimum input font.


## Deeper Context

- `audit-design-system-compliance.md#5-quick-reference--page-by-page-compliance` – Tasks (Partial), Task detail (Partial), Canvas/dialogs (Partial) rows: the specific top-3 fixes this story clears. Audit line numbers are stale — locate by selector/content.
- `audit-design-system-compliance.md#2-new-component-adoption-map` – Glass, terminal-frame, and card-tint application spots for these pages.
- `dev/design-system/DESIGN.md` – canon for `.card-glass` (overlay-above-live-content tier), `.terminal-frame`, `.card-tint-*` (hover-only semantic tint on categorized lists).


## Acceptance Scenarios

- [x] **S01 [OC01] [TI01,TI02] Task & project dialogs float as glass over the live page**
  - **Given** the Tasks page is loaded with a visible task list behind it
  - **When** the operator opens the New-Task dialog (and, on the projects surface, the Add-Project dialog)
  - **Then** each `<dialog>` renders with the canonical `card-glass` treatment (translucent + backdrop blur) rather than an opaque `--bg-mantle` fill, and the content behind reads through the glass

- [x] **S02 [OC01] [TI02] Dialog backdrop is theme-derived, not raw black**
  - **Given** the New-Task dialog is open in dark theme, then again in light theme
  - **When** the modal backdrop renders
  - **Then** the dim comes from a token-derived `color-mix` (theme-aware, e.g. `--bg-pit`/`--bg-crust`) and no `rgba(0, 0, 0, ...)` literal remains on `.task-dialog::backdrop`

- [x] **S03 [OC02] [TI03] Diff and raw artifacts render as terminal frames**
  - **Given** a task detail page whose artifacts include a diff view and a raw-data artifact
  - **When** the artifact column renders
  - **Then** each diff/raw view is wrapped in a `.terminal-frame` (bar + `.terminal-frame-dots` + `.terminal-frame-body`) with no `--crt` modifier (CRT is login-only per scarcity)

- [x] **S04 [OC03] [TI04] Running task cards carry data-driven semantic tint**
  - **Given** the Tasks page renders a running-status group (the only group rendered as cards today — non-running groups render as tables and stay untinted)
  - **When** the running task cards are built
  - **Then** each card applies the view-model `cardTintClass` (which maps running→`card-tint-accent`, queued/draft→`card-tint-info`, failed/cancelled→`card-tint-error`, review/interrupted→`card-tint-warning`) via `tl:classappend`, and no hardcoded `card-tint-accent` literal remains in `tasks.html` — this is a data-driven-consistency swap, NOT a table→card conversion

- [x] **S05 [OC03] [TI05] Review-bar actions render on the canonical button base**
  - **Given** a task in review state showing the Accept / Reject / Push Back bar
  - **When** the review bar renders
  - **Then** the three buttons compose the canonical `.btn` geometry (padding, font, radius, cursor inherited) carrying only their semantic success/error/warning tint, and render correctly in both themes

- [x] **S06 [OC04] [TI06] Push-back comment toggles via the hidden attribute**
  - **Given** a task in review; the push-back comment editor starts collapsed
  - **When** the operator triggers Push Back
  - **Then** the `.pushback-comment` block uses the `hidden` attribute (not `style="display:none"`), the controller reveals it by toggling the element's `hidden` attribute (`element.hidden`), and the show/hide behavior is unchanged from before

- [x] **S07 [OC01,OC04] [TI02,TI06,TI07] Task surface is grep-clean of raw color and inline display toggles**
  - **Given** the shipped `tasks.html`, `task_detail.html`, `task_timeline.html`, and the `.task-dialog` app CSS (the `task_form.dart` workflow-tab `display:none` toggles are S03-owned and explicitly carved out — see What We're NOT Doing)
  - **When** `tasks.html`/`task_detail.html` are swept for `style="display:none"` and the `.task-dialog::backdrop` app CSS is swept for `rgba(`
  - **Then** neither pattern remains, and `task_timeline.html` is confirmed free of S05-scope violations (no inline `style`, no `display:none`, no raw color) with no change required


## Structural Criteria

> Non-behavioral guards, each proved by a task Verify line.

- [x] No new runtime JS dependency, `@import`, or build step is introduced — changes are plain CSS + Trellis + Stimulus only (zero-npm constraint).
- [x] All CSS edits land in `static/app.css`; the synced `design-system.css` / `tokens.css` are untouched (drift check stays green).
- [x] `task_timeline.html` carries no S05-scope violation and is left unchanged.


## Scope & Boundaries

### Work Areas
- `templates/task_form.dart` + `templates/project_form.dart` — the two `<dialog class="task-dialog">` builders adopt the `card-glass` surface.
- `static/app.css` — `.task-dialog` drops its opaque fill; `.task-dialog::backdrop` becomes a token-mix; review-bar button rules (`.btn-accept/-reject/-pushback`) reduce to semantic tint over the `.btn` base.
- `templates/task_detail.html` — diff/raw artifact views wrapped in `.terminal-frame`; `.pushback-comment` moves to the `hidden` attribute.
- `templates/tasks.html` — running task cards wire `${task.cardTintClass}` instead of the hardcoded `card-tint-accent` literal.
- `static/controllers/dc_tasks_controller.js` — push-back comment reveal toggles `.hidden` instead of `.style.display`.
- `templates/task_timeline.html` — hygiene verification only (no violations expected → no edit).

### What We're NOT Doing
- Meters, the `budget-bar`/`task-progress` bars, and the task-detail activity-row loader -- owned by S03 (feedback primitives); leave the progress section and its dynamic `progressSectionStyle` toggle alone.
- Identicons for the task agent badge (`task-agent-badge`) -- owned by S13; the badge stays a text badge here.
- Empty-state claw-marks / mascot for the `tasks.html`/`task_detail.html` empty states -- owned by S12; leave the current emoji glyphs (`&#9744;`, `&#128172;`, `&#128451;`) untouched.
- Deleting the `--color-peach` token or fixing off-system-token use sites -- owned by S01; by the time S05 runs, `.btn-pushback` already reads a canonical token.
- Migrating `tasks.html`/`task_detail.html` off the shared `.page-content`/`.page-inner` layout-container family onto canonical `.content-area`/`.content-inner` -- deliberately deferred this milestone. The family survives app-side with many consumers (only `.dashboard*`/`.info*` collapse now, per S07/S10); this partial collapse is recorded as an intentional deviation via S14 (DESIGN.md note). S05 leaves the container family untouched.
- The New-Task dialog's workflow-tab loading/picker `display:none` toggles (`workflow-list-loading`, `workflow-list-empty`, `workflow-form`, `workflow-project-select`) -- driven by `dc_workflows_controller.js`. S03 (TI07) owns both the skeleton swap and the `display:none`→`hidden` conversion for these four elements and their controller writes; do not touch that controller or its markup here.
- The `.workflow-card:hover` non-token-border fix on the workflow-picker cards (`.workflow-card`, rendered into the New-Task dialog by `dc_workflows_controller.js`) -- owned by S06 (TI02); S05 leaves that hover rule untouched.


## Architecture Decision

**Approach**: Compose the already-synced canonical primitives (`card-glass`, `terminal-frame`, `card-tint-*`, `.btn`) in the templates/Dart builders; keep every CSS edit in `static/app.css` per the S01 sync contract. No new classes are invented — the view model already computes `cardTintClass`, so wiring is markup-side.


## Code Patterns & External References

```
# type | path#anchor                                              | why needed (intent)
file   | dev/design-system/components.css#.card-glass             | Glass recipe (sheen + edges + blur) the dialogs adopt — never in-flow
file   | dev/design-system/components.css#.terminal-frame         | Frame structure (bar + dots + body) for diff/raw artifacts; NO --crt here
file   | dev/design-system/components.css#.card-tint-accent        | Hover-only semantic tint variants; wired per status group
file   | dev/design-system/tokens.css#--bg-pit                    | Theme-aware deep-inset tokens for the token-mix backdrop
file   | packages/dartclaw_server/lib/src/templates/tasks.dart#cardTintClass | View model already emits the semantic tint per status — consume it
file   | packages/dartclaw_server/lib/src/static/controllers/dc_tasks_controller.js#push_back | Existing push-back reveal toggle to convert to .hidden
```


## Constraints & Gotchas

- **Glass only over live content**: dialogs float over the live task list, so `card-glass` is sanctioned; do not glass any in-flow card (`.task-meta-card`, artifact cards stay opaque `.card`).
- **Scarcity — no CRT here**: use the plain `.terminal-frame`; the single `--crt` surface app-wide is the login hero (S11).
- **Trellis smoke render passes null**: gate any new boolean on a pre-computed context field, and use `tl:attr`/`tl:classappend` for dynamic classes/attributes (raw `${}` in an attribute skips escaping). See LEARNINGS § Trellis Templates.
- **`[hidden]` reset already exists**: the `[hidden] { display: none !important; }` reset ships in `app.css` (a canonical-absent primitive kept app-side by the S01 split), so the `hidden` attribute is sufficient — no new app.css rule needed for the toggle.
- **CSS lives in `app.css` only**: the split from S01 makes `design-system.css` verbatim-synced; editing it fails the drift check. All S05 style changes go in `static/app.css`.


## Implementation Plan

### Implementation Tasks

- [x] **TI01** The New-Task and Add-Project dialogs are glass surfaces over live content
  - Compose the canonical pairing `card card-glass` on the `<dialog class="task-dialog">` element in `task_form.dart` and `project_form.dart` (same canon-settled glass recipe as S04's composer palettes). In `static/app.css`, drop `.task-dialog`'s opaque `background: var(--bg-mantle)` **and** its local `border`/`box-shadow` declarations so the canonical `.card` border plus `.card-glass`'s `border-color`/`border-top-color` and inset-sheen `box-shadow` cascade through – `app.css` loads after `design-system.css`, so a retained same-specificity `border`/`box-shadow` would silently cancel the glass edges and sheen. Keep the dialog's layout/padding rules and the token-derived `::backdrop` work (TI02).
  - **Verify**: `Test: rendered newTaskFormDialogHtml() and addProjectDialogHtml() contain classes "card card-glass" on the <dialog>; grep static/app.css .task-dialog rule has no "background: var(--bg-mantle)" and carries no local "border"/"box-shadow" override` (+ visual: the dialog reads as glass – sheen and bright edges, not translucency+blur alone – in both themes)

- [x] **TI02** The dialog backdrop is a theme-derived token mix
  - In `static/app.css`, replace `.task-dialog::backdrop { background: rgba(0,0,0,0.5) }` with a theme-aware `color-mix` (e.g. of `--bg-pit`/`--bg-crust`) so light theme dims correctly; keep the `backdrop-filter: blur(...)`.
  - **Verify**: `Test: grep static/app.css .task-dialog::backdrop block contains "color-mix" and contains no "rgba("`

- [x] **TI03** Diff and raw artifact views render as terminal frames
  - In `task_detail.html`, wrap the `pre.diff-view` / `div.diff-view` and `pre.task-artifact-raw` outputs in a `.terminal-frame` (with `.terminal-frame-bar` + `.terminal-frame-dots` + `.terminal-frame-body`). Plain frame only — no `--crt`. Preserve the existing `tl:utext`/`tl:text` bindings for content.
  - Each `.terminal-frame-bar` carries a short contextual title after the traffic-light dots, per the ratified `terminal-frame-title` convention (see Implementation Observations): the artifact filename, falling back to the artifact kind when no filename is available.
  - The common rendered-diff path is `div.diff-view` (`tasks_page.dart` sets `renderedHtml` for every diff artifact, via `_renderDiffHtml`) – a `div`, not a `pre`, so canon's `.terminal-frame-body pre` reset does not match it and its own `.diff-view` background/border/radius/padding would double-box inside the frame. Add to `static/app.css` a mirror reset `.terminal-frame-body .diff-view { background: transparent; border: none; box-shadow: none; padding: 0; }` so rendered diffs get the same flat framed look as canon's `pre` reset. The nested per-hunk `pre.task-artifact-raw` blocks inside that rendered diff go flat automatically via canon's descendant `pre` reset (canonical look; their `max-height`/`overflow` behavior survives, since the reset does not touch those). `tasks_page.dart` stays untouched (no Dart edit).
  - **Verify**: `Test: rendered task_detail with a diff artifact and a data artifact contains "terminal-frame" wrapping the diff-view and task-artifact-raw, with the artifact filename (or kind fallback) rendered as the title text in .terminal-frame-bar; contains no "terminal-frame--crt"; grep static/app.css contains a ".terminal-frame-body .diff-view" reset clearing background/border/box-shadow/padding`

- [x] **TI04** Running task cards carry the data-driven semantic tint
  - In `tasks.html`, the running task card (currently `class="card card-tint-accent task-card-running"`) applies `${task.cardTintClass}` via `tl:classappend` and drops the hardcoded `card-tint-accent` literal. The `cardTintClass` field already exists in `tasks.dart`.
  - **Verify**: `Test: grep tasks.html has tl:classappend referencing cardTintClass on the running card and no literal "card-tint-accent" string; rendered running group applies the class`

- [x] **TI05** Review-bar Accept/Reject/Push-Back render on the canonical button base
  - In `static/app.css`, reduce `.btn-accept` / `.btn-reject` / `.btn-pushback` to their semantic tint only (background/border/color), inheriting geometry (padding, font, radius, cursor) from the canonical `.btn` base; the template already applies `class="btn btn-accept"` etc.
  - **Verify**: `Test: grep static/app.css .btn-accept/.btn-reject/.btn-pushback rules declare no "padding:" and no "cursor:" (inherited from .btn); visual validation confirms button sizing in both themes`

- [x] **TI06** Push-back comment visibility uses the hidden attribute
  - In `task_detail.html`, change `<div class="pushback-comment" style="display:none">` to use the `hidden` attribute. In `dc_tasks_controller.js`, replace the `commentArea.style.display === 'none'` / `= ''` reveal (push_back branch) with a `.hidden` toggle. Behavior (collapsed until Push Back, then revealed) is unchanged.
  - **Verify**: `Test: grep task_detail.html .pushback-comment has "hidden" and no style="display; grep dc_tasks_controller.js push_back branch uses ".hidden" and not "style.display" for the comment area`

- [x] **TI07** `task_timeline.html` is confirmed free of S05-scope violations
  - Sweep `task_timeline.html` for inline `style` attributes, `display:none`, and raw color; it postdates the audit and is expected clean — record no change if so.
  - **Verify**: `Test: grep task_timeline.html finds no "style=" attribute (excluding tl:attr), no "display:none", no "rgba("`

### Validation
- Visual validation of the Tasks and Task-detail pages in both themes at desktop + 768px per the story gate: glass dialogs over the live list, terminal-framed artifacts, semantic card tints, review-bar buttons, and the push-back reveal. Exercise the review flow (`isReview` state) and a task with diff + data artifacts.


## Final Validation Checklist
- [x] `.task-dialog::backdrop` in `static/app.css` contains no `rgba(` literal (token-mix only).
- [x] No `style="display:none"` remains in `tasks.html` or `task_detail.html`.


## Implementation Observations

Records implementation-time observations, discovered requirements, and resolved/deferred decisions for this story.

- Critic review found the first backdrop token mix was opaque; the final mix uses `transparent` and computes to alpha 0.64 in both themes.
- Artifact/review live states were unavailable in the seeded profile; focused render/controller tests cover those paths.

#### DECISION NOTE: terminal-frame-title

- **Decision-Key:** terminal-frame-title
- **Altitude:** Component / cross-story UI convention (S05 + S06)
- **Affected surface:** `.terminal-frame` bars — S05 Task-detail diff/raw artifact frames (TI03); shared with S06 step-output frames
- **Decision:** Every `.terminal-frame` bar carries a short contextual title after the traffic-light dots. For S05 diff/raw artifact frames the label is the artifact filename, falling back to the artifact kind when no filename is available.
- **Rationale:** Establishes one shared app-wide title-bar convention with S06 (step-output frames use the step name), so terminal frames read consistently across surfaces.
- **Evidence:** Matches canon's showcase examples and DESIGN.md's `.terminal-frame` "title bar" contract; ratified by owner during 0.22 preflight, 2026-07-20.
