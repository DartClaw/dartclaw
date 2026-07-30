# Canon: dialog primitive and feedback decision-table rewrite

**Plan**: dev/bundle/docs/specs/0.22.1/plan.json
**Story-ID**: S04

## Feature Overview and Goal

**Intent**: DESIGN.md currently *sanctions* `confirm()` and ships no dialog frame at all, so the app was forced to invent a private modal and every destructive action in the product hands its irreversible decision to an unthemeable OS box — this story removes that sanction and puts a real dialog in canon, which is the single upstream blocker 0.22 recorded three times.

**Expected Outcomes**

- [OC01] A destructive confirmation or a structured-input modal can be built entirely from canonical classes — every frame composes `dialog` + its applicable modifier + `card card-glass`; scrim, header/body/footer/actions, width tier and confirm variant all live in `dev/design-system/` and are demonstrated in `showcase.html`.
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
> S04 ships the canonical `.dialog` family (promoted from the app's proven private `.task-dialog`) with `.dialog--confirm` and an explicit z-index scale. S05 repoints existing markup at it and deletes the private recipe. S06 ships exactly one `confirmDialog({title, body, confirmLabel, danger})` in `shared.js` plus one `htmx:confirm` listener in `dc_shell_controller.js`: every current and future modal confirmation and every `hx-confirm` gate routes through those two. Row-scoped destructive actions use the canonical inline `.delete-confirm-bar`, never a modal; this includes both scheduled-task and scheduled-job row deletes. No story adds a second modal confirmation implementation.

### From `docs/specs/0.22.1/plan.json` – Shared Decision: "Composite type-class vocabulary"
<!-- source: docs/specs/0.22.1/plan.json#sharedDecisions -->
<!-- extracted: e18cf85c5939ea2dec5f06cc5744dee27620c640 -->
> S02 fixes the seven composite class names, each binding font-size + weight + line-height + letter-spacing: `.t-caption`, `.t-body`, `.t-label`, `.t-heading`, `.t-page-title`, `.t-display`, `.t-metric`. All consumers apply these classes; raw `--text-*` tokens are for one-offs only, and no consumer hand-derives a tier from four separate properties.

### From `docs/specs/0.22.1/plan.json` – Shared Decision: "`--text-sm` retirement protocol"
<!-- source: docs/specs/0.22.1/plan.json#sharedDecisions -->
<!-- extracted: e18cf85c5939ea2dec5f06cc5744dee27620c640 -->
> S02 aliases `--text-sm` to `--text-base`, defines the seven composite classes and migrates every canon `components.css` consumer while the P1 type family is open. S07 later migrates app-side and non-drift-checked demo usages, then uses its one serialized token-only canon exception to delete the alias from `tokens.css`, sync served `tokens.css`, regenerate embedded assets and close parity green. It may not edit `components.css`, `icons.css` or any other canon family; no other story introduces `--text-sm`.


## Deeper Context

- `../dartclaw-public/dev/design-system/DESIGN.md#banners-and-toasts` – the 4-row table being replaced; line 675 is the `confirm()` sanction to delete. Read before rewriting the table.
- `../dartclaw-public/dev/design-system/DESIGN.md#elevation--depth` – where the stacking-order paragraph lands; the glass tier already names modals, command palettes and toasts but says nothing about order.
- `../dartclaw-public/dev/design-system/DESIGN.md#dos-and-donts` – "Don't rely on color alone for state" — the canon rule the toast currently breaks. Match its phrasing style for the native-dialog ban.
- `../dartclaw-public/dev/design-system/DESIGN.md#native-selects` – the prohibition style FR5 says to mirror ("Safari limitation … use an accessible custom listbox instead of over-styling `<select>`").
- `docs/specs/0.22.1/audit-ui-polish-2026-07-25.md#a-canon-changes--the-design-system-itself-is-the-defect-40` – the four `global` findings this story closes: dialog primitive, feedback table, toast severity, z-index scale. Read for the measured evidence behind each.
- `docs/specs/0.22/prd.md#decisions-log` – the "Keep `window.confirm`" row this story reverses, and its recorded blocker.
- `../dartclaw-public/dev/guidelines/VISUAL-VALIDATION-WORKFLOW.md` – both-theme desktop + 768px validation procedure.


## Acceptance Scenarios

- [x] **S01 [OC01] [TI02,TI03,TI07] A destructive confirmation renders from canonical classes alone**
  - **Given** `showcase.html` is open in the `visual` profile's browser with only `tokens.css`, `components.css` and `icons.css` loaded (no `app.css`)
  - **When** the Dialogs panel's confirm demo is opened via `showModal()`
  - **Then** a centred `<dialog class="dialog dialog--confirm card card-glass">` frame renders with the `::backdrop` scrim (blurred, `--bg-pit`-tinted), a `.dialog-header` title, a `.dialog-body` naming the object being destroyed, and a `.dialog-footer > .dialog-actions` row holding a `.btn.btn-ghost` cancel and a `.btn.btn-danger-fill` confirm — with no class from `app.css` on any element

- [x] **S02 [OC01] [TI02,TI07] The dialog hosts real form controls and scrolls its body, not its chrome**
  - **Given** the showcase's `<dialog class="dialog dialog--md card card-glass">` demo containing the canonical `.form-field` controls and a `.tabs` strip added by S03
  - **When** the demo is opened at a viewport short enough that the fields overflow
  - **Then** `.dialog-body` scrolls while `.dialog-header` and `.dialog-footer` stay pinned, `.dialog .tabs` has no bottom border, and every control renders at its canonical size with no `.task-dialog`-prefixed override in play

- [x] **S03 [OC01] [TI02] A dialog with no width modifier still renders at a bounded width**
  - **Given** markup `<dialog class="dialog card card-glass">` carrying no width modifier, where bare `.dialog` is the applicable default-width composition
  - **When** it is opened at 1440px and again at 768px
  - **Then** it renders at the `--md` default width clamped by `min(92vw, …)` at both widths — it neither collapses to content width nor spans the full viewport

- [x] **S04 [OC02] [TI06] The feedback decision table names five mechanisms and bans the native ones**
  - **Given** DESIGN.md § Feedback after the rewrite
  - **When** the decision table is read
  - **Then** it has exactly five rows — persistent problem → banner, transient success/error → toast, destructive confirmation → `.dialog--confirm`, row-scoped destructive → `.delete-confirm-bar`, structured input → `.dialog` with real form controls — no cell names `confirm()` as a mechanism, and a prohibition line states that native `alert()` / `confirm()` / `prompt()` are banned

- [x] **S05 [OC03] [TI05,TI07] Toast severity survives colour removal**
  - **Given** the showcase's four toast demos raised together and the screenshot converted to greyscale
  - **When** the four toasts are compared
  - **Then** each still reads as a different severity because success shows `circle-check`, error `circle-x`, warning `triangle-alert` and info `info` — and a `.toast` carrying an unrecognised variant class (what `sanitizeClassToken` produces for `showToast('bogus', …)`) shows the info glyph rather than an empty box

- [x] **S06 [OC04] [TI01,TI06] A toast raised over an open modal is documented as invisible, not silently broken**
  - **Given** `.toast-container` sitting at the highest `--z-*` tier and a `<dialog>` opened with `showModal()`
  - **When** a toast is raised while that dialog is open
  - **Then** the toast is still hidden — the dialog is in the browser top layer, which no z-index can beat — and DESIGN.md § Elevation & Depth states that rule together with the required workaround: re-parent the toast container into the open `<dialog>`, or report errors with an inline `.form-error`


## Structural Criteria

- [x] `bash dev/tools/fitness/check_design_system_sync.sh` exits 0 — served `tokens.css` and `design-system.css` are byte-identical to canon with regenerated sha256 provenance headers.
- [x] After the final served-CSS sync, `dart run dev/tools/embed_assets.dart` refreshes the tracked embedded bundle and `dart test packages/dartclaw_server/test/generated/embedded_assets_test.dart` passes; no generated test is allowed red.
- [x] Every mechanism named in the new § Feedback decision table resolves to a class defined in `dev/design-system/components.css` — no repeat of the § Native selects defect (documented component, zero backing CSS).
- [x] Every dialog frame demonstrated by this story composes `dialog` + its applicable modifier + `card card-glass`; the confirm specimen is exactly `dialog dialog--confirm card card-glass`, and canon contains `.dialog .tabs { border-bottom: 0; }` so tabbed dialogs do not need an app-local suppression.
- [x] `dev/design-system/components.css` remains at zero `var(--text-sm)` occurrences, preserving S02's closed canon-type handoff.
- [x] No file under `packages/dartclaw_server/lib/src/static/` other than `tokens.css` and `design-system.css` is modified: `app.css`, `controllers/` and all templates are untouched, and both production dialogs (`new-task-dialog`, `add-project-dialog`) still render exactly as before.
- [x] Any transition or animation added to `.dialog` is neutralised by the existing `@media (prefers-reduced-motion: reduce)` block in `components.css`.
- [x] `dart format --line-length=120 --output=none --set-exit-if-changed .`, `dart analyze --fatal-infos` and `bash dev/tools/fitness/run_all.sh` are clean.


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
- Hand-editing `packages/dartclaw_server/lib/src/generated/embedded_assets.g.dart` -- this story regenerates it only through `dart run dev/tools/embed_assets.dart` after its final served-CSS change, then closes with generated parity green.


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
- **Constraint**: canon-first. Every canon edit re-syncs the served copy with a regenerated two-line `/* Synced from … sha256: … */` header. Because this Workflow run is serialized, after the final served-CSS change run `dart run dev/tools/embed_assets.dart` before objective verification, then run `dart test packages/dartclaw_server/test/generated/embedded_assets_test.dart`; both it and the full declared gate set must be green. Re-run after remediation that changes an embed root. Never hand-edit the generated file.
- **Avoid**: documenting a mechanism DESIGN.md does not back with CSS — that is exactly the § Native selects defect this release is fixing. Instead: every class the new decision table names exists in `dev/design-system/components.css` before the table ships.
- **Constraint**: `.dialog` must host the `.form-*` controls and the `.tabs` / `.tab` component S03 added (the production task dialog carries a tab strip), because S06's two `prompt()`-replacement editors become forms inside it.
- **Avoid**: a `.toast::before` rule with no default mask — `sanitizeClassToken` passes any string through, so `showToast('bogus', …)` yields `class="toast toast-bogus"`. Instead: put the info glyph on the base `.toast::before` and let the four variants override it.
- **Avoid**: raw palette hex in `components.css` (canon Do's and Don'ts) — derive the scrim and confirm tints from tokens with `color-mix()`.
- **Constraint**: no new `var(--text-sm)` usages and no hand-derived type tiers in this story's canon rules (the two shared decisions inlined above; the same rule S03 applied) — component rules otherwise carry layout, colour and state only, with type tiers coming from the S02 composite classes in markup/showcase (e.g. `.t-heading` on the dialog title, not a `font-size`/`font-weight` copy of `app.css#.task-dialog-header h2` into `.dialog-header`). **Carve-out**: `.confirm-msg` keeps one font-size declaration, promoted as `var(--text-base)` in place of `app.css`'s aliased `var(--text-sm)`, because its markup is controller-built (`dc_scheduling_controller.js`) and can take no composite class until S06's controller work — pixel-identical, and rendering is unaffected while both copies load (`app.css` loads after `design-system.css`, so the identical-specificity app rule wins until S05 deletes it).


## Implementation Plan

### Implementation Tasks

Before TI01, capture the story-start visual targets named under Validation in both themes at 1440×900 and 768px. Also snapshot the accumulating no-commit checkout exactly as S04 receives it; every Git-style own-delta assertion below compares to this entry, never to `main`, `HEAD` or a merge base:

```sh
BASE=.agent_temp/0.22.1-s04-entry
rm -rf "$BASE"
mkdir -p "$BASE/dev" "$BASE/packages/dartclaw_server/lib/src"
cp -R dev/design-system "$BASE/dev/"
cp -R packages/dartclaw_server/lib/src/static "$BASE/packages/dartclaw_server/lib/src/"
```

- [x] **TI01** Canon carries a named stacking ladder and its own rules consume it
  - `dev/design-system/tokens.css` gains `--z-base`, `--z-sticky`, `--z-scrim`, `--z-sidebar`, `--z-dropdown`, `--z-overlay`, `--z-toast` in ascending order (the six tiers the audit names plus `--z-scrim`, which canon's mobile sidebar scrim actually needs between sticky and sidebar); `--z-toast` is the highest tier. **Five** canon literals convert, not three: the pre-existing `20` / `15` / `100` (lines 115 / 134 / 1450 in the pre-S01 file — their positions move under S01–S03, so locate them by value) stop hardcoding and reference the tokens, `.tabs--sticky`'s `z-index: 10` becomes `var(--z-sticky)`, **and S01's `.skip-link` handoff converts temporary `z-index: 30` to `var(--z-overlay)`**. The tab literal is S03's deliberate handoff; the skip-link literal is S01's deliberate handoff after proving keyboard focus above current chrome. Read both records rather than treating either as a defect. Component-local micro-stacking stays literal (the film-grain `z-index: -1` and `.pipeline-node`'s `z-index: 1` at line 2161 — both stack within their own component, not against the app layers).
  - **Read first**: S03's and S01's `## Implementation Observations` in their canonical FIS files record the `.tabs--sticky` and `.skip-link` literals addressed to this story's executor. Read both before starting; if a record is absent, inspect the corresponding rule anyway and report the missing handoff rather than assuming the conversion is out of scope.
  - **Verify**: `rg -n '^\s*--z-(base|sticky|scrim|sidebar|dropdown|overlay|toast):' dev/design-system/tokens.css` lists all seven, and `rg -n 'z-index:\s*(1[0-9]|[2-9][0-9]|[0-9]{3,})' dev/design-system/components.css` returns no matches (once S01–S03 have landed it returns **five** lines — `.tabs--sticky`'s `10`, `.skip-link`'s `30`, and the `20` / `15` / `100` this task also converts; fewer means an upstream handoff is missing); `awk '/^\.tabs--sticky/,/}/' dev/design-system/components.css | rg -n 'z-index: var\(--z-sticky\)'` and `awk '/^\.skip-link/,/}/' dev/design-system/components.css | rg -n 'z-index: var\(--z-overlay\)'` each return the converted declaration

- [x] **TI02** Canon ships the `.dialog` family, promoted from `.task-dialog`
  - New numbered component category in `dev/design-system/components.css` (added to the category list in the file header): `.dialog` frame, `.dialog::backdrop` scrim, `.dialog-header` / `-body` / `-footer` / `-actions`, and the `.dialog--sm` / `.dialog--md` width ladder. Carry over the proven behaviour from `app.css#.task-dialog`: `padding: 0`, `margin: auto`, scrolling body with pinned header/footer, and a viewport clamp. `.dialog--sm` is `min(92vw, 480px)`; `.dialog--md` and bare `.dialog` are `min(92vw, 680px)`, so an unmodified dialog is never unbounded. The canonical composition is one frame shape: every `<dialog>` uses `dialog` + its applicable modifier + `card card-glass`; bare `.dialog` is the default-width case. Add `.dialog .tabs { border-bottom: 0; }` so a tab strip inside the frame does not double the dialog chrome; S05 deletes the app-local suppression it replaces.
  - **Verify**: `rg -n '^\.dialog(::backdrop|-header|-body|-footer|-actions|--sm|--md)?\s*[,{]' dev/design-system/components.css` lists the frame, backdrop, four sub-elements and both width modifiers; `rg -nU --multiline-dotall '^\.dialog \.tabs\s*\{[^}]*border-bottom:\s*0' dev/design-system/components.css` matches the composition rule; opening the showcase demos at 1440px and 768px computes 480px or the 92vw clamp for `--sm`, and 680px or the 92vw clamp for `--md` and bare `.dialog`, with every frame also carrying `card card-glass`

- [x] **TI03** `.dialog--confirm` renders a destructive confirmation from existing canon buttons
  - Variant on TI02's frame, using the `--sm` 480px width contract and the exact frame composition `dialog dialog--confirm card card-glass`: leading `.icon` slot beside the message and a `.dialog-actions` row composing `.btn.btn-ghost` (cancel) with `.btn.btn-danger-fill` (confirm), both already in canon — S03 ships `.btn-danger-fill` for exactly this consumer. This task adds no button rule; if `.btn-danger-fill` is absent from `components.css`, S03 is incomplete — stop rather than defining it here.
  - **Verify**: `rg -n '\.dialog--confirm' dev/design-system/components.css` returns the variant rules, the showcase confirm frame is exactly `class="dialog dialog--confirm card card-glass"`, its computed width matches `.dialog--sm`, `rg -n '^\.btn-danger-fill' dev/design-system/components.css` returns S03's rule, and with `BASE=.agent_temp/0.22.1-s04-entry`, `git diff --no-index -U0 "$BASE/dev/design-system/components.css" dev/design-system/components.css | rg '^\+[^+]\.btn'` returns no matches – proving S04 did not add a button-family rule even though the accumulating checkout already contains S03's addition

- [x] **TI04** The row-scoped destructive pattern is canon, not app-private
  - Promote `app.css#.delete-confirm-bar` and its `.confirm-msg` child into `components.css` beside the dialog family, unchanged in appearance (one declaration swap per the Constraints bullet), so the decision table's row-scoped row (TI06) has backing CSS. The app-local copy stays until S05 deletes it.
  - **Verify**: `rg -n '\.delete-confirm-bar' dev/design-system/components.css` returns the rules; the scheduling delete row still renders identically in the `visual` profile (the app now loads two definitions of the class — canon's in `design-system.css` and the original in `app.css` — identical except `.confirm-msg` carrying `var(--text-base)` for `app.css`'s aliased `var(--text-sm)`, with the later-loading app copy winning until S05 deletes it)

- [x] **TI05** Toast severity reads without colour
  - `.toast::before` becomes a leading mask-image glyph sized like `.icon`, defaulting to `var(--icon-info)`; `.toast-success` / `-error` / `-warning` / `-info` each set both `border-left-color` and their glyph (`--icon-circle-check`, `--icon-circle-x`, `--icon-triangle-alert`, `--icon-info`) per the DESIGN.md § Icons vocabulary. CSS-only — `shared.js#showToast` and the existing `<span>` + `.toast-dismiss` markup are not touched.
  - **Verify**: `rg -n '\.toast(-success|-error|-warning|-info)?::before' dev/design-system/components.css` shows the base rule plus four variant overrides; `rg -n -e '--icon-(circle-check|circle-x|triangle-alert|info)' dev/design-system/components.css` lists the base `--icon-info` default plus the four variant masks (currently zero matches for this group); a greyscale screenshot of the four showcase toasts shows four distinct glyph shapes

- [x] **TI06** DESIGN.md documents the dialog, the five-row feedback table and the stacking order
  - Rename `### Banners and toasts` to `### Feedback` (it now covers dialogs) and replace the four-row table with five rows (per FR5, the two transient cases merge into one row): persistent problem → `.banner-error/-warning/-info`; transient success / error → `.toast-success` / `.toast-error`; destructive confirmation → `.dialog.dialog--confirm.card.card-glass`; row-scoped destructive → `.delete-confirm-bar`; structured input → `.dialog` + applicable width modifier + `.card.card-glass` with real form controls. Delete the `confirm()` mechanism cell and add a prohibition line in the § Native selects style stating native `alert()` / `confirm()` / `prompt()` are banned. Add dialog anatomy under § Components, a stacking-order paragraph under § Elevation & Depth naming the `--z-*` tiers and the `showModal()` top-layer exception with its workaround, and a `dialog:` entry in the frontmatter `components:` map alongside `card-glass`.
  - **Verify**: ``rg -nF '`confirm()` dialog' dev/design-system/DESIGN.md`` returns no matches (it currently returns line 675); `rg -n 'are banned' dev/design-system/DESIGN.md` returns the prohibition line; `rg -n '^### Feedback' dev/design-system/DESIGN.md` returns the renamed heading; `rg -n 'top layer' dev/design-system/DESIGN.md` returns the stacking paragraph; `rg -n '^  dialog:' dev/design-system/DESIGN.md` returns the frontmatter `components:` entry (currently no match)

- [x] **TI07** showcase.html demonstrates every primitive this story adds
  - A Dialogs panel with two live demos — `<dialog class="dialog dialog--confirm card card-glass">` and `<dialog class="dialog dialog--md card card-glass">` hosting S03's form controls and tab strip — a static `.delete-confirm-bar` row demo (TI04's canon copy is otherwise never render-proven without `app.css`), plus the updated Toast Notifications panel showing all four severity glyphs. The tabbed demo proves `.dialog .tabs { border-bottom: 0; }` without an app-local class. Showcase loads only `tokens.css` / `components.css` / `icons.css`, so anything that renders here is proven canon-sufficient for the frame, scrim, width ladder, tab composition, confirm bar and severity glyphs. (The `.task-dialog`-scoped control/tab sizing overrides at `app.css` 2284-2325 and 3822-3825 have no canon counterpart — they are S05 reconciliation fallout; showcase proves the canon half only.)
  - **Verify**: `rg -n 'class="dialog dialog--confirm card card-glass"' dev/design-system/showcase.html` and `rg -n 'class="dialog dialog--md card card-glass"' dev/design-system/showcase.html` each return one demo; `rg -n 'delete-confirm-bar' dev/design-system/showcase.html` returns the row demo (currently no match); opening `showcase.html` and triggering each demo renders them correctly in dark and light theme at 1440px and 768px, and the tabbed dialog's `.tabs` computes `border-bottom-width: 0px`

