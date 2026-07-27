# Canon: dialog primitive and feedback decision-table rewrite

**Plan**: docs/specs/0.22.1/plan.json
**Story-ID**: S04

## Feature Overview and Goal

**Intent**: DESIGN.md currently *sanctions* `confirm()` and ships no dialog frame at all, so the app was forced to invent a private modal and every destructive action in the product hands its irreversible decision to an unthemeable OS box — this story removes that sanction and puts a real dialog in canon, which is the single upstream blocker 0.22 recorded three times.

**Expected Outcomes**

- [OC01] A destructive confirmation or a structured-input modal can be built entirely from canonical classes — frame, scrim, header/body/footer/actions, width tier and confirm variant all live in `dev/design-system/` and are demonstrated in `showcase.html`.
- [OC02] DESIGN.md no longer sanctions native dialogs: the feedback decision table routes all five feedback cases to canon mechanisms and explicitly bans `alert()` / `confirm()` / `prompt()`.
- [OC03] Toast severity is legible without colour — success, error, warning and info each carry a distinct leading glyph, and an unrecognised type still gets one.
- [OC04] Overlay stacking is chosen from a named token tier in canon, and the `showModal()` top-layer exception is documented rather than discovered as a bug.


## Required Context

### From `docs/specs/0.22.1/prd.md` – "FR4: Form, tab and dialog primitives in canon"
<!-- source: docs/specs/0.22.1/prd.md#fr4-form-tab-and-dialog-primitives-in-canon -->
<!-- extracted: e18cf85c5939ea2dec5f06cc5744dee27620c640 -->
> …add `.dialog` (frame, `::backdrop` scrim, `-header` / `-body` / `-footer` / `-actions`, `--sm|--md` width ladder, `.dialog--confirm` variant). Promote the app's proven private `.task-dialog` recipe rather than inventing a new one. Document all three families in DESIGN.md and showcase.html; then delete the app-local duplicates and fold `.settings-tabs` / `.tab-bar` onto the canonical component.
>
> **Acceptance Criteria**:
> - [ ] `.form-*`, `.tabs`/`.tab`, `.dialog` exist in canon, documented and demonstrated.
> - [ ] No app-local re-implementation of any of the three remains; only one tab bar ships.

### From `docs/specs/0.22.1/prd.md` – "FR5: Feedback decision-table rewrite + native dialog eradication"
<!-- source: docs/specs/0.22.1/prd.md#fr5-feedback-decision-table-rewrite--native-dialog-eradication -->
<!-- extracted: e18cf85c5939ea2dec5f06cc5744dee27620c640 -->
> **Description**: Rewrite the DESIGN.md feedback decision table to five rows — persistent problem → banner; transient success/error → toast; destructive confirmation → `.dialog--confirm`; row-scoped destructive → the inline `.delete-confirm-bar` the app already ships; needs structured input → `.dialog` with real form controls — and add an explicit **"native `alert()` / `confirm()` / `prompt()` are banned"** line, mirroring the § Native selects prohibition. Then route all nine call sites through one `confirmDialog({title, body, confirmLabel, danger})` in `shared.js`. For the three `hx-confirm` templates, add a single `htmx:confirm` listener in `dc_shell_controller.js` — zero template edits, and all future `hx-confirm` uses convert automatically.

### From `docs/specs/0.22.1/plan.json` – Binding Constraint: Key Constraints, Assumptions & Dependencies
<!-- source: docs/specs/0.22.1/prd.md#key-constraints-assumptions--dependencies -->
<!-- extracted: e18cf85c5939ea2dec5f06cc5744dee27620c640 -->
> *Constraint:* **canon-first is mandatory.** The 0.22 drift check requires `design-system.css` byte-identical to `dev/design-system/components.css`. Any app-side edit to a canon-owned rule fails CI.
>
> *Constraint:* zero-npm / server-first; no build step; no new runtime JS dependencies (FR8 *removes* runtime dependencies, it does not add any).

### From `docs/specs/0.22.1/plan.json` – Binding Constraint: Constraints
<!-- source: docs/specs/0.22.1/prd.md#constraints -->
<!-- extracted: e18cf85c5939ea2dec5f06cc5744dee27620c640 -->
> **No backend work.** Any finding needing a service, schema or API change is out of scope by definition.

