# Sync hinge: purge app-local duplicates, adopt canonical primitives

**Plan**: dev/bundle/docs/specs/0.22.1/plan.json
**Story-ID**: S05

## Feature Overview and Goal

**Intent**: The app invented private form, tab and dialog families because canon had none; now that S03/S04 ship them, two implementations of each family exist at once – and until the app-local ones are gone, every later story has to guess which one to build on.

**Expected Outcomes**:

- [OC01] Exactly one implementation of the form, tab and dialog families ships – the canonical one. No app-local re-implementation of any of the three remains, only one tab bar ships, and no name S01–S04 moved into canon keeps a competing `app.css` declaration.
- [OC02] Every surface that used an app-local form, tab or dialog behaves exactly as before the swap: settings tabs switch, task and project dialogs open and submit, memory file tabs switch panels, settings field validation still reports per-field errors.
- [OC03] No swapped surface regresses against this story's fresh post-S04 story-start captures, in either theme at 1440×900 and 768px. The audit's 92-shot before/after set serves only S01's audit-baseline gate and S14's release-level re-validation.

## Required Context

### From `prd.md` – "Key Constraints, Assumptions & Dependencies" (canon-first)
<!-- source: prd.md#key-constraints-assumptions--dependencies -->
<!-- extracted: e18cf85 -->
> *Constraint:* **canon-first is mandatory.** The 0.22 drift check requires `design-system.css` byte-identical to `dev/design-system/components.css`. Any app-side edit to a canon-owned rule fails CI.

### From `prd.md` – "Key Constraints, Assumptions & Dependencies" (zero-npm / no build step)
<!-- source: prd.md#key-constraints-assumptions--dependencies -->
<!-- extracted: e18cf85 -->
> *Constraint:* zero-npm / server-first; no build step; no new runtime JS dependencies (FR8 *removes* runtime dependencies, it does not add any).

### From `prd.md` – "Constraints" (no backend work)
<!-- source: prd.md#constraints -->
<!-- extracted: e18cf85 -->
> **No backend work.** Any finding needing a service, schema or API change is out of scope by definition.

### From `prd.md` – "Out of Scope" (no new capabilities)
<!-- source: prd.md#out-of-scope -->
<!-- extracted: e18cf85 -->
> New UX capabilities of any kind. This release adds no features; it refines what exists.

### From `prd.md` – "FR4: Form, tab and dialog primitives in canon" (the acceptance criterion this story owns)
<!-- source: prd.md#fr4-form-tab-and-dialog-primitives-in-canon -->
<!-- extracted: e18cf85 -->
> - [ ] No app-local re-implementation of any of the three remains; only one tab bar ships.

### From `prd.md` – "FR6: Re-sync + adoption sweep" (drift gate)
<!-- source: prd.md#fr6-re-sync--adoption-sweep -->
<!-- extracted: e18cf85 -->
> Re-sync canon into the served CSS with the drift check green, purge app-local duplicates obsoleted by FR4 […]
>
> - [ ] Drift check green; `design-system.css` byte-identical to canon.

### From `prd.md` – "FR1: Surface & depth revision" (contrast floor the fallout pass must not break)
<!-- source: prd.md#fr1-surface--depth-revision -->
<!-- extracted: e18cf85 -->
> Card-vs-ground contrast ≥ 1.15:1 in both themes; no gradient stop equals the card fill.

### From `prd.md` – "Non-Functional Requirements" (accessibility)
<!-- source: prd.md#non-functional-requirements -->
<!-- extracted: e18cf85 -->
> WCAG AA text contrast preserved in both themes after the surface remap; `prefers-reduced-motion` honored; focus-visible on every interactive element; status never conveyed by colour alone

### From `prd.md` – "Non-Functional Requirements" (visual quality gate)
<!-- source: prd.md#non-functional-requirements -->
<!-- extracted: e18cf85 -->
> Both themes at desktop + 768px per story; UI smoke test at phase boundaries; the 92-screenshot audit capture reused as the before/after baseline

### From `plan.json` – shared decision "Canon-first, and canon closes after P1"
<!-- source: plan.json#sharedDecisions -->
<!-- extracted: 2026-07-25, re-extracted after plan remediation (superseded "Canon-first with per-story re-sync") -->
> Only P1 stories S01-S04 author rules in the drift-checked `tokens.css`, `components.css` and `icons.css`; those rule families close after P1. S07 has one serialized, deletion-only exception: after app-side migration it deletes the `--text-sm` alias from `tokens.css`, re-syncs only served `tokens.css`, regenerates embedded assets and closes generated parity green. It may not edit `components.css`, `icons.css` or any other canon family. S05 re-syncs nothing new — it verifies the post-P1 check is green after its purge. Every other P3 story consumes canon and reports a missing rule for hoisting to S01-S04. `DESIGN.md` and `showcase.html` remain writable because they are not drift-checked.

### From `plan.json` – "executionNotes" (embedded assets)
<!-- source: plan.json#executionNotes -->
<!-- extracted: 2026-07-25 -->
> EMBEDDED ASSETS IN THIS SERIALIZED RUN: after this story's final change under `lib/src/templates` or `lib/src/static`, run `dart run dev/tools/embed_assets.dart` before objective verification, then run the generated parity test. Every declared gate closes green; re-run after remediation that changes an embed root.

### From `plan.json` – shared decision "Surface token roles — three distinct planes"
<!-- source: plan.json#sharedDecisions -->
<!-- extracted: 2026-07-25, working-tree plan.json -->
> S01 fixes the structural rule every later story consumes: chrome (`.sidebar`, `.topbar`), page ground and `.card` occupy three mutually distinct planes in BOTH themes, and the body gradient never terminates on the card tone. The token assignment differs per theme and is not fixed here — the PRD's dark remap is chrome→crust / ground→base / card→sub-base, while the light theme gets its own mapping (card white on a tinted ground, chrome at the mantle tier), and exact values in both are an S01 visual-validation outcome. Card hover is not independent: `.card:hover` paints over the same token as card rest, so it re-derives from whatever S01 lands on. No downstream story re-tones a card, chrome, or ground locally — surface complaints go back to S01's tokens.

### From `plan.json` – shared decision "Composite type-class vocabulary"
<!-- source: plan.json#sharedDecisions -->
<!-- extracted: 2026-07-25 -->
> S02 fixes the seven composite class names, each binding font-size + weight + line-height + letter-spacing: `.t-caption`, `.t-body`, `.t-label`, `.t-heading`, `.t-page-title`, `.t-display`, `.t-metric`. All consumers apply these classes; raw `--text-*` tokens are for one-offs only, and no consumer hand-derives a tier from four separate properties.