- [x] **TI08** The served CSS and tracked embedded bundle carry the new canon
  - Copy canon `tokens.css` → `packages/dartclaw_server/lib/src/static/tokens.css` and canon `components.css` → `packages/dartclaw_server/lib/src/static/design-system.css`, each prefixed by the regenerated two-line `/* Synced from dev/design-system/<file> on <date>.\n   sha256: <hash> */` header. `icons.css` is unchanged by this story and must not be re-synced gratuitously. After the final copy, run `dart run dev/tools/embed_assets.dart` before objective verification.
  - **Verify**: `bash dev/tools/fitness/check_design_system_sync.sh` exits 0; `dart test packages/dartclaw_server/test/generated/embedded_assets_test.dart` passes; with `BASE=.agent_temp/0.22.1-s04-entry`, `git diff --no-index --name-only --no-renames "$BASE/packages/dartclaw_server/lib/src/static" packages/dartclaw_server/lib/src/static` names exactly `tokens.css` and `design-system.css`; both generated asset files remain tracked; `rg -n 'var\(--text-sm\)' dev/design-system/components.css packages/dartclaw_server/lib/src/static/design-system.css` returns no matches, preserving S02's completed canon migration

### Testing Strategy
_(Empty — per-task Verify lines plus the showcase-rendered Acceptance Scenarios are the full test approach; this story adds no Dart code.)_