### From `docs/specs/0.22.1/plan.json` – Binding Constraint: Out of Scope
<!-- source: docs/specs/0.22.1/prd.md#out-of-scope -->
<!-- extracted: e18cf85c5939ea2dec5f06cc5744dee27620c640 -->
> New UX capabilities of any kind. This release adds no features; it refines what exists.

### From `docs/specs/0.22.1/plan.json` – Binding Constraint: FR5
<!-- source: docs/specs/0.22.1/prd.md#fr5-feedback-decision-table-rewrite--native-dialog-eradication -->
<!-- extracted: e18cf85c5939ea2dec5f06cc5744dee27620c640 -->
> Zero `window.alert` / `window.confirm` / `window.prompt` / bare `alert(` / `confirm(` / `prompt(` in `lib/src/static/controllers/`.

### From `docs/specs/0.22.1/plan.json` – Binding Constraint: Non-Functional Requirements
<!-- source: docs/specs/0.22.1/prd.md#non-functional-requirements -->
<!-- extracted: e18cf85c5939ea2dec5f06cc5744dee27620c640 -->
> WCAG AA text contrast preserved in both themes after the surface remap; `prefers-reduced-motion` honored; focus-visible on every interactive element; status never conveyed by colour alone
>
> Both themes at desktop + 768px per story; UI smoke test at phase boundaries; the 92-screenshot audit capture reused as the before/after baseline