### From `plan.json` – shared decision "One dialog frame and one confirmation API"
<!-- source: plan.json#sharedDecisions -->
<!-- extracted: 2026-07-25 -->
> S04 ships the canonical `.dialog` family (promoted from the app's proven private `.task-dialog`) with `.dialog--confirm` and an explicit z-index scale. S05 repoints existing markup at it and deletes the private recipe. S06 ships exactly one `confirmDialog({title, body, confirmLabel, danger})` in `shared.js` plus one `htmx:confirm` listener in `dc_shell_controller.js`: every current and future modal confirmation and every `hx-confirm` gate routes through those two. Row-scoped destructive actions use the canonical inline `.delete-confirm-bar`, never a modal; this includes both scheduled-task and scheduled-job row deletes. No story adds a second modal confirmation implementation.

### From `plan.json` – shared decision "`--text-sm` retirement protocol"
<!-- source: plan.json#sharedDecisions -->
<!-- extracted: 2026-07-25 -->
> S02 aliases `--text-sm` to `--text-base`, defines the seven composite classes and migrates every canon `components.css` consumer. S07 migrates the remaining app-side and non-drift-checked demo usages, then uses its one token-only exception to delete the alias from `tokens.css`, sync served `tokens.css`, regenerate embedded assets and close parity green. No other story introduces `--text-sm` or reopens a canon family.

## Deeper Context

- `../dartclaw-public/dev/tools/fitness/check_design_system_sync.sh` – the drift gate: line 2 of each served file must carry the source `sha256:`, and the body from line 3 must diff clean against canon. Read before regenerating any provenance header.
- `docs/specs/0.22.1/audit-ui-polish-2026-07-25.md#c-adoption-gaps--canon-has-the-answer-the-app-does-not-use-it-118` – `global`, `settings/all-tabs`, `settings/tab-bar` groups: the evidence for what the app duplicated and which residual defects belong to the P3 surface sweeps, not here.
- `../dartclaw-public/dev/guidelines/TRELLIS-GUIDELINES.md` – template rules for the `.html` + `.dart` pairs being edited; § Footguns fails silently.
- `../dartclaw-public/packages/dartclaw_server/lib/src/static/controllers/CONVENTIONS.md` – Stimulus naming/attribute contract for the four controllers whose class selectors change.
- `../dartclaw-public/packages/dartclaw_server/AGENTS.md` – § Conventions and § Gotchas for `dartclaw_server`. Its standing "run `embed_assets.dart` after any template or static asset edit" rule applies at this story boundary: run it after the final embed-root change, before objective verification, and close with generated parity green.
- `../dartclaw-public/dev/guidelines/VISUAL-VALIDATION-WORKFLOW.md` – capture conventions for the both-theme, two-viewport pass.
- `../dartclaw-public/dev/design-system/DESIGN.md` – the S03/S04 sections defining the canonical form, tab and dialog vocabulary this story consumes.

## Acceptance Scenarios

- [x] **S01 [OC01,OC02] [TI02] Settings tab strip renders and switches through the canonical tab component**
  - **Given** `settings.html`'s `<nav>` carries `class="tabs tabs--sticky"` with ten `tab` links, and `app.css` declares no `.settings-tabs` / `.settings-tab` rule at all
  - **When** an operator loads `/settings` on the `visual` profile (port 3338) and clicks "Security"
  - **Then** the Security panel becomes visible, the clicked link carries `aria-current="page"`, the strip still scrolls horizontally without wrapping at 768px, and the active-tab underline comes from the served `design-system.css`

- [x] **S02 [OC01,OC02] [TI01,TI03] New Task dialog is the canonical frame hosting canonical form controls**
  - **Given** `task_form.dart` emits `<dialog id="new-task-dialog">` with the canonical `dialog` class plus a `dialog--` width modifier (retaining `card card-glass`), `dialog-header` / `dialog-body` / `dialog-footer` / `dialog-actions` children, and fields using `form-field` / `form-label` / `form-input`
  - **When** an operator clicks the "New Task" button (`data-task-dialog-open`) on `/tasks`, switches to the Workflow tab, and submits
  - **Then** the dialog opens modally over the canon `::backdrop` scrim served from `design-system.css`, the Single Task / Workflow panels switch, and `task-dialog-submit` posts the same payload as before the swap

- [x] **S03 [OC02] [TI01] Settings field validation still reports per-field errors after the form swap**
  - **Given** `dc_settings_controller.js` resolves error slots through the shared `.form-error` class (the name carries over from the app-local family), keys its toggle-exclusion guards on the presence of S03's `.form-toggle` control inside the field container instead of the `.form-group-toggle` class (S03 maps the container itself to `.form-field--inline`, which also hosts non-toggle inline fields and is not a valid guard on its own), and marks invalid inputs by setting `aria-invalid="true"` on the control, which S03's canonical invalid-state hook (`input.form-input[aria-invalid="true"]` / `:user-invalid`, per the canon-hoist manifest) already styles
  - **When** an operator saves the Server tab with Port set to `notanumber`
  - **Then** the offending field renders its inline error text, the input carries `aria-invalid="true"` and takes its error boundary from the served `design-system.css`, and the save is rejected rather than silently accepted

- [x] **S04 [OC03] [TI05,TI08] Swapped surfaces survive the S01–S04 re-tone and re-scale without local re-toning**
  - **Given** S01's surface ladder and S02's type scale are live in the served CSS, and `app.css` no longer declares card, chrome or ground tones for the swapped families
  - **When** `/settings`, `/tasks`, `/memory`, `/knowledge`, `/knowledge/timeline`, `/projects`, `/workflows`, `/channels/*` and task detail are captured in both themes at 1440×900 and 768px against the fresh post-S04 captures taken before TI01
  - **Then** each surface differs from its post-S04 baseline only by the mechanical swap and any TI05 plane-role correction, card-vs-ground contrast stays ≥ 1.15:1, and every swapped control still shows a focus-visible ring

- [x] **S05 [OC01] [TI07] A swap that would change behaviour is recorded, not made**
  - **Given** `.well-content .form-row`'s bespoke input-appearance recipe (`app.css:1105-1114`, plus its 768px block at `:3816-3818`) styles bare `input` / `textarea` / `select` elements rather than canonical control classes, and its only consumer is `scheduling.html` (11 `class="form-row"` divs inside the two `well-content` panels at `:35` and `:121`) – a template outside this story's list
  - **When** the form family is folded onto canon
  - **Then** the recipe is left standing untouched (it has no bare `.form-row` rule head to purge) and recorded in this FIS's Implementation Observations naming S08 as its sole owner – swapping it would mean editing markup this story does not own

- [x] **S06 [OC02] [TI01,TI04] Toggle fields stay excluded from the settings save payload after the container swap**
  - **Given** all four `.form-group-toggle` guard sites in `dc_settings_controller.js` (:210, :277, :375, :398) detect toggle fields via S03's `.form-toggle` control (e.g. `group.querySelector('.form-toggle')`) – not via `.form-field--inline`, which also hosts non-toggle inline fields
  - **When** an operator edits only a text field on the Server tab and saves
  - **Then** the save request body contains the edited field and no toggle-field keys, and the TI04 regression assertion fails if any of the four guards stops matching the toggle container

- [x] **S07 [OC01,OC02] [TI09] The knowledge hub's private toolbar and pager render through canon**
  - **Given** `knowledge_hub.html:20-21` carries `list-toolbar` with a `form-input--search` field instead of `knowledge-search-strip` / `knowledge-search-form`, and its Previous/Next links at `:63,65` carry `class="btn btn-ghost"` inside a canonical `pager` instead of `pager-link`
  - **When** an operator searches on `/knowledge` and pages forward
  - **Then** the search submits and the page advances exactly as before, the toolbar and pager take their appearance from `design-system.css`, and `app.css` declares none of the four replaced classes

## Structural Criteria

- [x] `bash dev/tools/fitness/check_design_system_sync.sh` exits 0 – `tokens.css`, `design-system.css` and `icons.css` byte-identical to canon with matching sha256 provenance headers.
- [x] `app.css` declares no bare-class rule for any class name canon defines, except the ten pre-existing shadows (`banner`, `data-table`, `input-area`, `session-item`, `shell`, `sidebar`, `terminal-frame-body`, `theme-toggle`, `topbar`, `well-content`), which this story does not touch.
- [x] No `app.css` rule whose selector references a canon-defined class in *any* position declares appearance (colour, background, typography, border treatment, shadow); layout-only descendant rules (positioning, overflow, flex/grid, spacing) are permitted per the Architecture Decision, as are appearance-bearing descendant rules explicitly recorded under TI07 with an owning story (`.well-content .form-row` is the known case).
- [x] Element ids and `data-*` hooks are unchanged: `new-task-dialog`, `add-project-dialog`, `task-dialog-submit`, `data-task-dialog-open`, `data-task-dialog-close`, `data-field`, `data-tab`, `data-task-tab`, `data-task-panel` – verified by `for h in new-task-dialog add-project-dialog task-dialog-submit data-task-dialog-open data-task-dialog-close data-field data-tab data-task-tab data-task-panel; do rg -q -- "$h" packages/dartclaw_server/lib/src || echo "MISSING $h"; done` printing nothing.
- [x] The `.form-group-toggle` behavioural guard moves atomically at all four `dc_settings_controller.js` sites (:210, :277, :375, :398) onto a detection that still uniquely identifies toggle fields – S03's `.form-toggle` control inside the field container, not `.form-field--inline` alone – so toggle fields stay excluded from the settings dirty-diff and save payload.
- [x] No surviving `app.css` rule sets the `background` shorthand or `appearance` on a selector that references a canon-defined control class – the shorthand silently resets canon's `background-image` chevron while canon's `appearance: none` still applies, leaving live `<select>`s with no dropdown affordance.
- [x] `app.css` `var(--text-sm)` usages do not exceed the pre-story baseline of 79 – this story introduces none.
- [x] After the final template/static change, `dart run dev/tools/embed_assets.dart` refreshes the tracked generated bundle before objective verification.
- [x] The full `dartclaw_server` test suite is green, including `test/generated/embedded_assets_test.dart`; no allowed-red generated test and no narrowed parity coverage.

## Scope & Boundaries

### Work Areas
- `packages/dartclaw_server/lib/src/static/app.css` – the bespoke form family (`.form-group` / `-toggle` / `-checkbox`, `.form-label`, `.form-input`, `.form-select`, `.form-textarea`, `.form-error`, `.form-hint`), both tab bars (`.settings-tabs` / `.settings-tab`, `.tab-bar` / `.tab-btn`, `.tab-header-actions`, `.knowledge-tabs`), the private `.task-dialog*` family, every further app-local re-implementation the diff surfaces (`.btn-sm`, `.btn-icon-sm`, `.btn-danger-fill`, `.empty-state-title`, `.pager` / `.pager-link` / `.pager-label`, `.knowledge-search-strip` / `-form`, `.toggle-switch` / `.toggle-slider`), and their post-S01–S04 fallout
- Trellis templates – `settings.html`, `memory_dashboard.html`, `knowledge_hub.html`, `kg_timeline.html`, `tasks.html`, `task_detail.html`, `channel_detail.html`, `workflow_list.html`, `task_form.dart`, `project_form.dart`, plus `scheduling.html` **for its two `toggle-switch` / `toggle-slider` lines only** (`:13`, `:22`) – the purge strands them otherwise, and everything else on that surface stays S08's
- Stimulus controllers – `dc_settings_controller.js`, `dc_memory_controller.js`, `dc_tasks_controller.js`, `dc_workflows_controller.js` (class selectors and the HTML strings `dc_workflows_controller.js` builds)
- Regression tests – `test/static/app_js_test.dart`, `test/templates/projects_test.dart`, `test/web/pages/task_detail_test.dart`
- Synced CSS – served `design-system.css` / `tokens.css` / `icons.css`, verified against canon; this story authors no canon rule and re-syncs nothing new
- Deferral ledger – behaviour-changing swaps handed to their owning P3 story

### What We're NOT Doing
- Native `alert` / `confirm` / `prompt` removal and the `confirmDialog` API -- S06 owns them; this story changes dialog *markup*, not dialog *call sites*.
- Per-surface polish on the swapped surfaces (settings IA and dirty state, the sticky tab-strip slab, empty/loading states) -- owned by S07 (type and colour), S16 (empty/loading states and the shared fragments) and the S08–S12 and S15 surface sweeps; fixing them here would hide behaviour changes inside a mechanical swap.
- The `.custom-select` family (`.custom-select` plus `-trigger`, `-label`, `-caret`, `-menu`, `-option`, `-check` and the `.native-select-hidden` child, `app.css:849-1000`) -- app-owned **by design**: DESIGN.md § Native selects sanctions a custom listbox as the escape hatch where a native `<select>` cannot be branded, so it is not a duplicate of `.form-select`. Do not delete it. S08 owns verifying it still renders correctly against the new canon form controls.
- App-local classes canon has no counterpart for (`.form-grid`, `.form-actions`, `.field-label`, `.tab-panel`, `.toggle-btn*`) -- deleting them would remove shipped behaviour. `.form-hint` and `.form-row` do *not* belong on this list: S03 ships both names in canon, so the bare app-local `.form-hint` rule joins TI01's deletion sweep -- except `.well-content .form-row`'s bespoke input-appearance recipe (`app.css:1105-1114`), whose sole consumer is `scheduling.html` – outside this story's template list – and which is therefore recorded under TI07 with S08 as its owner, not made here. Verified in source: `settings.html` carries `guard-editor-form-row` and `signal_pairing.html` carries `pairing-form-row`, both distinct class tokens the `.well-content .form-row` selector cannot match, and `settings.html` has no `well-content` element at all – neither template consumes the recipe, so neither S11 nor S10 is handed any part of it.
- The ten `app.css` classes that shadowed canon names *before* this milestone (`banner`, `data-table`, `input-area`, `session-item`, `shell`, `sidebar`, `terminal-frame-body`, `theme-toggle`, `topbar`, `well-content`) -- pre-existing overrides no S01–S04 change created; sweeping them would break traceability of this change.
- Adoption of the newly canonical primitives on surfaces that never had an app-local equivalent -- `.value-absent`, `.meter--empty`, pagers on unpaginated lists, empty states missing a title, list toolbars on surfaces that never had one: S16 (the shared `.value-absent` helper and the single `.empty-state` implementation) and the S08–S12 and S15 surface sweeps own applying them. This story replaces existing re-implementations; it does not add primitives where nothing stood.
- Any canon edit at all -- S05 has no canon write right. P1 closes every rule family; S07's later exception is limited to deleting the `--text-sm` alias from `tokens.css` and cannot help a primitive gap found here. If a canonical primitive cannot absorb a call site, this story **stops and reports the gap for hoisting into the owning P1 story** (form / control / tab / state to S03, dialog and feedback to S04) – it neither authors the rule nor gives the app a private variant back.

## Architecture Decision

**Approach**: Canon owns the families whole – appearance *and* their own layout, including the sticky strip (`.tabs--sticky`) and trailing action slot (`.tabs-actions`) S03 promoted out of `app.css`; the only app-side rules that survive a purge are genuinely page-specific ones with no canon counterpart, and those are keyed on preserved element ids, never on a canon class head.
**Why this over alternatives**: keeping app-local wrapper classes (`.settings-tabs`, `.knowledge-tabs`) as layout-only shims would leave two tab-bar implementations in the tree, which is exactly what FR4's acceptance criterion forbids – and S03 already absorbed both shapes into canon, so the shims would have nothing left to carry.

## Technical Overview

_(Empty – the Architecture Decision plus per-task pattern references carry the full picture; no separate technical narrative needed.)_

## Code Patterns & External References

```
# type | path#anchor or url                                                      | why needed (intent)
file   | packages/dartclaw_server/lib/src/static/app.css#.settings-tabs          | The sticky ten-tab strip (:1167-1204) S03 absorbed into `.tabs--sticky` – read it to confirm nothing is left behind before deleting
file   | packages/dartclaw_server/lib/src/templates/knowledge_hub.html           | The simplest tab nav to swap first (two links, no controller) before the ten-tab settings case
file   | packages/dartclaw_server/lib/src/static/controllers/dc_settings_controller.js | Tab activation (:4,:16,:717), error rendering (:229,:230,:322) and toggle-exclusion guards (:210,:277,:375,:398) – all must move with the classes
file   | packages/dartclaw_server/lib/src/static/controllers/dc_workflows_controller.js | Builds form markup as HTML strings inside `selectWorkflow` (:159-181) – a class swap here is a JS edit, not a template edit
file   | packages/dartclaw_server/lib/src/templates/task_form.dart               | The dialog + tabs + form composite that exercises all three families at once
file   | packages/dartclaw_server/test/static/app_js_test.dart                   | CSS-text-shape assertions on app.css that break when the rules are deleted
doc    | ../dartclaw-public/dev/design-system/DESIGN.md                          | Canonical form/tab/dialog vocabulary as S03/S04 shipped it
```

## Constraints & Gotchas

- **Constraint**: this FIS lives in `dartclaw-private`, the code does not -- Workaround: every `packages/…`, `dev/…` and `test/…` path below, and every Verify command, is relative to the sibling repo root `../dartclaw-public/`; run them from there.
- **Critical**: this story changes both template and static embed roots. After its final such change, run `dart run dev/tools/embed_assets.dart` before objective verification, then run `dart test packages/dartclaw_server/test/generated/embedded_assets_test.dart`; the full declared suite closes green. Re-run after remediation that changes an embed root. Hand-editing either generated file remains forbidden.
- **Constraint**: the canonical and app-local form classes share names (`form-label`, `form-input`, `form-select`, `form-textarea`, `form-error`) while the container differs (`.form-group` → `.form-field`) -- Workaround: treat the app.css deletion and the container rename as one change per file; a template left on `form-group` keeps its markup valid but loses all layout.
- **Critical**: a `background` shorthand on a control class erases canon's `<select>` chevron while canon's `appearance: none` still applies, leaving live selects with no dropdown affordance -- Must handle by: closing that window at TI01 rather than extending it. S03 mitigated the S03→S05 interval by element-qualifying its control selectors (`input.form-input` / `select.form-select` / `textarea.form-textarea`); once the app's `.form-select` rule is deleted the mitigation is no longer load-bearing, but any *surviving* app rule that sets `background` on a canonical control re-opens it. Confirm the chevron renders on `/settings` after each pass, not only at story close.
- **Avoid**: fixing a visual defect that surfaces during a swap -- Instead: leave the behaviour as-is and record it against the owning P3 story; this story is mechanical class-swapping only.
- **Avoid**: re-toning a card, chrome or ground colour locally when the S01 re-tone looks wrong on a swapped surface -- Instead: route the complaint back to S01's tokens.
- **Critical**: `test/static/app_js_test.dart` asserts literal `app.css` substrings (`.settings-tab,\n  .topbar-back {`, `.task-dialog .custom-select-trigger {\n    min-height: 48px;`, the `.settings-tabs` scroll regexes, the `.task-dialog::backdrop` token check) -- Must handle by: re-pointing each assertion at the canonical class while preserving its intent, especially the 48px mobile touch-target floor.
- **Critical**: the purge list in `plan.json`'s S05 scope (form family, `.settings-tabs` / `.tab-bar`, `.task-dialog`) is **incomplete and non-exhaustive** -- Must handle by: deriving the set from an actual diff of `app.css` definitions against the post-S04 canon vocabulary plus the app-side shapes S03/S04 name as promotion sources, per TI09. Working from any enumeration – the plan's, this FIS's, or S03's – under-delivers FR4's "no app-local re-implementation remains". Two examples the enumerations missed and the diff caught: `.toggle-switch` / `.toggle-slider` (S03 promotes them into `.form-toggle`) and `.pager-link`.
- **Constraint**: `.settings-tabs` is *deleted*, not kept as a layout shim -- Workaround: S03 ships `.tabs--sticky` carrying its behaviour, and S03's What-We're-NOT-Doing assigns the deletion here.
- **Critical**: canon is closed to this story -- Must handle by: reporting, not authoring. P1 owns all rule families; S07's later token-only alias deletion cannot absorb a missing primitive. A gap this story finds – a canonical primitive that cannot absorb a call site, or a canon-owned rule S03/S04 did not ship – stops the pass and is reported for hoisting into the owning P1 story, per `docs/specs/0.22.1/canon-hoist-manifest.md`. This story touches `dev/design-system/` not at all and re-syncs nothing new; `check_design_system_sync.sh` is a *verification* here (proof the purge left the served copies untouched), not a re-sync step. `DESIGN.md` and `showcase.html` are not drift-checked and stay writable, but this story has no reason to write them.

## Implementation Plan

### Implementation Tasks

Before TI01, snapshot the closed canon exactly as this story receives it from S01–S04:

```sh
BASE=.agent_temp/0.22.1-s05-entry
rm -rf "$BASE"
mkdir -p "$BASE/dev"
cp -R dev/design-system "$BASE/dev/"
```

- [x] **TI01** The form family has exactly one implementation, and it is canon's
  - Delete the bespoke `.form-group` / `-toggle` / `-checkbox`, `.form-label`, `.form-input`, `.form-select`, `.form-textarea`, `.form-error`, `.form-hint` rules from `app.css`, together with `.toggle-switch` / `.toggle-slider` (`app.css:752-783` plus the ≤768px 48px block at `:3793-3798`, which S03 promoted into `.form-toggle`) – its markup lives at `settings.html:280,282,564,566,571,573` **and `scheduling.html:13,22`**, so the scheduling pair moves in this pass too or the purge strands it; move `settings.html`, `task_detail.html`, `tasks.html`, `channel_detail.html`, `workflow_list.html`, `project_form.dart`, `task_form.dart` and the variable-field HTML strings built inside `dc_workflows_controller.js#selectWorkflow` (:159-181) onto `form-field` / `form-label` / `form-input` / `form-select` / `form-textarea` / `form-error` plus S03's checkbox and toggle primitives; update the `dc_settings_controller.js` selectors at :210, :229, :230, :277, :322, :375, :398 – the four `.form-group-toggle` guards (:210, :277, :375, :398) move together onto the `.form-toggle`-based detection (e.g. `group.querySelector('.form-toggle')`).
  - The ≤768px `font-size: 16px` iOS-zoom floor (`app.css:3812-3820`) names `.form-input` and `.form-select` among its selectors. Once canon owns the controls that floor is canon-owned, and `font-size` on a canon class head is barred by Structural Criteria 2 and 3 – so drop `.form-input` and `.form-select` from the selector list and leave only the non-canonical selectors (`.custom-select-trigger`, `.pairing-input`, `.well-content .form-row *`) behind in `app.css`. **Consume S03's canonical floor**: at ≤768px, `input.form-input` and `select.form-select` in `components.css` retain `font-size: 16px`. S05 neither re-authors it nor preserves an `app.css` workaround; canon is closed to this story.
  - **Verify**: `rg -n 'form-group|toggle-switch|toggle-slider' packages/dartclaw_server/lib/src/{templates,static,web} packages/dartclaw_server/test` exits with code exactly 1 (0 means residue remains, 2 means the search itself failed – pre-story it exits 0 across ten files, so the check is not vacuous), a `<select class="form-select">` on `/settings` still shows its dropdown chevron at every step of the pass, `/settings`, `/tasks` (New Task), `/projects` (Add Project) and `/channels/*` render fields with label, control and error slot at their pre-swap positions, and at a 768px viewport on `/settings` `getComputedStyle(document.querySelector('input.form-input')).fontSize` reads ≥ 16px – below that the iOS-zoom floor did not survive the move to canon, which is a stop-and-report, not an app-side re-add

- [x] **TI02** One tab component ships, and both divergent tab bars are gone
  - `.settings-tabs` / `.settings-tab`, `.tab-bar` / `.tab-btn`, `.tab-header-actions` and the now-redundant `.knowledge-tabs` wrapper are removed from `app.css` outright – S03's canon absorbed all of their layout (`.tabs`, `.tabs--sticky`, `.tabs-actions`), so no app-side shim survives. `settings.html` carries `class="tabs tabs--sticky"`; `memory_dashboard.html`, `knowledge_hub.html`, `kg_timeline.html` and `task_form.dart` carry `tabs` / `tab`, with `memory_dashboard.html`'s trailing controls on `tabs-actions`; `dc_settings_controller.js:4,16,717` and `dc_memory_controller.js:43,64` query the canonical tab class. `.tab-panel` stays app-local – canon ships no panel primitive.
  - **Verify**: `rg -n '\bsettings-tabs?\b|\btab-btn\b|\btab-bar\b|\bknowledge-tabs\b|\btab-header-actions\b' packages/dartclaw_server/lib/src packages/dartclaw_server/test` exits with code exactly 1 – the bare-token patterns catch CSS selectors, `class="…"` markup and JS strings alike; clicking a settings tab and a memory file tab switches panels, and the settings strip still scrolls without wrapping at 768px

- [x] **TI03** One dialog frame ships, and the private `.task-dialog` recipe is retired
  - All `.task-dialog*` rules removed from `app.css`; `task_form.dart` and `project_form.dart` emit the canonical `dialog` class with a `dialog--` width modifier from S04's `--sm` | `--md` ladder plus `dialog-header` / `dialog-body` / `dialog-footer` / `dialog-actions`. Ids `new-task-dialog`, `add-project-dialog`, `task-dialog-submit` and the `data-task-dialog-open` / `data-task-dialog-close` hooks are unchanged, so `dc_tasks_controller.js:503,507,512,786` and `dc_workflows_controller.js:241,264,265` keep working untouched. Both dialogs use S04's canonical frame composition: `dialog` + applicable width modifier + `card card-glass`. Three `.task-dialog*` blocks are layout, not appearance, and carry over re-keyed on the canonical classes instead of being deleted: the `min-height` touch-target floors on the dialog's controls – `.form-input`, `.form-select` *and* `.custom-select-trigger` (44px base at `app.css:2299-2303`, 48px at ≤768px at `app.css:3822-3826`) – survive as app-local size rules keyed on the preserved dialog ids (`#new-task-dialog`, `#add-project-dialog`), never on a canon class head – `min-height` is sizing, which the Structural Criteria permit in a descendant position. Read the post-S03 `components.css` before carrying them: if canon already floors the canonical controls, drop the `.form-input` / `.form-select` share and keep only the `.custom-select-trigger` share app-side. Likewise id-keyed: `.task-dialog-body .tab-panel.active`'s flex column + `--sp-4` gap (`app.css:2021-2025`, else the bare `.tab-panel.active { display: block }` takes over and the field stack collapses). `.task-dialog-tabs`' inset padding (`app.css:2284`) carries over id-keyed app-side, while its `border-bottom: none` suppression is deleted: S04 canonically owns the composition through `.dialog .tabs { border-bottom: 0; }`, per `canon-hoist-manifest.md`, so this story consumes that rule rather than stop-and-reporting or keeping an app-local border treatment.
  - **Verify**: `rg -n 'task-dialog' packages/dartclaw_server/lib/src packages/dartclaw_server/test | rg -v 'data-task-dialog-(open|close)|task-dialog-submit|new-task-dialog'` prints nothing – the preserved ids and hooks are the only surviving `task-dialog` substrings; `rg -nU --multiline-dotall '^\.dialog \.tabs\s*\{[^}]*border-bottom:\s*0' dev/design-system/components.css` matches S04's rule and no surviving `app.css` selector suppresses the dialog tab border; opening New Task and Add Project shows the canon `::backdrop` scrim, both dialogs submit successfully, the tab strip has no bottom border, and the New Task field stack keeps its `--sp-4` gap in both panels

- [x] **TI09** No app-local re-implementation of any S01–S04 canon primitive survives, inside the three families or outside them _(runs after TI03, before TI04)_
  - **Derive the set, do not trust an enumeration**: list every class `app.css` defines, list every class the post-S04 `dev/design-system/components.css` defines plus the app-side shapes S03/S04 name as their promotion sources, and purge the overlap. Same-name collisions are deleted outright, markup already carrying the name: `.btn-sm` (`:569`), `.btn-icon-sm` (`:788`, `:803`), `.btn-danger-fill` (`:1156`, `:1161`), `.empty-state-title` (`:1809`), `.pager` / `.pager-label` (`:3183`, `:3199`). Renamed replacements need a markup edit too: `.pager-link` (`:3191`) becomes `class="btn btn-ghost"` per S03's pager contract, and `.knowledge-search-strip` / `.knowledge-search-form` (`:3064`, `:3070`, `:3076`, `:3205`) become `.list-toolbar` + `.form-input--search` – both at `knowledge_hub.html:20-21,63,65`, the only consumer. The enumeration is a floor: anything else the diff surfaces is in scope, and the derivation command below is the gate, not this list.
  - Purge means *replacing an existing app-local implementation*. Applying a canonical primitive where the app never had an equivalent – pagers on unpaginated lists, empty-state titles on pages lacking one, `.value-absent` / `.meter--empty` – stays with S16 and the surface sweeps.
  - **Verify**: `rg -n '^\.(btn-sm|btn-icon-sm|btn-danger-fill|empty-state-title|pager|pager-link|pager-label|knowledge-search-strip|knowledge-search-form|toggle-switch|toggle-slider)([ ,{:]|$)' packages/dartclaw_server/lib/src/static/app.css` exits with code exactly 1; the TI06 intersection command returns to exactly the ten pre-existing shadow names; and `/tasks`, `/knowledge` and `/projects` render small buttons, the knowledge toolbar, the Previous/Next pager and empty-state titles through canon rather than the pre-purge `--text-xs` / `--fg-sub0` treatment

- [x] **TI04** Regression tests assert the canonical classes and still guard the mobile touch-target floor
  - Re-point each assertion group at its post-swap owner, preserving intent: (a) the mobile touch-target block (`app_js_test.dart:236-241`) names **three** classes this story retires, not one – `.btn-icon-sm` (TI09), `.toggle-switch`'s 48px square (TI01, `app.css:3793-3798`) and `.settings-tab` (TI02) – and each re-points at whichever file owns that floor afterwards, canon if S03 ships it, the surviving id-keyed app-local rule otherwise; the same rule applies to the dialog's 44/48px `min-height` floors, covering `.form-input`, `.form-select` and `.custom-select-trigger`, not the trigger alone. Every 48px assertion keeps its intent: no touch target shrinks below 48px anywhere it was floored before the swap; (b) the backdrop group asserts against `design-system.css` – the `--bg-pit` 64% `color-mix` now lives on canon `.dialog::backdrop`, and the vacuous `isFalse` regex on the removed `.task-dialog::backdrop` (`app_js_test.dart:396`) is replaced by a positive assertion on the canon backdrop token; (c) the tab-strip scroll group (`app_js_test.dart:269-279`) moves to `design-system.css` in full – `.settings-tabs` is deleted, so the single-row/`overflow-x`/thin-scrollbar assertions now guard canon `.tabs` / `.tabs--sticky`; (d) `test/templates/projects_test.dart:199` and `test/web/pages/task_detail_test.dart:79,80,126` re-point at the canonical container/dialog classes. Add a regression assertion that all four toggle-exclusion guards use the `.form-toggle`-based detection (scenario S06).
  - **Verify**: `dart test packages/dartclaw_server/test/static/app_js_test.dart packages/dartclaw_server/test/templates/projects_test.dart packages/dartclaw_server/test/web/pages/task_detail_test.dart` passes, and each re-pointed assertion fails when its guarded declaration is removed from whichever file now owns it – including the 48px floor, the backdrop token, and the toggle-guard hook

- [x] **TI05** `app.css` carries no fallout from the S01–S04 re-tone and re-scale on the swapped surfaces
  - **The input is S01's plane-role shift record**, not a re-derivation: S01 closes with an Implementation Observations entry in `s01-canon-surface-ladder-depth-colour-rest-states.md` enumerating each `app.css` rule whose hard-coded surface token changed plane role under the re-tone, with the role that rule is intended to carry afterwards. Work that record entry by entry: a rule TI01–TI03/TI09 already deleted needs nothing; every rule still standing is repointed at the token the record assigns it. None re-declares a card, chrome or ground tone locally, and any tone that still reads wrong after the repoint goes back to S01's tokens rather than being corrected here, per the plan's surface-token shared decision. If the record is absent or an entry names no intended role, stop and report – this task has no other authority for what "the correct role" is.
  - **Verify**: transcribe the record into a tab-separated `selector<TAB>intended-token` file (one line per entry) and run, from `../dartclaw-public/`:
    ```bash
    while IFS=$'\t' read -r sel token; do
      block=$(awk -v s="$sel" 'index($0,s){f=1} f{print} f&&/\}/{f=0}' packages/dartclaw_server/lib/src/static/app.css)
      if [ -z "$block" ]; then echo "DELETED $sel"; continue; fi
      printf '%s' "$block" | rg -q -- "$token" && echo "OK $sel -> $token" || echo "UNFIXED $sel -> $token"
    done < record.tsv
    ```
    No `UNFIXED` line is printed, and the output line count equals the record's entry count (a short count means the transcription dropped an entry, not that the rules are clean). Falsification check: reverting any one repointed rule to its pre-story token must make that entry print `UNFIXED`. Plus card-vs-ground contrast measured ≥ 1.15:1 in both themes on `/settings` and `/tasks`

- [x] **TI06** Canon, served CSS and the tracked embedded bundle are provably current, and no canon name keeps an `app.css` rule head
  - This story authors no canon rule and re-syncs nothing: canon closed after P1, so the drift check proves that the purge stayed out of `dev/design-system/` and left the three served copies byte-identical to what S01–S04 landed. After the final template/static change, run `dart run dev/tools/embed_assets.dart` before this objective verification.
  - **Verify**: `bash dev/tools/fitness/check_design_system_sync.sh` exits 0, `dart test packages/dartclaw_server/test/generated/embedded_assets_test.dart` passes, with `BASE=.agent_temp/0.22.1-s05-entry`, `git diff --no-index --quiet "$BASE/dev/design-system" dev/design-system` exits 0, both generated asset files remain tracked, and `comm -12 <(rg -o '^\s*\.[a-zA-Z][a-zA-Z0-9_-]*' dev/design-system/components.css | tr -d ' ' | sed 's/^\.//' | sort -u) <(rg -o '^\s*\.[a-zA-Z][a-zA-Z0-9_-]*' packages/dartclaw_server/lib/src/static/app.css | tr -d ' ' | sed 's/^\.//' | sort -u)` (TI03's carried-over layout rules are keyed on the preserved dialog *ids*, so no canon class name gains an `app.css` rule head and the intersection stays at exactly ten) prints exactly the ten shadow names, one per line: `banner`, `data-table`, `input-area`, `session-item`, `shell`, `sidebar`, `terminal-frame-body`, `theme-toggle`, `topbar`, `well-content`

- [x] **TI07** Every behaviour-changing swap is recorded against its owning story instead of being made
  - Each swap that would alter behaviour or appearance beyond the class change is left unmade and appended to this FIS's Implementation Observations with the owning P3 story named: S06 for confirmation call sites, S07 for global type, colour and stacking, S16 for the shared fragments, states and data formatting, and **S08–S12 and S15** by surface. S15 is not optional in that list – this story edits `workflow_list.html` and `dc_workflows_controller.js`, and S15 is the only owner of the workflows and projects surfaces, so a deferred workflow- or project-surface swap routed to S08–S12 lands on a story that excludes it. Known entries: the sticky settings tab-strip slab (audit `settings/tab-bar`, owner S11) and `.well-content .form-row`'s bespoke input recipe (owner S08 – its only consumer is `scheduling.html`).
  - Deferrals go into the **canonical** FIS at `dartclaw-private/docs/specs/0.22.1/fis/`, not only the disposable public bundle copy, which is deleted before merge – `plan.json#executionNotes` makes this the condition on success metric 5, and S14's ledger reads Implementation Observations and nothing else.
  - **Verify**: Implementation Observations lists one entry per unmade swap; every entry names a story ID drawn from {S06, S07, S08, S09, S10, S11, S12, S15, S16}, and no entry names a story that excludes the surface it defers – check each against the owning FIS's What We're NOT Doing before writing it

- [x] **TI08** The swapped surfaces are visually clean in both themes at both viewports
  - Before TI01 starts, capture `/settings`, `/tasks`, task detail, `/memory`, `/knowledge`, `/knowledge/timeline`, `/projects`, `/workflows` and a channel detail page at the post-S04 boundary on the `visual` profile (port 3338) in dark and light at 1440×900 and 768px – this story's comparison baseline, since the audit's 92-screenshot capture predates the S01–S04 re-tone and cannot separate swap regressions from intended canon changes. Re-capture the same set after TI07 and diff; keep the audit capture as the milestone-level before/after reference.
  - **Verify**: every diff against the post-S04 capture traces to a TI05 plane-role correction or is recorded under TI07 – a mechanical swap introduces no other visual change; no swapped control loses its focus-visible ring, and no status is conveyed by colour alone

### Testing Strategy

_(Empty – regression proof is carried by TI04's re-pointed assertions, including the scenario-S06 toggle-guard assertion, and each task's Verify line; this story adds no new test harness.)_

### Validation

- Full-surface visual pass after each family swap and at story close: both themes, 1440×900 and 768px, `visual` profile (port 3338), diffed against the post-S04 capture per TI08.

### Execution Contract

- Task order is TI01 → TI02 → TI03 → TI09 → TI04 → TI05 → TI06 → TI07 → TI08; TI09 is numbered out of sequence because it was added after the family tasks were tagged, and it must land before TI04 aggregates the regression assertions.
- TI01–TI03 are one family per pass, each followed by `dart test packages/dartclaw_server/test/static/app_js_test.dart packages/dartclaw_server/test/templates/projects_test.dart packages/dartclaw_server/test/web/pages/task_detail_test.dart`, `bash dev/tools/fitness/check_design_system_sync.sh` (story-boundary invariant – it reads only the canon↔served CSS pairs and does not exercise this story's app-side edits) and a full-surface visual pass, before the next family starts – the plan riskSummary's stated mitigation for this story's latent-coupling risk. After the final embed-root change, run the generator and generated parity test before TI06–TI08 close the story.
- Expected intermediate breakage, excluded from the per-pass regression criteria and re-checked after TI03: after TI01, New Task dialog and settings fields still carry `.task-dialog`-scoped `.form-*` overrides (`app.css:2291-2325`); after TI02, `.task-dialog-tabs .tab-btn` (`app.css:2286`) is orphaned until TI03 removes the family.
- Test assertions that name a family's classes are re-pointed in the same pass that swaps that family's markup (`projects_test.dart:199` and the `.toggle-switch` 48px assertion at `app_js_test.dart:239` with TI01, the `.settings-tab*` groups with TI02, `task_detail_test.dart:80,126` and the dialog groups with TI03, the `.btn-icon-sm` 48px assertion at `app_js_test.dart:237` with TI09) – otherwise the per-pass test gate fails on its own schedule; TI04 aggregates, adds the toggle-guard assertion, and closes with the full run. The generated parity test runs after the final embed-root change and is included in the green closing gate.

## Final Validation Checklist

- [x] `bash dev/tools/fitness/check_design_system_sync.sh` exits 0, with `BASE=.agent_temp/0.22.1-s05-entry`, `git diff --no-index --quiet "$BASE/dev/design-system" dev/design-system` exits 0, and both generated asset files remain tracked
- [x] `dart test packages/dartclaw_server` is fully green, including `test/generated/embedded_assets_test.dart`
- [x] The hook-preservation loop (Structural Criteria) prints nothing
- [x] The four purge greps (TI01 `form-group`, TI02 tab tokens, TI03 `task-dialog` with preserved-hook exclusions, TI09 the five promoted names) exit exactly 1 / print nothing
- [x] TI05's record-driven loop prints no `UNFIXED` line and one line per entry in S01's plane-role shift record
- [x] TI08 visual pass complete; Implementation Observations carries one entry per unmade swap, each naming an owning story that does not exclude the surface

## Implementation Observations

### Run: 2026-07-29 17:56 UTC – observations

#### CANON GAPS FOUND AND HOISTED (four; S03's and S04's families — all landed and verified)

Three rules the swap proved canon needed. Each was measured live on the `visual` profile after the purge, reported for
orchestrator-mediated hoisting rather than authored here, and landed in `dev/design-system/components.css` mid-story.
**S05 authored no canon rule and re-synced no served copy** — the hoisting story owned both, and
`check_design_system_sync.sh` exits 0.

| Gap | Pre-swap (app.css) | Canon before the hoist | After the hoist |
|---|---|---|---|
| `.form-toggle` hit area at ≤768px | 48x48 (`.toggle-switch`), slider 36x20 centred | 36x20 — **20px height fails WCAG 2.5.8 AA (24px)** | 48x48 box, slider 36x20 centred |
| `.tab` height at ≤768px (anchor tabs) | 48 (`.settings-tab`) | 36 — clears AA, loses the pre-swap floor | 48 |
| `.dialog[open] > form` pass-through | n/a — the app frame never split | frame split collapsed at the `<form>`; footer **unreachable** | frame splits one level down |

Only anchor tabs were affected by the second: `app.css`'s generic `button, summary, [role="button"] { min-height: 48px }`
still floors the four `<button>` memory tabs, so the loss reached the ten `<a>` settings tabs alone. The hoisted
`.tab { display: inline-flex; align-items: center }` is load-bearing — a `<button>` centres its own content and an
`<a>` does not, so without it the two tab forms would sit differently once the floor raises the box.

The third is the one worth reading twice. Canon's `.dialog[open] { display: flex; flex-direction: column }` plus
`.dialog { overflow: hidden }` assumes header/body/footer are direct children of `<dialog>`. Both production dialogs
wrap their sections in a `<form>`, so the form was the frame's only flex item, the column stopped there, the body never
absorbed the squeeze, and because the frame **clips rather than scrolls** the footer left the viewport with no way
back — measured at 1440x560: frame scrollHeight 593 vs clientHeight 524, Cancel and Create Task unreachable by wheel,
touch or keyboard. That is strictly worse than pre-swap, where the frame at least carried the UA's `overflow: auto`,
and it blocked task creation outright, so it could not be recorded and deferred.

**Shim -> hoist -> shim removed, in that order.** S05 first carried it app-side as an id-keyed layout rule
(`#new-task-dialog > form, #add-project-dialog > form`) in the same category as TI03's three sanctioned carry-overs,
because the footer being unreachable blocked task creation and could not wait. It was reported at the same time. The
orchestrator routed it to **S04** rather than leaving it app-side, on the reasoning that the form-wrapper inertness is
structural, not per-dialog: S06's two upcoming editors are form-wrapped too, so every future submitting dialog would
have re-derived the same rule. S04 shipped `.dialog[open] > form { display: flex; flex-direction: column; min-height: 0;
flex: 1 1 auto }` plus `.dialog > form > .tabs` inset parity. **The app-local shim was then deleted and canon is
consumed.**

Verified against pure canon with no app-local rule in place, at 1440x560: New Task frame 524/524 (no self-scroll), body
scrolls, header and footer both visible, `form` computes `display: flex` with `min-height: 0px`, tab strip
`padding-inline-start: 20px` and `border-bottom-width: 0px`; Add Project frame does not self-scroll and its footer is
visible. **S04's short-viewport fix reaches production only through this rule** — without it the canonical frame is
inert against form-wrapped markup.

Note `min-height: 0` is load-bearing on the *form* even though S04 established it was inert on `.dialog-body` (where
`overflow-y: auto` does the work). The form is not a scroll container, so it has no automatic minimum size of zero and
would otherwise refuse to shrink below its content. Do not tidy it away.


**A fourth gap, found by the post-implementation review — hoisted to S03, landed, closed:
`textarea.form-textarea` had no ≤768px iOS-zoom floor.** Canon's floor is
`@media (max-width: 768px) { input.form-input, select.form-select { font-size: 16px } }` and its own comment says
"textarea is deliberately absent — add it only against evidence of the same native case." That evidence now exists:
pre-swap every one of these textareas carried `class="form-input"`, so the *app* block's bare `.form-input` entry
floored them at 16px. They now carry `form-textarea` only and match neither floor. Measured at 768px on `/settings`:
`textarea.form-textarea` computes **14px** while `input.form-input` beside it computes 16px, so iOS Safari will zoom the
viewport on focus where it previously did not. Five live consumers: settings Compact Instructions
(`settings.html:245`), New Task Description and Acceptance Criteria (`task_form.dart:88,101`), task-detail pushback
(`task_detail.html:202`), and the long-form workflow variables built in `dc_workflows_controller.js:169`.
`.well-content .form-row textarea` kept its own 16px entry, so two textarea families now behave differently on the same
device. Per TI01's stop-and-report clause it was **not** re-added app-side; it was reported for a canon hoist into S03,
which shipped it by adding `textarea.form-textarea` to canon's existing ≤768px block and deleting the "deliberately
absent" comment. TI01's Verify probes only `input.form-input`, which is why the task gate passed over it — the defect
was caught by the post-implementation review, not by the spec.

**Closed and verified after the hoist landed**, all five consumers measured at 768x900 against the served canon:

| Consumer | Element | Class | Computed |
|---|---|---|---|
| Settings Compact Instructions | `#field-compact-instructions` | `form-textarea` | 16px |
| New Task Description | `#task-description` | `form-textarea` | 16px |
| New Task Acceptance Criteria | `#task-acceptance-criteria` | `form-textarea` | 16px |
| Task-detail pushback | `#pushback-comment` | `form-textarea` | 16px |
| Workflow long-form variable (JS-built) | `[name="wf-var-FEATURE"]` | `form-textarea` | 16px |

The fifth is the one worth having measured rather than reasoned about: it is emitted as an HTML string by
`dc_workflows_controller.js#selectWorkflow`, so nothing static proves canon's element-qualified selector matches what
that code actually writes. Driving the real path — open New Task, switch to the Workflow tab, select a definition —
also confirmed the rest of the controller-built form family renders through canon: container `form-field`, label
`form-label t-label` at 14px/500, and its three `input.form-input` siblings at 16px. The Compact Instructions field
needed its collapsed settings panel revealed before measuring, per S03's trap.

#### DECISIONS THIS STORY OWNED

**`.btn-icon-sm` touch target (handed over by S03).** Accepted canon's 28px tier; no app-local bump, no canon request.
The five live consumers (`scheduling.html:96,99,192,196,199`) carried `class="btn-icon-sm"` with **no** `.btn`, so
canon alone would have stripped them to UA chrome — canon's `.btn-icon-sm` is padding and box only. Adding the base
class both restores appearance and picks up canon's own `@media (max-width: 768px) { .btn { min-height: 48px } }`, so
they measure 48x48 at mobile with no app rule and no canon change. Only the 769–1024px band drops 44px to 28px, which
clears WCAG 2.5.8 AA (24px); 44px was 2.5.5 AAA. A `pointer: coarse` bump for the whole icon-button family remains the
better long-term answer and is a canon decision, not an app one.

**The dialog tab-strip inset is canon's, not app-side — corrected after review.** This story first carried it as
`#new-task-dialog .tabs { padding-inline: var(--sp-5) }` on the reasoning that canon's `.dialog > .tabs` is a *child*
selector and the strip is a grandchild behind the `<form>`. That reasoning was **wrong**: canon ships the two-level
selector `.dialog > .tabs, .dialog > form > .tabs` (`components.css:3122-3128`), whose own comment says "Both levels are
matched because the frame's chrome row sits inside the `<form>` when there is one." The DOM
(`<dialog class="dialog …"><form id="new-task-form"><div class="tabs">`) is a literal match for the second selector.
The app-local rule was therefore a duplicate of a canon rule — exactly what this story exists to delete — and it has
been removed, along with TI03's instruction to carry it. **S04's handoff item 4 was right and this story's first reading
of it was wrong.** Measured after removal: `padding-inline-start: 20px`, `border-bottom-width: 0px` — unchanged.

Canon's `.dialog .tabs { border-bottom: 0 }` is a descendant selector and reaches through the form, so the border
suppression was deleted as TI03 directs. The `>` vs descendant split across this family is deliberate and documented in
canon: `.dialog[open] > form`, `.dialog > .tabs` and `.dialog > form > .tabs` are child selectors so a `.tabs` nested
deeper — inside `.dialog-body` — reads as content rather than frame chrome and keeps its own inset.

**Reseed boundary — read before comparing any before/after capture.** The 48 story-start screenshots were taken on the
long-lived `visual` instance on port 3338, which had accumulated runtime state since 12:28. Mid-story that process was
killed by a careless `pkill -f "dartclaw-visual"` (the pattern also matched its `mktemp` data dir) and restarted, which
reseeded it — the profile's `run.sh` uses a temp data dir with a cleanup trap, so accumulated sessions and tasks were
discarded. The 48 after-captures were taken on a clean instance. **Content differences that cross that boundary —
different session lists, task rows, or counts — are reseed artifacts and must not be read as visual regressions.** Only
layout, type, colour and spacing differences are attributable to this story's swap. Two files exceeded an 8% byte
delta: `channel-detail-dark-mobile.png` (-73%, a capture-timing artifact — the *before* caught a mid-transition fade
with the channel avatar not yet painted; the after is the settled render) and `workflows-light-mobile.png` (-9%,
content). Both were reviewed visually and neither is a regression.

The compiled-template problem behind the restart is worth recording for the next story that edits a `.dart` template:
`dartclaw serve --dev --source-dir` serves `.html` templates and static assets live from the source tree, but `.dart`
template functions (`task_form.dart`, `project_form.dart`, `projects_page.dart`) are compiled into the running VM and do
**not** reload. A long-running server will silently render the old dialog markup. Start a second instance on another
port rather than restarting a shared one.

#### DEFERRED — behaviour- or appearance-changing swaps left unmade, with owning story

| # | Item | Owner | Why not here |
|---|---|---|---|
| 1 | `.well-content .form-row`'s bespoke input-appearance recipe (`app.css`, plus its 768px `font-size: 16px` entry) | **S08** | Styles bare `input`/`textarea`/`select`, not canonical control classes; its only consumer is `scheduling.html`, a template outside this story's list. Left standing untouched — it has no bare `.form-row` rule head to purge. Confirmed in source: `settings.html` carries `guard-editor-form-row`, `signal_pairing.html` carries `pairing-form-row`, and `settings.html` has no `well-content` element, so neither S11 nor S10 inherits any part of it. |
| 2 | Sticky settings tab-strip slab (audit `settings/tab-bar`) | **S11** | Presentation of the strip once canon owns it; not a class swap. |
| 3 | `restart_banner.html:7,8` — `class="btn-sm btn-primary"` / `class="btn-sm btn-ghost dismiss"` carry no base `.btn` | **S12** | Pre-existing defect the plan assigns whole to S12 (S16 and S11 both explicitly decline it). Deleting app.css's `.btn-sm` moves their label from 12px to 14px and gives them canon's `.btn-sm` box, but they remain UA chrome until the base class lands. Not fixed here — fixing only these two would leave the shell's other missing-`.btn` cases inconsistent. |
| 4 | `.custom-select` family (`.custom-select` plus `-trigger`, `-label`, `-caret`, `-menu`, `-option`, `-check`, `.native-select-hidden`) | **S08** (verification only) | **Intentionally retained, not an overlooked duplicate.** DESIGN.md § Native selects sanctions a custom listbox as the escape hatch where a native `<select>` cannot be branded, so it is not a duplicate of canon's `.form-select`. Its `.custom-select-trigger` keeps both the 16px iOS floor and the dialog's 44/48px min-height, now id-keyed. |
| 5 | Inline `<code>` inside `.task-chat-embed` is byte-identical to its host in dark theme | **canon / S01 lineage** | TI05 repoints `.task-chat-embed` to `--bg-card` as S01's record directs, and in dark `--bg-card` resolves to exactly `--bg-sub-base` — which canon's `.msg-content code` paints. Measured: an un-highlighted probe `<code>` inside the embed returns `oklab(0.302107 0.00681466 -0.0307181)` for both itself and its host. It is masked in production only incidentally, because highlight.js tags every inline `<code>` with `.hljs` and paints `#1e1e2e` over it — remove that and the collision is live. S01 predicted this exactly and offered two remedies: step the well (`color-mix(in oklab, var(--bg-card) 88%, var(--bg-crust))`) or keep the host off the card plane. The first is a canon edit; the second contradicts S01's own record entry. Routed back rather than corrected locally, per the plan's surface-token shared decision. |
| 6 | `.metric-card` family (`app.css`) still shadows canon's `.card-metric` | **S15** | S07 explicitly declines it and assigns the deletion plus the `workflow_detail.html` re-render to S15. TI05 repointed its `--bg-mantle` to `--bg-card` per S01's record; the family itself stays. |
| 7 | Pager label drops from 14px to 12px | **accepted, recorded** | `.pager-label` now composes `.t-caption`, matching canon's own showcase specimen. TI09's Verify explicitly expects the pager to render "through canon rather than the pre-purge `--text-xs` / `--fg-sub0` treatment", so this is the intended direction, not drift. |
| 8 | `.empty-state-title` weight drops from 600 to 500 | **accepted, recorded** | Canon's rule is colour-only and its comment directs the markup to compose a `.t-*` tier; there is no 14px/600 tier, so `.t-label` (14px/500) is the nearest. Colour moves `--fg-sub0` to `--fg`, which is canon's stated intent for the rule. |
| 9 | `.btn-danger-fill` glyph colour moves `--bg-base` to `--bg-crust` | **accepted, recorded** | Canon's promoted value. Its only consumer (`dc_scheduling_controller.js`) already composes `btn btn-danger-fill btn-sm`, so canon reaches it with no markup change. |
| 10 | `.btn-sm` label grows 12px to 14px across ~58 call sites | **accepted, recorded** | S03 recorded this as the deliberate consequence of canon's `.btn-sm` declaring no `font-size` ("the label tier stays with the type layer"); the app copy loading later was the only reason 12px still shipped. |
| 11 | Tab strips lose a 16px bottom margin on `/settings`, `/knowledge`, `/knowledge/timeline` | **accepted, recorded** | Canon's `.tabs` carries no trailing margin. On those three the parent `.page-inner` is a flex column with a 24px gap, so the strip stays separated — the gap goes from 40px to 24px. `/memory` was the one surface where the parent is a block box with no gap, so the strip would have sat flush against the panel it labels; that one is carried as `#memory-files-card .tabs { margin-bottom: var(--sp-4) }`, layout-only and keyed on a preserved id. |
| 12 | Both dialogs narrow by 3vw below ~715px viewport width | **accepted, recorded (S04 handoff item 3)** | `app.css`'s `@media (max-width: 768px) { .task-dialog { width: 95vw } }` was deliberately not promoted; the ratified width contract is one per tier (`min(92vw, 680px)`). Inert at 768px itself, where `max-width: 680px` already wins. |
| 13 | Dialog checkboxes grow 14px to 16px; their labels move `--fg-sub0` to `--fg` at unchanged 14px | **accepted, recorded** | `input.form-checkbox` is canon's control; the app's `.task-dialog .form-group-checkbox input[type="checkbox"]` size override and its label colour rule were appearance on canon-class descendants, which Structural Criteria 2/3 bar. |
| 14 | Knowledge search section spacing | **accepted, recorded** | The `.knowledge-search-strip` wrapper (grid, `--sp-3` gap, `--sp-4` bottom margin) is replaced by `.list-toolbar` on the `<form>` itself. Form-to-chips spacing moves 12px to 16px; the section's own bottom margin is absorbed by `.page-inner`'s 24px gap. |
| 15 | `workflow_list.html`'s two `select.form-input` controls now carry `form-select` | **overlaps S15 TI13** | Canon element-qualifies `select.form-select`, so after the purge these two selects matched no canonical rule at all. S15 TI13 claims this swap; it is done here because leaving it would strand them for the whole intervening window. S15 should find it already applied — its stated reasoning is unchanged and its "closed, not deferred" disposition still holds. |
| 16 | Settings tab labels gain `--weight-medium` and `--leading-tight` | **accepted, recorded** | The deleted `.settings-tab` set `font-size` only, so the ten anchors rendered at the inherited normal weight; `.t-label` adds weight 500 and tight leading. Size is unchanged (`--text-sm` aliases `--text-base`). DESIGN.md § Forms directs "compose `.t-label` on labels and tabs", and the four `.tab-btn` families already carried `--weight-medium`, so applying it harmonises the two tab forms rather than diverging them. Caught by review, not by the visual pass. |
| 17 | `/memory`'s tab bar stops wrapping at 768px and scrolls instead | **accepted, recorded** | The deleted `.tab-bar` had `@media (max-width: 768px) { flex-wrap: wrap }` with `.tab-header-actions` going full-width below the tabs. Canon's `.tabs` is `flex-wrap: nowrap; overflow-x: auto` by S03's Architecture Decision ("scroll, never wrap"), and S03 recorded that the full-width wrap "is **not** carried into canon" because it is not expressible inside a scroller. The Raw/Rendered toggle group is now reached by the same horizontal scroll as the tabs. Route to S09 if the toggle should not live inside a scrolling strip. |
| 18 | A magnifier glyph now renders in the knowledge search field | **accepted, recorded** | `<span class="icon icon-search">` is new markup. It is coupled to the class swap rather than gratuitous: canon's `input.form-input.form-input--search { padding-left: var(--sp-8) }` reserves the glyph's space unconditionally, so omitting it would leave a bare 32px indent. Matches canon's own showcase specimen for `.list-toolbar`. |

#### DELTAS FROM THIS FIS'S OWN ENUMERATIONS

**TI06's intersection is exactly ten names, but not the ten the FIS lists** — `banner` is out and `btn-close` is in.

- `banner` was never a real shadow. `app.css` had no bare `.banner` rule; the name entered the extraction only through
  the multi-selector head `.banner .dismiss[data-icon]::before, .toast-dismiss[data-icon]::before,
  .btn-close[data-icon]::before`, which S04's close-out made canonical and this story deleted. `app.css` now declares
  only `.banner-restart`, which canon does not define.
- `btn-close` enters for the mirror reason. Canon defines **no** `.btn-close` rule — it carries
  `.btn-close[data-icon]::before` plus a comment that reads, verbatim, ".btn-close is app-owned and has no canon rule
  — the selector is here so the app-side copy can be deleted whole rather than leaving one orphan line". The
  line-anchored extraction cannot tell that selector from a rule head. The control stays app-owned per S04's handoff
  ("S05 either adopts the `.btn-icon` form or keeps `.btn-close` app-side") and the orchestrator's direction; adopting
  `.btn.btn-ghost.btn-icon` would add a visible resting border to both dialog close buttons, which is an appearance
  change this story does not make.

The criterion's intent — no canon primitive keeps a competing `app.css` rule head — holds in both cases. Nine genuine
pre-existing shadows survive untouched: `data-table`, `input-area`, `session-item`, `shell`, `sidebar`,
`terminal-frame-body`, `theme-toggle`, `topbar`, `well-content`.

**An eleventh pre-existing shadow the FIS's list missed:** `session-title-static`. Canon declares
`.topbar .session-title-static` and `app.css` declares a bare `.session-title-static` with font-size, weight and
colour. Pre-existing, created by no S01–S04 change, and invisible to TI06's line-anchored command (canon's selector
starts `.topbar`). Left alone under the same reasoning as the other pre-existing shadows.

**Two Verify greps cannot exit 1 as written**, both pattern artifacts rather than residue:

- TI01's `toggle-slider` matches canon's own `form-toggle-slider` as a substring, and the `lib/src/static` scope
  includes the drift-checked served `design-system.css`, whose promoted comment names `.form-group` /
  `.form-group-checkbox` as the promotion source. Neither is editable by this story. Re-run with class-token
  boundaries and the served canon excluded, the check exits 1: `rg -nP 'form-group(?![\w-])|(?<![\w-])toggle-switch(?![\w-])|(?<![\w-])toggle-slider(?![\w-])' <lib dirs> <test> -g '!design-system.css'`.
- TI02's `settings-tabs?` matches the re-pointed test assertion that proves the name is *absent*
  (`RegExp(r'^\.settings-tabs?\b'...) , isFalse`). Scoped to `lib/src` it exits 1.

**S03's note that Scenario S05's interaction-set enumeration is incomplete is confirmed and unchanged.** Three canon
rules reach live markup the list does not mention: `.form-checkbox` (3 uses in `channel_detail.html`, no app.css rule
behind them), `.status-badge-muted` (emitted by `ChannelStatus.disabled`, visible on `/scheduling`), and
`.empty-state .btn` spacing. The traceability clause cannot be satisfied literally; it is satisfied in intent by
deriving the purge set from an actual `app.css`-vs-canon diff, as TI09 directs, rather than from any enumeration.

**Entry-snapshot delta.** `.agent_temp/0.22.1-s05-entry` was taken at 18:29, before the mid-story hoist landed at
19:04, so TI06's `git diff --no-index --quiet "$BASE/dev/design-system" dev/design-system` exits 1 for the rest of the
story. The snapshot was deliberately **not** re-taken: it is the audit trail proving S05 authored no canon, and the
diff against it now shows exactly and only the two hoisted rules and nothing else. The served re-sync was performed by
the hoisting story, not by S05 — `check_design_system_sync.sh` exits 0.

#### VERIFICATION EVIDENCE — appearance rules on canon-referencing selectors

Structural Criterion 3 was checked mechanically rather than by eye: every `app.css` rule whose selector references a
class canon defines (in any position), cross-checked against a canon class inventory built from selectors only, with
comments stripped. **52 such rules before this story, 30 after — 22 removed, none added.** The one entry that reads as
"new" is the 768px `font-size: 16px` block, whose identity string changed only because `.form-input,` and
`.form-select,` were dropped from the head of its selector list; the rule is the same and the only canon classes it
still references are `well-content` and `form-row`, the carve-out recorded above. Every surviving flagged rule is one
of the nine pre-existing shadows, a `.active` state-class coincidence, `.btn-close`, or the `.well-content .form-row`
case with S08 named as owner.