### Validation

- Before TI01, capture story-start baselines for `showcase.html`, `/tasks`, `/projects` and a toast-raising state in both themes at 1440×900 and 768px, following `dev/guidelines/VISUAL-VALIDATION-WORKFLOW.md`. After TI08, re-capture the same states and compare final captures to those story-start baselines. The production dialogs must be pixel-unchanged — this story adds canon classes, it does not repoint markup. The audit's 92-shot set is not this story's comparison set — it belongs to S01's audit-baseline gate and S14's release-level validation.

### Execution Contract

- Capture the `showcase.html`, `/tasks`, `/projects` and toast-state story-start baselines in both themes at 1440×900 and 768px before TI01. TI01 then runs before TI02 (the ladder is settled before component work begins — note the dialog frame itself takes no `z-index`: `showModal()`'s top layer handles its stacking, per the Critical gotcha above); TI02 before TI03/TI07; TI04 and TI05 before TI06 (the table may not name a class that does not yet exist); TI08 last and after every canon or embed-root edit; re-run its sync, generator and parity gate after any later remediation. Final captures compare to the story-start set, never the 92-shot audit set (S01's story-start comparator and S14's release baseline).


## Final Validation Checklist

- [x] With `BASE=.agent_temp/0.22.1-s04-entry`, `git diff --no-index --name-only --no-renames "$BASE/dev/design-system" dev/design-system` names exactly `tokens.css`, `components.css`, `DESIGN.md` and `showcase.html`; `cmp -s "$BASE/dev/design-system/icons.css" dev/design-system/icons.css` exits 0. The entry already contains S01–S03 and every other accumulated checkout edit, so this is S04's own canon delta rather than a branch-base diff.
- [x] The equivalent entry-snapshot diff over `packages/dartclaw_server/lib/src/static` names exactly `tokens.css` and `design-system.css`; no `app.css`, controller, template or served `icons.css` change is attributed to S04.
- [x] `rg -c 'window\.(alert|confirm|prompt)|[^.\w](alert|confirm|prompt)\(' packages/dartclaw_server/lib/src/static/controllers/` still reports the same nine call sites across `dc_shell_controller.js` (5), `dc_settings_controller.js` (2), `dc_scheduling_controller.js` (1) and `dc_projects_controller.js` (1) — S04 must not change controller code, and S06 is what drives this to zero.


## Implementation Observations

#### DECISION NOTE: s04.dialog-width-tier-contract

Decision-Key: s04.dialog-width-tier-contract
Altitude: FIS
Affected surface: Canon `.dialog` width ladder and `.dialog--confirm`
Decision: `.dialog--sm` is `min(92vw, 480px)`; `.dialog--md` and bare `.dialog` are `min(92vw, 680px)`; confirmations use the small tier.
Rationale: Preserves the proven 680px form-dialog measure while giving confirmations a compact, explicit tier.
Evidence: User ratified the recommended preflight option on 2026-07-26.

### Run: 2026-07-29 15:52 UTC – observations

#### HANDOFF to S05 — four facts the repoint cannot derive

**1. Canon has no `.dialog-header h2` rule. The title composes `.t-heading` in markup.** Per the FIS Constraints ban on hand-derived type tiers, `.dialog-header` carries layout and the chrome edge only. `app.css#.task-dialog-header h2` (`--text-lg` + `--weight-bold`) is exactly `.t-heading` minus `letter-spacing: var(--tracking-tight)`, so when S05 repoints, add `class="t-heading"` to the `<h2>` or the title drops to body size. Measured after adding it in the showcase: 18px / 600 / `--fg`, matching production.

**2. Canon has no close-button rule.** Production uses `app.css#.btn-close`. The showcase demos use `class="btn btn-ghost btn-icon" data-icon="x"` instead, which is canon-only. `.btn-icon-sm` + `data-icon` is NOT a working pair — `icons.css` zeroes the glyph margin for `.btn-icon[data-icon]::before` but not for `.btn-icon-sm`, so the glyph sits off-centre in a `padding: 0` box. S05 either adopts the `.btn-icon` form or keeps `.btn-close` app-side.

**3. The 95vw mobile override was deliberately NOT promoted.** `app.css:2062` has `@media (max-width: 768px) { .task-dialog { width: 95vw } }`. The ratified decision note (s04.dialog-width-tier-contract, owner 2026-07-26) fixes one contract per tier: `min(92vw, 680px)`. Repointing therefore narrows both production dialogs by 3vw below ~715px viewport width (the override is inert at 768px itself, where `max-width: 680px` already wins). Intentional, recorded here so it is not read as a regression.

**4. The dialog tab strip inset IS in canon** — `.dialog > .tabs { padding-inline: var(--sp-5) }`. So `app.css#.task-dialog-tabs` (`padding: 0 var(--sp-5); border-bottom: none`) is fully replaced and S05 can delete it. Verified against production: tab text 33px, body label 21px, title 21px from the frame edge — identical in both. The `.task-dialog-tabs .tab-btn` vertical-padding rule and the `.task-dialog`-scoped control sizing at `app.css` 2294-2325 / 3825-3827 have no canon counterpart and remain S05 reconciliation fallout.

#### DEVIATION: the promotion is not byte-for-byte, by necessity

TI02 says to carry over `.task-dialog` behaviour including "scrolling body with pinned header/footer". The app recipe does not actually achieve the second half: `<dialog>` is a block box with UA `overflow: auto`, so at a viewport short enough the whole frame scrolls and the footer leaves the screen. Measured before the fix at 1440x560: frame `scrollHeight` 591 vs `clientHeight` 524, footer rect top 531 / bottom 609 against a frame ending at 543 — Cancel and the confirm button both unreachable.

Acceptance Scenario S02 requires the opposite, so canon diverges deliberately: `.dialog[open] { display: flex; flex-direction: column }` + `.dialog { overflow: hidden }` + `.dialog-body { flex: 1 1 auto; min-height: 0 }` + `flex-shrink: 0` on header, footer and a direct-child `.tabs`. After: frame does not self-scroll, body scrolls, header/tabs/footer all fully visible at 560px. **S05 inherits a fix, not a regression** — but it is a real rendering change to the two production dialogs at short viewports, so it belongs in S05 review notes rather than being discovered later.

The `[open]` qualification is load-bearing and must not be simplified: the UA hides a closed dialog with `dialog:not([open]) { display: none }`, and any author `display` declaration beats a UA one at every specificity, so an unqualified `display: flex` renders every closed dialog on the page. Verified all four showcase dialogs report `display: none` while closed.

#### CONFIRMED for S01: the dialog footer token still serves

S01 TI17 flagged `app.css:2051 .task-dialog-footer` as "dialog chrome — S04 owns the dialog family, so confirm there before repointing". Confirmed: `color-mix(in srgb, var(--bg-base) 18%, var(--bg-mantle))` is promoted unchanged. After S01, dark `--bg-mantle` is the glass base, and the dialog frame *is* glass (`card-glass`), so the footer reads as the same material lifted a step toward the ground. No repoint needed.

#### NOTICED BUT NOT TOUCHING

- **`.delete-confirm-bar` fails WCAG AA in the light theme, pre-existing.** Independent measurement: ghost Cancel label (`--fg-sub0` #62677d) 3.06:1 and `.confirm-msg` (`--fg` #4c4f69) 4.37:1 against the bar surface; the border is 2.59:1 against 3:1 for non-text. Cause is the tint formula `color-mix(in srgb, var(--error) 10%, var(--bg-surface0))`: in light, `--bg-surface0` (#ccd0da) is already below the page ground and a dark `--error` (#a40a2b) darkens it further, while in dark the same formula moves the surface lighter. NOT introduced here — promoted verbatim from `app.css:1153-1158` under TI04 ("unchanged in appearance"), and the app copy still wins at equal specificity, so live rendering is untouched. The release NFR is contrast *preserved*, and it is. Fixing means changing shipped appearance, which is an S05/S14 decision, not a promote-verbatim task. Suggested direction: base the light tint on `--bg-card`/`--bg-base` rather than `--bg-surface0`.
- **`.dialog::backdrop` does not dim in the light theme.** `--bg-pit` resolves to ~#e8eaf0 in light, above the page ground #e4e7ef, so the scrim lightens rather than darkens (measured dimming 1.02:1; dark is a healthy 1.17:1). Only the `blur(4px)` communicates modality. Kept as-is because Acceptance Scenario S01 prescribes a `--bg-pit`-tinted scrim and it is verbatim from `app.css:1952`. This is the same trap canon already documents for `.tabs::after` (a surface tone only darkens in the theme it was chosen for). Worth S14 revisiting, since promoting it makes it the pattern every future modal inherits.
- **`.tab` carries `margin-bottom: -1px`** to overlap the `.tabs` bottom border. Inside a dialog that border is removed, so the active underline hangs 1px past the content box (clipped by the scroller, so invisible today). One-line fix available if it ever surfaces: `.dialog .tabs .tab { margin-bottom: 0 }`.
- **Confirm-dialog glyph sits ~2px above the first text line optical centre** (`align-items: flex-start` on a 1.25em icon in a 1.6 line-height box). Correcting it needs a magic-number `margin-top`; left alone rather than putting a tuned constant into canon.
- **`--z-base` and `--z-dropdown` ship with no consumers.** Mandated verbatim by TI01. They stay speculative until S07 TI08 migrates the seven `app.css` literals; S07 review should confirm they land rather than rot.
- **`showcase.html` `.showcase h3` was narrowed to `h3:not(.t-heading)`.** At `(0,1,1)` it out-specified `.t-heading` at `(0,1,0)` and rendered all three dialog titles as muted body text. No pre-existing `<h3>` in the file carries `.t-heading`, so the change is behaviour-preserving for every other demo. Flagged because it touches a shared showcase style rather than only this story panel.

### Run: 2026-07-29 16:09 UTC – observations

#### CORRECTION to the DEVIATION block above — `min-height: 0` was NOT the mechanism

The earlier observation credited `min-height: 0` on `.dialog-body` for keeping the frame from scrolling its own chrome. A fresh-context critic pass falsified that, and I re-measured at 1440x520 on the showcase form dialog:

| `min-height` | `overflow-y` | frame self-scrolls | footer visible |
|---|---|---|---|
| `0` | `auto` | no (484/484) | yes |
| `auto` | `auto` | no (484/484) | yes |
| `auto` | `visible` | **yes (603/484)** | no |
| `0` | `visible` | **yes (603/484)** | yes |

`overflow-y: auto` is what does the work: a scroll container has an automatic minimum size of zero (CSS Box Sizing 3), so the body can shrink past its own content without any `min-height` declaration. `min-height: 0` was inert in the shipped configuration and has been **removed**; the rule comment now names `overflow-y` as load-bearing. The rest of the DEVIATION block stands — the flex column, `overflow: hidden`, and the `flex-shrink: 0` chrome are all still required, and S05 still inherits a genuine short-viewport fix.

#### NOTICED BUT NOT TOUCHING — second pass (critic review)

- **The toast dismiss button is the one production detail the showcase does NOT prove canon-sufficient.** `shared.js` emits `<button class="toast-dismiss" aria-label="Dismiss" data-icon="x">`, but the reset that centres that glyph — `.toast-dismiss[data-icon]::before { margin-right: 0 }` — lives in `app.css:1975-1979`, not in canon. Substituting production markup into the showcase widens the button by 16.4px. The showcase specimens use a literal `&times;` instead, so the gap is invisible there. Not fixed here: the reset belongs to the icon system, and `icons.css` is frozen for this story by a structural criterion (byte-identical), so placing it needs a decision between `components.css` and `icons.css`. **S05** should route it when it deletes the app-side copies. Note the same unbacked reset also covers `.banner .dismiss` and `.btn-close`.
- **The mandated `card card-glass` composition leaks a hover affordance onto every modal.** `.card:hover` (0,2,0) sets an accent-tinted `border-color` and `box-shadow: var(--shadow-md)`, while `.card-glass` (0,1,0) loses the tie — so mousing over an open dialog *lowers* its elevation from `--shadow-lg` to `--shadow-md` and tints its border. `.card-glass:hover` already resets `translate` for exactly this class of problem ("Overlays anchor to a trigger — they do not drift") but not these two properties. Pre-existing for `.task-dialog`; S04 is what makes the composition canonical. Not fixed here because the correction lives in the Cards family (section 6) and reaches every `.card-glass` consumer, not just dialogs — same blast-radius reasoning S03 used for the `.btn` border. Suggested: add `border-color` and `box-shadow` to the `.card-glass:hover` resets.
- **Canon has no composition for a NON-destructive modal confirmation, and S06 needs one.** `.dialog--confirm` hard-codes `color: var(--error)` on its glyph and the § Feedback table maps it to "Destructive confirmation" only. But the shared decision routes *every* modal confirmation through one `confirmDialog({..., danger})`, and `dc_shell_controller.js:477` ("Restart DartClaw? Active turns will complete first.") is a `danger: false` case. As shipped, S06 must either put a red alert glyph on a benign prompt or drop the glyph entirely, since adding a second modal implementation is banned. Needs a design decision, so it is recorded rather than guessed: either move the `--error` tint off `.dialog--confirm` onto a markup-level icon class or a `.dialog--danger` hook, or document that the non-danger path composes `.dialog--sm` with no glyph.
- **`.dialog .tabs` (descendant) and `.dialog > .tabs` (child) disagree about scope.** The border suppression is a descendant selector while the inset and `flex-shrink` are child selectors, so a `.tabs` sub-navigation nested inside `.dialog-body` would lose its underline without gaining the inset. The rule comment says "directly under the header", which the selector does not enforce. Not fixed because this story Structural Criterion and TI02 Verify both quote `.dialog .tabs { border-bottom: 0; }` verbatim — changing it to `>` would fail the stated gate. Fold it into the child rule when a spec amendment allows.
- **S07 consequence, unrecorded until now:** `--z-toast` is 100 and `.restart-overlay` still carries the literal `9999` (`app.css:2011`), so today the restart blocker covers toasts. When S07 TI08 migrates that literal to `--z-overlay` (30) the ordering inverts and toasts will paint *over* the full-screen restart blocker. That may well be desirable, but it is a behaviour change that should be an explicit S07 decision rather than a side effect. Both the token comments and the DESIGN.md stacking table were reworded to read as role definitions rather than present-tense consumer inventories, so neither now claims a migration that has not happened.
- **The tabbed-dialog demo has incomplete tablist semantics** — `role="tablist"` with `role="tab"` + `aria-selected` but no `aria-controls`, no `role="tabpanel"` and no roving `tabindex`, so assistive tech announces tabs that control nothing. It mirrors S03 existing `.tabs-demo-*` specimens exactly, so it is consistent rather than newly wrong, and fixing it here would diverge from its siblings. Worth an S14 sweep across all tab demos. Everything else in the dialog demos checks out: `aria-labelledby` wired, `showModal()` lands focus on Close, Esc closes, and all four frames report `display: none` while closed.
- **DESIGN.md frontmatter `card-glass` said "72% alpha"; the real value is 60%** (`--glass-bg` is `color-mix(in srgb, var(--bg-mantle) 60%, transparent)`, measured `/ 0.6`). Pre-existing, but this story new `dialog:` entry sits directly beneath it and inherits the figure via `# via card-glass`, which made the stale number newly load-bearing — so it was corrected to 60% in the same edit.

### Run: 2026-07-29 16:23 UTC – observations

#### CLOSE-OUT REMEDIATION (orchestrator-directed, three items) — all green

Landed after the story gates were already green, inside the P1 window, because all three sit in families this story made canonical and become contract-banned once S04 is accepted. `plan.json` stays `done` (same precedent as S02 `.tracking-caps`).

**1. `.card-glass:hover` no longer inherits the card hover affordance.** `.card:hover, .card.card-hover` (0,2,0) out-specified `.card-glass` (0,1,0), so pointing at an open dialog tinted its border toward the accent and dropped its elevation from `--shadow-lg` to `--shadow-md` — an overlay getting *less* prominent as you approach it. The existing rule already reset `background` and `translate` for exactly this reason ("Overlays anchor to a trigger — they do not drift"); it now also restores `border-color`, `border-top-color` and `box-shadow`. `border-top-color` has to be restated because `.card:hover` sets the `border-color` shorthand, which resets all four edges. The selector was widened to `.card-glass:hover, .card-glass.card-hover` to mirror how `.card` pairs its two triggers, so a forced hover state cannot reintroduce what real hover no longer does.

Verified with transitions disabled (a mid-transition `getComputedStyle` returns an oklab interpolation and reads as a false failure — this cost one wrong measurement before it was caught). Real pointer hover on the showcase confirm dialog: `matches(":hover")` true, border stays `--fg`-derived with no accent tint, `box-shadow` keeps `0 8px 32px` (`--shadow-lg`), `translate` none. All **9** `.card-glass` consumers reachable in the showcase — three demo cards, five dialog frames and a simulated `.composer-palette` — are hover-inert in **both** themes. Live check on `/tasks`: the production `dialog.task-dialog.card.card-glass` is hover-inert in both themes and keeps the large elevation. The app has exactly four `.card-glass` consumers (`task_form.dart`, `project_form.dart`, and the two `composer-palette` / `composer-reference-palette` overlays in `chat.html`) and `app.css` declares no `.card-glass` rule, so canon governs all of them.

**2. The icon-only dismiss glyph reset is now canon.** `[data-icon]::before` carries a trailing `--sp-2` to separate a glyph from its label; a dismiss control has no label, so the margin pushed the glyph off-centre. `icons.css` resets this only for `.btn-icon`, and the reset for the dismiss controls lived in `app.css:1975-1979` — meaning the one production detail the showcase did *not* prove canon-sufficient was the dismiss button. The reset now sits in `components.css` beside the feedback family it serves (`icons.css` stays byte-identical, as this story structural criterion requires).

The showcase specimens and the live `showDemoToast` helper both now emit the **real production markup** — `<button class="toast-dismiss" aria-label="Dismiss" data-icon="x"></button>`, matching `shared.js#showToast` exactly — instead of a literal `&times;`. Measured: `margin-right: 0px`, mask present, dismiss box 22px, glyph centred, both themes. So S05 can delete the `app.css` block without opening a canon gap.

*Judgement call worth flagging:* the promoted rule includes `.btn-close[data-icon]::before` even though `.btn-close` is app-owned and has no canon rule. Including it lets S05 delete the app block whole rather than leaving one orphan line; the alternative — canon silently not covering it — risks an 8px glyph shift the moment that block goes. It is commented as app-owned and retires when the close control is repointed at `.btn.btn-ghost.btn-icon`, which `icons.css` already covers. Canon defines no `.btn-close` rule itself, so no button-family rule was added (`git diff` on the entry snapshot still returns no `+.btn` line).

**3. Non-destructive modal confirmation — owner decision, recorded.** The non-danger path composes the **same** `.dialog--confirm` frame with **no glyph**, and a plain `.btn` confirm instead of `.btn-danger-fill`. The `--error` glyph appears only when `danger: true`, supplied at markup level by `confirmDialog`. No new canon rule, no `.dialog--danger` variant, composition formula untouched.

DESIGN.md § Feedback now carries a two-row danger/non-danger table making the split explicit, its decision-table row is retitled "Modal confirmation" (it is no longer destructive-only, and names the restart case), and § Dialogs describes `.dialog--confirm` as serving both. `showcase.html` gains a non-danger specimen using the real S06 copy ("Restart DartClaw? Active turns will complete first."). Measured: identical `dialog dialog--confirm card card-glass` frame class as the destructive demo, 480px, zero `.dialog-body .icon`, confirm button class exactly `btn`. This closes the gap recorded in the previous run block — S06 no longer has to guess or re-litigate.

**Gates re-run after remediation:** drift check exit 0, embedded-assets parity test passes, `dart format` exit 0, `dart analyze --fatal-infos` exit 0, `fitness/run_all.sh` exit 0, `git diff --check` exit 0. Entry-snapshot deltas unchanged in shape — canon names exactly `tokens.css` / `components.css` / `DESIGN.md` / `showcase.html`, served names exactly `tokens.css` / `design-system.css`, with `app.css`, canon `icons.css` and served `icons.css` all byte-identical and the nine controller call sites intact. The gate-pinned `.dialog .tabs { border-bottom: 0; }` string is untouched. Production task dialog re-fingerprinted across 20 computed properties x 7 elements x 2 themes: identical to the story-start capture.

**Explicitly NOT done, per the same instruction:** the `.dialog .tabs` descendant-vs-child selector fold (gate-pinned verbatim, needs a spec amendment), the tablist a11y demo semantics (S14 sweep across all tab demos), and the S07 z-index inversion (S07 decision). All three remain recorded above.

### Run: 2026-07-29 17:43 UTC – observations

#### HOIST (orchestrator-directed): the dialog frame was inert against form-wrapped markup

**The defect S05 proved in production.** `.dialog[open] { display: flex; flex-direction: column }` assumed header / tabs / body / footer were direct children of `<dialog>`. Both production dialogs — and both editors S06 will build — wrap their sections in a `<form>`, so the form was the frame's *only* flex item: the three-part split collapsed one level up, `.dialog-body` never absorbed the squeeze, and because the frame carries `overflow: hidden` the footer was **clipped rather than scrolled** — Cancel and Create Task unreachable by wheel, touch and keyboard, blocking task creation. Measured by S05 at 1440x560: frame `scrollHeight` 593 vs `clientHeight` 524. This was a regression introduced by this story's own short-viewport fix; the block/`overflow: auto` original would at least have scrolled to the footer.

The showcase never caught it because the form-dialog specimen had no `<form>` — the same class of miss as the `&times;` toast-dismiss substitution: a specimen that diverges from production markup cannot prove canon-sufficiency for it.

**Fix, in canon.** A pass-through rather than `display: contents`:

```css
.dialog[open] > form { display: flex; flex-direction: column; min-height: 0; flex: 1 1 auto; }
```

`display: contents` was considered and rejected: it would remove the form's box and risk its landmark role in the a11y tree, for no layout benefit the pass-through does not already give. The pass-through keeps the `<form>` box, its role and its submit semantics intact. The rule is `[open]`-qualified for the same reason the frame rule is — a closed dialog must keep the UA `display: none`.

The tabs chrome rule also only matched a direct child, so it now matches both levels:

```css
.dialog > .tabs, .dialog > form > .tabs { flex-shrink: 0; padding-inline: var(--sp-5); }
```

Deliberately still not a descendant selector: a `.tabs` nested inside `.dialog-body` is content, not frame chrome, and must keep its own inset and its ability to shrink.

**`min-height: 0` IS load-bearing here — the opposite of the `.dialog-body` case.** Measured at 1440x560 on the form-wrapped specimen:

| form `min-height` | frame self-scrolls | footer reachable |
|---|---|---|
| `0` (shipped) | no (524/524) | yes |
| `auto` | **yes (581/524)** | **no** |

The earlier correction in this file removed `min-height: 0` from `.dialog-body` because a scroll container (`overflow-y: auto`) already has an automatic minimum size of zero. A `<form>` has `overflow: visible`, so it is floored at min-content and genuinely needs the explicit `0`. Both facts are true; the distinguishing property is whether the element is a scroll container. Do not "tidy" this one away by analogy with the other.

**Verification.** Form-wrapped specimen at 1440x560, both themes: frame does not self-scroll, body scrolls, header + tabs + footer all reachable, tabs inset 20px with `flex-shrink: 0`. All **five** showcase specimens — the form-wrapped one plus the four direct-child frames (`--confirm`, non-danger `--confirm`, `--sm`, bare `.dialog`) — pass the same assertions in both themes, so the pass-through did not regress the original shape. Form semantics intact: computed `display: flex` (not `contents`), 10 associated form elements, `submit` event fires, dialog closes, and the a11y tree still exposes a `form` node containing every control plus both footer buttons.

**Live, against production markup with S05's interim shim neutralised in the browser** (`#new-task-dialog > form, #add-project-dialog > form` and `#new-task-dialog .tabs` blanked at runtime, so only canon was in play): form resolves `display: flex` / `column` / `min-height: 0px` / `flex-grow: 1` and tabs resolve `padding-left: 20px` / `flex-shrink: 0` — all from canon; frame does not self-scroll (524/524), body scrolls, header and footer reachable, and the Create Task submit button sits inside the frame box. Confirmed in both themes. **S05 can delete its id-keyed shim** — the canon rule is declaration-for-declaration what the shim contained.

**Showcase specimen now mirrors production**: the `--md` demo wraps its sections in `<form method="dialog">` with a real `type="submit"` confirm button, and the panel prose states why. The four direct-child specimens are kept deliberately so both shapes stay render-proven.

**Assets.** Served copies re-synced and `embed_assets.dart` re-run. Drift gate exit 0 and the embedded parity test passes. Because S05 is mid-story in `app.css` / templates, asset identity was proven directly rather than by whole-file diff: base64-decoding the generated bundle shows `static/tokens.css`, `static/design-system.css`, `static/icons.css` and `static/app.css` are each **byte-identical** to their served file, and the canon → served → provenance-header sha256 chain matches for both S04-owned files. Canon delta is still exactly `tokens.css`, `components.css`, `DESIGN.md`, `showcase.html`, with canon `icons.css` byte-identical. `dart format`, `dart analyze --fatal-infos`, `fitness/run_all.sh` and `git diff --check` all exit 0, and the gate-pinned `.dialog .tabs { border-bottom: 0; }` string is untouched.

*Method note for anyone re-running this:* `getComputedStyle` returns a **live** declaration, so reading properties off it after `dialog.close()` reports the closed state and looked like a failure of the form rule. Snapshot values eagerly into primitives while the dialog is open. This is a second instance of the same class of trap as the mid-transition oklab interpolation recorded earlier.

### Run: 2026-07-29 22:52 UTC – observations

#### HOIST (orchestrator-directed): malformed comment in the stacking-order block silently killed `--z-base`

**The defect, and how it got in.** The § Stacking order comment closed at `… what that costs a toast. */`, and the four prose lines added later during close-out remediation (the "role, not inventory" wording) were appended *after* that terminator, ending in a second, unmatched `*/`. Those lines were therefore raw content inside `:root {}`. On malformed input a CSS parser discards up to and including the next semicolon — which was the one ending `--z-base: 0` — so the first tier of the ladder was consumed along with the garbage. `getPropertyValue("--z-base")` returned empty while `--z-sticky` … `--z-toast` all resolved, and the served copy was identically broken. Found by S07 during its z-index migration; S07 correctly left it alone, canon being closed to it.

Introduced by me in the close-out remediation run, not by the original TI01 edit: the first version of the block was well-formed, and the insertion point was chosen without noticing the terminator already sitting there. `dart analyze`, `dart format`, the drift gate and the embedded parity test are all blind to it — none of them parse CSS — which is why it survived a full green gate set twice.

**Fix.** All prose now lives inside a single comment; the wording is unchanged apart from "Each comment **below** states the ROLE …" for accuracy now that the block reads as one unit. No token values were touched.

**Verified in-browser, canon (`showcase.html`, file:// so no server cache):** all seven tiers resolve — `--z-base` `0`, `--z-sticky` `10`, `--z-scrim` `15`, `--z-sidebar` `20`, `--z-dropdown` `25`, `--z-overlay` `30`, `--z-toast` `100` — strictly ascending; a real consumer (`z-index: var(--z-base)` on a positioned probe) computes `0` rather than `auto`, proving the token resolves through the cascade and not merely as a string; and the two declarations immediately after the ladder (`--radius`, `--radius-lg`) are intact, confirming the discard window closed where expected. **Served copy re-verified on a live app page** (`/tasks`, hard reload, `tokens.css` + `app-tokens.css` + `design-system.css` in play): same seven values, `--z-base` `0`, `--radius` `4px`.

**Same-pattern sweep.** Wrote a comment-state scanner (tracks `/*` / `*/` depth, reports stray terminators and unterminated blocks) and ran it over all three canon CSS files plus all seven served CSS files. Before the sync: exactly one defect, the stale served `tokens.css` at line 146. After: **zero across all ten files**. `components.css` was clean, so it was deliberately not re-synced — and the drift gate passing while only `tokens.css` was re-synced is itself the proof that canon `components.css` is unchanged by this hoist.

The embedded bundle was regenerated and checked directly rather than by whole-file diff, since S07 is mid-close: base64-decoding `static/tokens.css` and `static/design-system.css` from the generated map shows both byte-identical to their served files, the decoded `tokens.css` has zero stray terminators and no unterminated block, and it contains `--z-base:     0;`.

**Gates** (slim protocol per the 2026-07-29 owner directive): drift exit 0, embedded parity test passes, `dart format` 0, `dart analyze --fatal-infos` 0, `git diff --check` 0. Canon delta unchanged in shape — still exactly `tokens.css`, `components.css`, `DESIGN.md`, `showcase.html`, with canon `icons.css` byte-identical.

**Worth carrying forward:** a CSS comment defect is invisible to every gate this release runs, and its blast radius is "the declaration after the malformed run", which is arbitrary and silent. The scanner used here is ~15 lines; S14 may want it as a fitness check so the next stray terminator fails CI instead of a story two waves downstream. Recorded as a suggestion, not shipped — adding a fitness test is outside this story surface.