### From `docs/specs/0.22.1/plan.json` – Shared Decision: "One dialog frame and one confirmation API"
<!-- source: docs/specs/0.22.1/plan.json#sharedDecisions -->
<!-- extracted: e18cf85c5939ea2dec5f06cc5744dee27620c640 -->
> S04 ships the canonical `.dialog` family (promoted from the app's proven private `.task-dialog`) with `.dialog--confirm` and an explicit z-index scale. S05 repoints existing markup at it and deletes the private recipe. S06 ships exactly one `confirmDialog({title, body, confirmLabel, danger})` in `shared.js` plus one `htmx:confirm` listener in `dc_shell_controller.js` — every current and future confirmation routes through those two, and no story adds a second dialog implementation.

### From `docs/specs/0.22.1/plan.json` – Shared Decision: "Composite type-class vocabulary"
<!-- source: docs/specs/0.22.1/plan.json#sharedDecisions -->
<!-- extracted: e18cf85c5939ea2dec5f06cc5744dee27620c640 -->
> S02 fixes the seven composite class names, each binding font-size + weight + line-height + letter-spacing: `.t-caption`, `.t-body`, `.t-label`, `.t-heading`, `.t-page-title`, `.t-display`, `.t-metric`. All consumers apply these classes; raw `--text-*` tokens are for one-offs only, and no consumer hand-derives a tier from four separate properties.

### From `docs/specs/0.22.1/plan.json` – Shared Decision: "`--text-sm` retirement protocol"
<!-- source: docs/specs/0.22.1/plan.json#sharedDecisions -->
<!-- extracted: e18cf85c5939ea2dec5f06cc5744dee27620c640 -->
> Two-step so the app never breaks mid-migration: S02 aliases `--text-sm` to `--text-base` in canon `tokens.css` and stops treating it as a tier in DESIGN.md; S07 migrates every remaining usage in `app.css` and `design-system.css` onto the composite classes and then deletes the alias from canon. No other story introduces a new `--text-sm` usage.


## Deeper Context

- `../dartclaw-public/dev/design-system/DESIGN.md#banners-and-toasts` – the 4-row table being replaced; line 675 is the `confirm()` sanction to delete. Read before rewriting the table.
- `../dartclaw-public/dev/design-system/DESIGN.md#elevation--depth` – where the stacking-order paragraph lands; the glass tier already names modals, command palettes and toasts but says nothing about order.
- `../dartclaw-public/dev/design-system/DESIGN.md#dos-and-donts` – "Don't rely on color alone for state" — the canon rule the toast currently breaks. Match its phrasing style for the native-dialog ban.
- `../dartclaw-public/dev/design-system/DESIGN.md#native-selects` – the prohibition style FR5 says to mirror ("Safari limitation … use an accessible custom listbox instead of over-styling `<select>`").
- `docs/specs/0.22.1/audit-ui-polish-2026-07-25.md#a-canon-changes--the-design-system-itself-is-the-defect-40` – the four `global` findings this story closes: dialog primitive, feedback table, toast severity, z-index scale. Read for the measured evidence behind each.
- `docs/specs/0.22/prd.md#decisions-log` – the "Keep `window.confirm`" row this story reverses, and its recorded blocker.
- `../dartclaw-public/dev/guidelines/VISUAL-VALIDATION-WORKFLOW.md` – both-theme desktop + 768px validation procedure.


## Acceptance Scenarios

- [ ] **S01 [OC01] [TI02,TI03,TI07] A destructive confirmation renders from canonical classes alone**
  - **Given** `showcase.html` is open in the `visual` profile's browser with only `tokens.css`, `components.css` and `icons.css` loaded (no `app.css`)
  - **When** the Dialogs panel's confirm demo is opened via `showModal()`
  - **Then** a centred frame renders with the `::backdrop` scrim (blurred, `--bg-pit`-tinted), a `.dialog-header` title, a `.dialog-body` naming the object being destroyed, and a `.dialog-footer > .dialog-actions` row holding a `.btn.btn-ghost` cancel and a `.btn.btn-danger-fill` confirm — with no class from `app.css` on any element

- [ ] **S02 [OC01] [TI02,TI07] The dialog hosts real form controls and scrolls its body, not its chrome**
  - **Given** the showcase's `.dialog.dialog--md` demo containing the canonical `.form-field` controls and a `.tabs` strip added by S03
  - **When** the demo is opened at a viewport short enough that the fields overflow
  - **Then** `.dialog-body` scrolls while `.dialog-header` and `.dialog-footer` stay pinned, and every control renders at its canonical size with no `.task-dialog`-prefixed override in play

- [ ] **S03 [OC01] [TI02] A dialog with no width modifier still renders at a bounded width**
  - **Given** markup `<dialog class="dialog card card-glass">` carrying neither `.dialog--sm` nor `.dialog--md`
  - **When** it is opened at 1440px and again at 768px
  - **Then** it renders at the `--md` default width clamped by `min(92vw, …)` at both widths — it neither collapses to content width nor spans the full viewport

- [ ] **S04 [OC02] [TI06] The feedback decision table names five mechanisms and bans the native ones**
  - **Given** DESIGN.md § Feedback after the rewrite
  - **When** the decision table is read
  - **Then** it has exactly five rows — persistent problem → banner, transient success/error → toast, destructive confirmation → `.dialog--confirm`, row-scoped destructive → `.delete-confirm-bar`, structured input → `.dialog` with real form controls — no cell names `confirm()` as a mechanism, and a prohibition line states that native `alert()` / `confirm()` / `prompt()` are banned

- [ ] **S05 [OC03] [TI05,TI07] Toast severity survives colour removal**
  - **Given** the showcase's four toast demos raised together and the screenshot converted to greyscale
  - **When** the four toasts are compared
  - **Then** each still reads as a different severity because success shows `circle-check`, error `circle-x`, warning `triangle-alert` and info `info` — and a `.toast` carrying an unrecognised variant class (what `sanitizeClassToken` produces for `showToast('bogus', …)`) shows the info glyph rather than an empty box

- [ ] **S06 [OC04] [TI01,TI06] A toast raised over an open modal is documented as invisible, not silently broken**
  - **Given** `.toast-container` sitting at the highest `--z-*` tier and a `<dialog>` opened with `showModal()`
  - **When** a toast is raised while that dialog is open
  - **Then** the toast is still hidden — the dialog is in the browser top layer, which no z-index can beat — and DESIGN.md § Elevation & Depth states that rule together with the required workaround: re-parent the toast container into the open `<dialog>`, or report errors with an inline `.form-error`


## Structural Criteria

- [ ] `bash dev/tools/fitness/check_design_system_sync.sh` exits 0 — served `tokens.css` and `design-system.css` are byte-identical to canon with regenerated sha256 provenance headers.
- [ ] `packages/dartclaw_server/lib/src/generated/embedded_assets.g.dart` is deliberately left stale — `git status --porcelain packages/dartclaw_server/lib/src/generated/` prints nothing for this story. Regeneration is S14's single release-close action; see Constraints & Gotchas.
- [ ] Every mechanism named in the new § Feedback decision table resolves to a class defined in `dev/design-system/components.css` — no repeat of the § Native selects defect (documented component, zero backing CSS).
- [ ] The story's diff introduces zero new `var(--text-sm)` occurrences in `dev/design-system/components.css`.
- [ ] No file under `packages/dartclaw_server/lib/src/static/` other than `tokens.css` and `design-system.css` is modified: `app.css`, `controllers/` and all templates are untouched, and both production dialogs (`new-task-dialog`, `add-project-dialog`) still render exactly as before.
- [ ] Any transition or animation added to `.dialog` is neutralised by the existing `@media (prefers-reduced-motion: reduce)` block in `components.css`.
- [ ] `dart format --line-length=120 --output=none --set-exit-if-changed .`, `dart analyze --fatal-infos` and `bash dev/tools/fitness/run_all.sh` are clean.


## Scope & Boundaries

### Work Areas
- `dev/design-system/tokens.css` — the `--z-*` stacking ladder
- `dev/design-system/components.css` — dialog family, row-scoped confirm bar, toast severity glyph, and adoption of the `--z-*` tokens by canon's own stacking rules
- `dev/design-system/DESIGN.md` — § Feedback rewrite (replacing § Banners and toasts), dialog anatomy in § Components, stacking paragraph in § Elevation & Depth, `components.dialog` frontmatter entry
- `dev/design-system/showcase.html` — Dialogs panel and the updated Toast Notifications panel
- `packages/dartclaw_server/lib/src/static/tokens.css` + `design-system.css` — re-synced served copies with regenerated provenance headers

### What We're NOT Doing
- Routing the app's nine native-dialog call sites through `confirmDialog()` -- S06 owns the controller work; S04 only removes the canon sanction that blocked it.
- Repointing `task_form.dart` / `project_form.dart` at `.dialog` and deleting `app.css`'s `.task-dialog` -- S05's mechanical swap; S04 leaves both production dialogs rendering unchanged, including the `.task-dialog`-scoped control/tab sizing overrides at `app.css` 2284-2325 / 3822-3825, which stay app-side until S05 reconciles them.
- Migrating `app.css`'s seven ad-hoc `z-index` values (including `.restart-overlay` at 9999) onto the new ladder -- app-side adoption is **S07 TI08's**, which the plan's S07 scope names with the seven line numbers verbatim; S04 ships and documents the ladder only. (S05 does not claim it — do not route it there.)
- Defining any button variant -- S03 (this story's dependency) already promotes `.btn-danger-fill` into canon "as the filled destructive variant S04's `.dialog--confirm` consumes"; S04 composes it and adds no button rule of its own. The audit contradicts itself here (`:125` prescribes `btn-danger-fill` in the confirm dialog, `:181` prescribes folding it onto `.btn-danger`); the reconciliation is that the *class* is canon (S03) and the *app.css copy* is what gets deleted (S05).
- Resolving DESIGN.md § Source-of-truth scope's byte-identity contradiction -- S14 owns the end-to-end DESIGN.md reconciliation.
- Regenerating `packages/dartclaw_server/lib/src/generated/embedded_assets.g.dart` -- `plan.json#executionNotes` reserves the single regeneration for S14; this story re-syncs the served CSS and leaves the generated bundle stale, exactly as S01 does.


## Architecture Decision

**Approach**: Promote the app's shipped `.task-dialog` recipe into canon as `.dialog` unchanged in behaviour, and carry toast severity with a variant-driven `::before` mask — so the whole story is canon CSS plus documentation, with zero JS, template or `app.css` edits.
**Why this over alternatives**: emitting `<span class="icon icon-circle-check">` from `shared.js#showToast` (the audit's suggestion) would also work, but it drops an app-side JS change into a P1 canon story and risks a double glyph once S05/S06 touch the same code; the pseudo-element gives the same non-colour severity channel with no consumer change at all.


## Technical Overview

_(Empty — the picture is fully carried by the Architecture Decision, Code Patterns and per-task descriptions.)_


## Code Patterns & External References

```
# type | path#anchor or url                                                        | why needed (intent)
file   | packages/dartclaw_server/lib/src/static/app.css#.task-dialog              | The proven recipe to promote (~lines 1943-2060): width clamp, ::backdrop scrim, header/body/footer/actions, 768px override
file   | packages/dartclaw_server/lib/src/static/app.css#.delete-confirm-bar       | Row-scoped destructive pattern the decision table names — promote its six declarations plus the .confirm-msg child
file   | dev/design-system/components.css#.toast                                   | Current toast rules: variants change only border-left-color — the defect being fixed
file   | dev/design-system/icons.css#.icon                                          | mask-image mechanism plus the --icon-circle-check / --icon-circle-x / --icon-triangle-alert / --icon-info data URIs (all four already exist)
file   | packages/dartclaw_server/lib/src/templates/task_form.dart#new-task-dialog  | Consumer markup the canonical classes must absorb in S05 without behaviour change — note the tab strip inside the dialog
file   | dev/design-system/components.css#toast-container                          | The 100 literal at line 1450, plus 20/15 at lines 115/134 — the three canon z-index literals the ladder replaces
file   | dev/tools/fitness/check_design_system_sync.sh                             | The drift gate: sha256 on line 2 of the served file, byte-identical body from line 3
wire   | docs/wireframes/guard-editor.html                                          | Guard-editor surface whose unconfirmed Delete S06 routes through .dialog--confirm — check the frame can host its field list
```


## Constraints & Gotchas

- **Critical**: `showModal()` promotes a `<dialog>` into the browser top layer, which beats every z-index — the `--z-*` ladder does not fix a toast raised from inside a modal. Must handle by: documenting the re-parent-or-inline-`.form-error` rule in § Elevation & Depth (TI06) rather than by raising `--z-toast`.
- **Constraint**: canon-first. Every canon edit re-syncs the served copy with a regenerated two-line `/* Synced from … sha256: … */` header, and stops there. Do **not** run `dart run dev/tools/embed_assets.dart` here: the served CSS is embedded into `embedded_assets.g.dart`, so that file goes stale and the AOT binary keeps serving the old stylesheet even with the drift check green — which is the intended state until S14. `plan.json#executionNotes` reserves the single regeneration for S14 because running it per story rewrites a large generated file that every later story re-drifts and lands that diff into the parallel P3 branches; S01 carries the identical instruction. Leaving it stale costs this story nothing: `showcase.html` links canon directly, and the `visual` profile runs from the source checkout, where `asset_resolver.dart` resolves `staticDir` to `lib/src/static/` on disk and falls back to the embedded bundle only when no source tree is present.
- **Avoid**: documenting a mechanism DESIGN.md does not back with CSS — that is exactly the § Native selects defect this release is fixing. Instead: every class the new decision table names exists in `dev/design-system/components.css` before the table ships.
- **Constraint**: `.dialog` must host the `.form-*` controls and the `.tabs` / `.tab` component S03 added (the production task dialog carries a tab strip), because S06's two `prompt()`-replacement editors become forms inside it.
- **Avoid**: a `.toast::before` rule with no default mask — `sanitizeClassToken` passes any string through, so `showToast('bogus', …)` yields `class="toast toast-bogus"`. Instead: put the info glyph on the base `.toast::before` and let the four variants override it.
- **Avoid**: raw palette hex in `components.css` (canon Do's and Don'ts) — derive the scrim and confirm tints from tokens with `color-mix()`.
- **Constraint**: no new `var(--text-sm)` usages and no hand-derived type tiers in this story's canon rules (the two shared decisions inlined above; the same rule S03 applied) — component rules otherwise carry layout, colour and state only, with type tiers coming from the S02 composite classes in markup/showcase (e.g. `.t-heading` on the dialog title, not a `font-size`/`font-weight` copy of `app.css#.task-dialog-header h2` into `.dialog-header`). **Carve-out**: `.confirm-msg` keeps one font-size declaration, promoted as `var(--text-base)` in place of `app.css`'s aliased `var(--text-sm)`, because its markup is controller-built (`dc_scheduling_controller.js`) and can take no composite class until S06's controller work — pixel-identical, and rendering is unaffected while both copies load (`app.css` loads after `design-system.css`, so the identical-specificity app rule wins until S05 deletes it).


## Implementation Plan

### Implementation Tasks

- [ ] **TI01** Canon carries a named stacking ladder and its own rules consume it
  - `dev/design-system/tokens.css` gains `--z-base`, `--z-sticky`, `--z-scrim`, `--z-sidebar`, `--z-dropdown`, `--z-overlay`, `--z-toast` in ascending order (the six tiers the audit names plus `--z-scrim`, which canon's mobile sidebar scrim actually needs between sticky and sidebar); `--z-toast` is the highest tier. **Four** canon literals convert, not three: the pre-existing `20` / `15` / `100` (lines 115 / 134 / 1450 in the pre-S01 file — their positions move under S01–S03, so locate them by value) stop hardcoding and reference the tokens, **and `.tabs--sticky`'s `z-index: 10` becomes `var(--z-sticky)`**. That fourth literal is S03's deliberate handoff, not a defect: S03's L3 decision ships `.tabs--sticky` with the literal because `var(--z-sticky)` does not exist while S03 runs, and this task is the named converter (`canon-hoist-manifest.md` row 10 — *"S03 authors, S04 defines the token"*). Component-local micro-stacking stays literal (the film-grain `z-index: -1` and `.pipeline-node`'s `z-index: 1` at line 2161 — both stack within their own component, not against the app layers).
  - **Read first**: S03's `## Implementation Observations` in `docs/specs/0.22.1/fis/s03-canon-form-control-tab-state-primitives.md` records the `.tabs--sticky` literal and the L3 reasoning addressed to this story's executor. Read it before starting — if that record is absent, S03 did not close its handoff; check `rg -n 'tabs--sticky' dev/design-system/components.css` for the rule anyway and report the missing record rather than assuming the conversion is out of scope.
  - **Verify**: `rg -n '^\s*--z-(base|sticky|scrim|sidebar|dropdown|overlay|toast):' dev/design-system/tokens.css` lists all seven, and `rg -n 'z-index:\s*(1[0-9]|[2-9][0-9]|[0-9]{3,})' dev/design-system/components.css` returns no matches (once S03 has landed it returns **four** lines — `.tabs--sticky`'s `10` plus the `20` / `15` / `100` this task also converts; it returns only the three at the pre-S03 revision, so a run that shows three means S03's `.tabs--sticky` rule is missing and TI06 of S03 did not land); `awk '/^\.tabs--sticky/,/}/' dev/design-system/components.css | rg -n 'z-index: var\(--z-sticky\)'` returns the converted declaration

- [ ] **TI02** Canon ships the `.dialog` family, promoted from `.task-dialog`
  - New numbered component category in `dev/design-system/components.css` (added to the category list in the file header): `.dialog` frame, `.dialog::backdrop` scrim, `.dialog-header` / `-body` / `-footer` / `-actions`, and the `.dialog--sm` / `.dialog--md` width ladder. Carry over the proven behaviour from `app.css#.task-dialog`: `padding: 0`, `margin: auto`, scrolling body with pinned header/footer, and a viewport clamp. `.dialog--sm` is `min(92vw, 480px)`; `.dialog--md` and bare `.dialog` are `min(92vw, 680px)`, so an unmodified dialog is never unbounded.
  - **Verify**: `rg -n '^\.dialog(::backdrop|-header|-body|-footer|-actions|--sm|--md)?\s*[,{]' dev/design-system/components.css` lists the frame, backdrop, four sub-elements and both width modifiers; opening the showcase demos at 1440px and 768px computes 480px or the 92vw clamp for `--sm`, and 680px or the 92vw clamp for `--md` and bare `.dialog`

- [ ] **TI03** `.dialog--confirm` renders a destructive confirmation from existing canon buttons
  - Variant on TI02's frame, using the `--sm` 480px width contract: leading `.icon` slot beside the message and a `.dialog-actions` row composing `.btn.btn-ghost` (cancel) with `.btn.btn-danger-fill` (confirm), both already in canon — S03 ships `.btn-danger-fill` for exactly this consumer. This task adds no button rule; if `.btn-danger-fill` is absent from `components.css`, S03 is incomplete — stop rather than defining it here.
  - **Verify**: `rg -n '\.dialog--confirm' dev/design-system/components.css` returns the variant rules, its computed width matches `.dialog--sm`, `rg -n '^\.btn-danger-fill' dev/design-system/components.css` returns S03's rule (not one added by this story), and `git diff dev/design-system/components.css` shows no added `.btn`-family rule

- [ ] **TI04** The row-scoped destructive pattern is canon, not app-private
  - Promote `app.css#.delete-confirm-bar` and its `.confirm-msg` child into `components.css` beside the dialog family, unchanged in appearance (one declaration swap per the Constraints bullet), so the decision table's row-scoped row (TI06) has backing CSS. The app-local copy stays until S05 deletes it.
  - **Verify**: `rg -n '\.delete-confirm-bar' dev/design-system/components.css` returns the rules; the scheduling delete row still renders identically in the `visual` profile (the app now loads two definitions of the class — canon's in `design-system.css` and the original in `app.css` — identical except `.confirm-msg` carrying `var(--text-base)` for `app.css`'s aliased `var(--text-sm)`, with the later-loading app copy winning until S05 deletes it)

- [ ] **TI05** Toast severity reads without colour
  - `.toast::before` becomes a leading mask-image glyph sized like `.icon`, defaulting to `var(--icon-info)`; `.toast-success` / `-error` / `-warning` / `-info` each set both `border-left-color` and their glyph (`--icon-circle-check`, `--icon-circle-x`, `--icon-triangle-alert`, `--icon-info`) per the DESIGN.md § Icons vocabulary. CSS-only — `shared.js#showToast` and the existing `<span>` + `.toast-dismiss` markup are not touched.
  - **Verify**: `rg -n '\.toast(-success|-error|-warning|-info)?::before' dev/design-system/components.css` shows the base rule plus four variant overrides; `rg -n -e '--icon-(circle-check|circle-x|triangle-alert|info)' dev/design-system/components.css` lists the base `--icon-info` default plus the four variant masks (currently zero matches for this group); a greyscale screenshot of the four showcase toasts shows four distinct glyph shapes

- [ ] **TI06** DESIGN.md documents the dialog, the five-row feedback table and the stacking order
  - Rename `### Banners and toasts` to `### Feedback` (it now covers dialogs) and replace the four-row table with five rows (per FR5, the two transient cases merge into one row): persistent problem → `.banner-error/-warning/-info`; transient success / error → `.toast-success` / `.toast-error`; destructive confirmation → `.dialog.dialog--confirm`; row-scoped destructive → `.delete-confirm-bar`; structured input → `.dialog` with real form controls. Delete the `confirm()` mechanism cell and add a prohibition line in the § Native selects style stating native `alert()` / `confirm()` / `prompt()` are banned. Add dialog anatomy under § Components, a stacking-order paragraph under § Elevation & Depth naming the `--z-*` tiers and the `showModal()` top-layer exception with its workaround, and a `dialog:` entry in the frontmatter `components:` map alongside `card-glass`.
  - **Verify**: ``rg -nF '`confirm()` dialog' dev/design-system/DESIGN.md`` returns no matches (it currently returns line 675); `rg -n 'are banned' dev/design-system/DESIGN.md` returns the prohibition line; `rg -n '^### Feedback' dev/design-system/DESIGN.md` returns the renamed heading; `rg -n 'top layer' dev/design-system/DESIGN.md` returns the stacking paragraph; `rg -n '^  dialog:' dev/design-system/DESIGN.md` returns the frontmatter `components:` entry (currently no match)

- [ ] **TI07** showcase.html demonstrates every primitive this story adds
  - A Dialogs panel with two live demos — a `.dialog--confirm` and a `.dialog.dialog--md` hosting S03's form controls and tab strip — a static `.delete-confirm-bar` row demo (TI04's canon copy is otherwise never render-proven without `app.css`), plus the updated Toast Notifications panel showing all four severity glyphs. Showcase loads only `tokens.css` / `components.css` / `icons.css`, so anything that renders here is proven canon-sufficient for the frame, scrim, width ladder, confirm bar and severity glyphs. (The `.task-dialog`-scoped control/tab sizing overrides at `app.css` 2284-2325 and 3822-3825 have no canon counterpart — they are S05 reconciliation fallout; showcase proves the canon half only.)
  - **Verify**: `rg -n 'class="dialog' dev/design-system/showcase.html` returns both demos; `rg -n 'delete-confirm-bar' dev/design-system/showcase.html` returns the row demo (currently no match); opening `showcase.html` and triggering each demo renders them correctly in dark and light theme at 1440px and 768px

- [ ] **TI08** The served CSS carries the new canon
  - Copy canon `tokens.css` → `packages/dartclaw_server/lib/src/static/tokens.css` and canon `components.css` → `packages/dartclaw_server/lib/src/static/design-system.css`, each prefixed by the regenerated two-line `/* Synced from dev/design-system/<file> on <date>.\n   sha256: <hash> */` header. `icons.css` is unchanged by this story and must not be re-synced gratuitously. Stop at the re-sync — the embedded bundle stays stale for S14 (Constraints & Gotchas).
  - **Verify**: `bash dev/tools/fitness/check_design_system_sync.sh` exits 0; `git status --short packages/dartclaw_server/lib/src/static/` lists only `tokens.css` and `design-system.css`; `git status --porcelain packages/dartclaw_server/lib/src/generated/` prints nothing (the generator was not run); `git diff -U0 "$(git merge-base main HEAD)" -- dev/design-system/components.css | grep '^+' | grep 'var(--text-sm)'` prints nothing (diff-scoped — pre-existing usages like `.toast-dismiss` remain until S07)

### Testing Strategy
_(Empty — per-task Verify lines plus the showcase-rendered Acceptance Scenarios are the full test approach; this story adds no Dart code.)_

### Validation

- Visual validation per `dev/guidelines/VISUAL-VALIDATION-WORKFLOW.md`: `showcase.html` plus the surfaces carrying the two production dialogs (`/tasks`, `/projects`) and any toast-raising surface, in both themes at 1440px and 768px, diffed against the audit's 92-screenshot baseline. The production dialogs must be pixel-unchanged — this story adds canon classes, it does not repoint markup.

### Execution Contract

- TI01 before TI02 (the ladder is settled before component work begins — note the dialog frame itself takes no `z-index`: `showModal()`'s top layer handles its stacking, per the Critical gotcha above); TI02 before TI03/TI07; TI04 and TI05 before TI06 (the table may not name a class that does not yet exist); TI08 last and after every canon edit.


## Final Validation Checklist

- [ ] `rg -c 'window\.(alert|confirm|prompt)|[^.\w](alert|confirm|prompt)\(' packages/dartclaw_server/lib/src/static/controllers/` still reports the same nine call sites across `dc_shell_controller.js` (5), `dc_settings_controller.js` (2), `dc_scheduling_controller.js` (1) and `dc_projects_controller.js` (1) — S04 must not change controller code, and S06 is what drives this to zero.


## Implementation Observations

#### DECISION NOTE: s04.dialog-width-tier-contract

Decision-Key: s04.dialog-width-tier-contract
Altitude: FIS
Affected surface: Canon `.dialog` width ladder and `.dialog--confirm`
Decision: `.dialog--sm` is `min(92vw, 480px)`; `.dialog--md` and bare `.dialog` are `min(92vw, 680px)`; confirmations use the small tier.
Rationale: Preserves the proven 680px form-dialog measure while giving confirmations a compact, explicit tier.
Evidence: User ratified the recommended preflight option on 2026-07-26.
