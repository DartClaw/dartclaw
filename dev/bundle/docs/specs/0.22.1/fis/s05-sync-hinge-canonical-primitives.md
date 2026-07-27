# Sync hinge: purge app-local duplicates, adopt canonical primitives

**Plan**: docs/specs/0.22.1/plan.json
**Story-ID**: S05

## Feature Overview and Goal

**Intent**: The app invented private form, tab and dialog families because canon had none; now that S03/S04 ship them, two implementations of each family exist at once – and until the app-local ones are gone, every later story has to guess which one to build on.

**Expected Outcomes**:

- [OC01] Exactly one implementation of the form, tab and dialog families ships – the canonical one. No app-local re-implementation of any of the three remains, only one tab bar ships, and no name S01–S04 moved into canon keeps a competing `app.css` declaration.
- [OC02] Every surface that used an app-local form, tab or dialog behaves exactly as before the swap: settings tabs switch, task and project dialogs open and submit, memory file tabs switch panels, settings field validation still reports per-field errors.
- [OC03] No surface regresses visually against the audit's before/after baseline, in either theme at desktop and 768px, once the S01–S04 re-tone and re-scale reach the app.

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
> A story that changes a canon-owned rule edits `dev/design-system/` (tokens.css / components.css / icons.css / DESIGN.md / showcase.html) first, then re-syncs the served copies under `packages/dartclaw_server/lib/src/static/` — regenerating the two-line `/* Synced from … sha256: … */` provenance header — within the same story. `dev/tools/fitness/check_design_system_sync.sh` must be green at every story boundary. ONLY the P1 stories S01-S04 hold that right, and only for the three DRIFT-CHECKED files — `tokens.css`, `components.css` and `icons.css`. Those close once P1 completes, because the check pins a sha256 on line 2 of each served copy and concurrent edits in the parallel P3 wave conflict on that line by construction. S05 re-syncs nothing new — it verifies the check is green after its purge. A P3 story that finds it needs a canon RULE stops and reports it for hoisting into the owning P1 story (surfaces and chrome to S01, type and icons to S02, form/control/tab/state to S03, dialog and feedback to S04); it does not add the rule itself. `DESIGN.md` and `showcase.html` are NOT closed and NOT drift-checked — they are prose and a demo, never synced — so any story that establishes a documented contract writes it there directly, and S14 reconciles the whole document at release close.

### From `plan.json` – "executionNotes" (embedded assets)
<!-- source: plan.json#executionNotes -->
<!-- extracted: 2026-07-25 -->
> EMBEDDED ASSETS: `embedded_assets.g.dart` is regenerated exactly ONCE, by S14. No other story runs `dart run dev/tools/embed_assets.dart`, and no other story asserts a clean `git diff` on it. Mid-release regeneration is re-drifted by every subsequent story, so it is wasted work that also lands a large generated-file diff into parallel branches.

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
> S04 ships the canonical `.dialog` family (promoted from the app's proven private `.task-dialog`) with `.dialog--confirm` and an explicit z-index scale. S05 repoints existing markup at it and deletes the private recipe. S06 ships exactly one `confirmDialog({title, body, confirmLabel, danger})` in `shared.js` plus one `htmx:confirm` listener in `dc_shell_controller.js` — every current and future confirmation routes through those two, and no story adds a second dialog implementation.

### From `plan.json` – shared decision "`--text-sm` retirement protocol"
<!-- source: plan.json#sharedDecisions -->
<!-- extracted: 2026-07-25 -->
> S02 aliases `--text-sm` to `--text-base` in canon `tokens.css` […]; S07 migrates every remaining usage in `app.css` and `design-system.css` onto the composite classes and then deletes the alias from canon. No other story introduces a new `--text-sm` usage.

## Deeper Context

- `../dartclaw-public/dev/tools/fitness/check_design_system_sync.sh` – the drift gate: line 2 of each served file must carry the source `sha256:`, and the body from line 3 must diff clean against canon. Read before regenerating any provenance header.
- `docs/specs/0.22.1/audit-ui-polish-2026-07-25.md#c-adoption-gaps--canon-has-the-answer-the-app-does-not-use-it-118` – `global`, `settings/all-tabs`, `settings/tab-bar` groups: the evidence for what the app duplicated and which residual defects belong to the P3 surface sweeps, not here.
- `../dartclaw-public/dev/guidelines/TRELLIS-GUIDELINES.md` – template rules for the `.html` + `.dart` pairs being edited; § Footguns fails silently.
- `../dartclaw-public/packages/dartclaw_server/lib/src/static/controllers/CONVENTIONS.md` – Stimulus naming/attribute contract for the four controllers whose class selectors change.
- `../dartclaw-public/packages/dartclaw_server/AGENTS.md` – § Conventions and § Gotchas for `dartclaw_server`. Note its standing "run `embed_assets.dart` after any template or static asset edit" rule is **suspended for this release** by `plan.json#executionNotes`: `embedded_assets.g.dart` is regenerated exactly once, by S14.
- `../dartclaw-public/dev/guidelines/VISUAL-VALIDATION-WORKFLOW.md` – capture conventions for the both-theme, two-viewport pass.
- `../dartclaw-public/dev/design-system/DESIGN.md` – the S03/S04 sections defining the canonical form, tab and dialog vocabulary this story consumes.

## Acceptance Scenarios

- [ ] **S01 [OC01,OC02] [TI02] Settings tab strip renders and switches through the canonical tab component**
  - **Given** `settings.html`'s `<nav>` carries `class="tabs tabs--sticky"` with ten `tab` links, and `app.css` declares no `.settings-tabs` / `.settings-tab` rule at all
  - **When** an operator loads `/settings` on the `visual` profile (port 3338) and clicks "Security"
  - **Then** the Security panel becomes visible, the clicked link carries `aria-current="page"`, the strip still scrolls horizontally without wrapping at 768px, and the active-tab underline comes from the served `design-system.css`

- [ ] **S02 [OC01,OC02] [TI01,TI03] New Task dialog is the canonical frame hosting canonical form controls**
  - **Given** `task_form.dart` emits `<dialog id="new-task-dialog">` with the canonical `dialog` class plus a `dialog--` width modifier (retaining `card card-glass`), `dialog-header` / `dialog-body` / `dialog-footer` / `dialog-actions` children, and fields using `form-field` / `form-label` / `form-input`
  - **When** an operator clicks the "New Task" button (`data-task-dialog-open`) on `/tasks`, switches to the Workflow tab, and submits
  - **Then** the dialog opens modally over the canon `::backdrop` scrim served from `design-system.css`, the Single Task / Workflow panels switch, and `task-dialog-submit` posts the same payload as before the swap

- [ ] **S03 [OC02] [TI01] Settings field validation still reports per-field errors after the form swap**
  - **Given** `dc_settings_controller.js` resolves error slots through the shared `.form-error` class (the name carries over from the app-local family), keys its toggle-exclusion guards on the presence of S03's `.form-toggle` control inside the field container instead of the `.form-group-toggle` class (S03 maps the container itself to `.form-field--inline`, which also hosts non-toggle inline fields and is not a valid guard on its own), and marks invalid inputs by setting `aria-invalid="true"` on the control, which S03's canonical invalid-state hook (`input.form-input[aria-invalid="true"]` / `:user-invalid`, per the canon-hoist manifest) already styles
  - **When** an operator saves the Server tab with Port set to `notanumber`
  - **Then** the offending field renders its inline error text, the input carries `aria-invalid="true"` and takes its error boundary from the served `design-system.css`, and the save is rejected rather than silently accepted

- [ ] **S04 [OC03] [TI05,TI08] Swapped surfaces survive the S01–S04 re-tone and re-scale without local re-toning**
  - **Given** S01's surface ladder and S02's type scale are live in the served CSS, and `app.css` no longer declares card, chrome or ground tones for the swapped families
  - **When** `/settings`, `/tasks`, `/memory`, `/knowledge`, `/knowledge/timeline`, `/projects`, `/workflows`, `/channels/*` and task detail are captured in both themes at 1440px and 768px against the audit's baseline
  - **Then** each surface differs from the baseline only by the intended canon changes, card-vs-ground contrast stays ≥ 1.15:1, and every swapped control still shows a focus-visible ring

- [ ] **S05 [OC01] [TI07] A swap that would change behaviour is recorded, not made**
  - **Given** `.well-content .form-row`'s bespoke input-appearance recipe (`app.css:1105-1114`, plus its 768px block at `:3816-3818`) styles bare `input` / `textarea` / `select` elements rather than canonical control classes, and its only consumer is `scheduling.html` (11 `class="form-row"` divs inside the two `well-content` panels at `:35` and `:121`) – a template outside this story's list
  - **When** the form family is folded onto canon
  - **Then** the recipe is left standing untouched (it has no bare `.form-row` rule head to purge) and recorded in this FIS's Implementation Observations naming S08 as its sole owner – swapping it would mean editing markup this story does not own

- [ ] **S06 [OC02] [TI01,TI04] Toggle fields stay excluded from the settings save payload after the container swap**
  - **Given** all four `.form-group-toggle` guard sites in `dc_settings_controller.js` (:210, :277, :375, :398) detect toggle fields via S03's `.form-toggle` control (e.g. `group.querySelector('.form-toggle')`) – not via `.form-field--inline`, which also hosts non-toggle inline fields
  - **When** an operator edits only a text field on the Server tab and saves
  - **Then** the save request body contains the edited field and no toggle-field keys, and the TI04 regression assertion fails if any of the four guards stops matching the toggle container

- [ ] **S07 [OC01,OC02] [TI09] The knowledge hub's private toolbar and pager render through canon**
  - **Given** `knowledge_hub.html:20-21` carries `list-toolbar` with a `form-input--search` field instead of `knowledge-search-strip` / `knowledge-search-form`, and its Previous/Next links at `:63,65` carry `class="btn btn-ghost"` inside a canonical `pager` instead of `pager-link`
  - **When** an operator searches on `/knowledge` and pages forward
  - **Then** the search submits and the page advances exactly as before, the toolbar and pager take their appearance from `design-system.css`, and `app.css` declares none of the four replaced classes

## Structural Criteria

- [ ] `bash dev/tools/fitness/check_design_system_sync.sh` exits 0 – `tokens.css`, `design-system.css` and `icons.css` byte-identical to canon with matching sha256 provenance headers.
- [ ] `app.css` declares no bare-class rule for any class name canon defines, except the ten pre-existing shadows (`banner`, `data-table`, `input-area`, `session-item`, `shell`, `sidebar`, `terminal-frame-body`, `theme-toggle`, `topbar`, `well-content`), which this story does not touch.
- [ ] No `app.css` rule whose selector references a canon-defined class in *any* position declares appearance (colour, background, typography, border treatment, shadow); layout-only descendant rules (positioning, overflow, flex/grid, spacing) are permitted per the Architecture Decision, as are appearance-bearing descendant rules explicitly recorded under TI07 with an owning story (`.well-content .form-row` is the known case).
- [ ] Element ids and `data-*` hooks are unchanged: `new-task-dialog`, `add-project-dialog`, `task-dialog-submit`, `data-task-dialog-open`, `data-task-dialog-close`, `data-field`, `data-tab`, `data-task-tab`, `data-task-panel` – verified by `for h in new-task-dialog add-project-dialog task-dialog-submit data-task-dialog-open data-task-dialog-close data-field data-tab data-task-tab data-task-panel; do rg -q -- "$h" packages/dartclaw_server/lib/src || echo "MISSING $h"; done` printing nothing.
- [ ] The `.form-group-toggle` behavioural guard moves atomically at all four `dc_settings_controller.js` sites (:210, :277, :375, :398) onto a detection that still uniquely identifies toggle fields – S03's `.form-toggle` control inside the field container, not `.form-field--inline` alone – so toggle fields stay excluded from the settings dirty-diff and save payload.
- [ ] No surviving `app.css` rule sets the `background` shorthand or `appearance` on a selector that references a canon-defined control class – the shorthand silently resets canon's `background-image` chevron while canon's `appearance: none` still applies, leaving live `<select>`s with no dropdown affordance.
- [ ] `app.css` `var(--text-sm)` usages do not exceed the pre-story baseline of 79 – this story introduces none.
- [ ] `lib/src/generated/embedded_assets.g.dart` is deliberately left stale – `git status --porcelain packages/dartclaw_server/lib/src/generated/` prints nothing for this story. `plan.json#executionNotes` reserves the single regeneration for S14.
- [ ] The `dartclaw_server` test suite is green except `test/generated/embedded_assets_test.dart`, which byte-compares the stale generated bundle against `lib/src/templates` and `lib/src/static` and has been red since S01's first re-sync – the release-wide condition S14 closes, not a defect this story introduces. Do not regenerate to make it pass and do not narrow the test.

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
- Any canon edit at all -- canon closed when P1 completed (`plan.json#sharedDecisions`, *Canon-first, and canon closes after P1*): `tokens.css`, `components.css` and `icons.css` are writable only by S01–S04. If a canonical primitive cannot absorb a call site, this story **stops and reports the gap for hoisting into the owning P1 story** (form / control / tab / state to S03, dialog and feedback to S04) – it neither authors the rule nor gives the app a private variant back.

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
- **Critical**: do **not** run `dart run dev/tools/embed_assets.dart` -- `plan.json#executionNotes` reserves the single regeneration for S14, because mid-release regeneration is re-drifted by every subsequent story and lands a large generated diff into the parallel P3 branches. `lib/src/generated/embedded_assets.g.dart` therefore stays stale through this story, exactly as S01 and S04 leave it; hand-editing it is forbidden too. Leaving it stale costs this story nothing: the `visual` profile runs from the source checkout, where `asset_resolver.dart` resolves `staticDir` and the template dir on disk and falls back to the embedded bundle only when no source tree is present.
- **Constraint**: the canonical and app-local form classes share names (`form-label`, `form-input`, `form-select`, `form-textarea`, `form-error`) while the container differs (`.form-group` → `.form-field`) -- Workaround: treat the app.css deletion and the container rename as one change per file; a template left on `form-group` keeps its markup valid but loses all layout.
- **Critical**: a `background` shorthand on a control class erases canon's `<select>` chevron while canon's `appearance: none` still applies, leaving live selects with no dropdown affordance -- Must handle by: closing that window at TI01 rather than extending it. S03 mitigated the S03→S05 interval by element-qualifying its control selectors (`input.form-input` / `select.form-select` / `textarea.form-textarea`); once the app's `.form-select` rule is deleted the mitigation is no longer load-bearing, but any *surviving* app rule that sets `background` on a canonical control re-opens it. Confirm the chevron renders on `/settings` after each pass, not only at story close.
- **Avoid**: fixing a visual defect that surfaces during a swap -- Instead: leave the behaviour as-is and record it against the owning P3 story; this story is mechanical class-swapping only.
- **Avoid**: re-toning a card, chrome or ground colour locally when the S01 re-tone looks wrong on a swapped surface -- Instead: route the complaint back to S01's tokens.
- **Critical**: `test/static/app_js_test.dart` asserts literal `app.css` substrings (`.settings-tab,\n  .topbar-back {`, `.task-dialog .custom-select-trigger {\n    min-height: 48px;`, the `.settings-tabs` scroll regexes, the `.task-dialog::backdrop` token check) -- Must handle by: re-pointing each assertion at the canonical class while preserving its intent, especially the 48px mobile touch-target floor.
- **Critical**: the purge list in `plan.json`'s S05 scope (form family, `.settings-tabs` / `.tab-bar`, `.task-dialog`) is **incomplete and non-exhaustive** -- Must handle by: deriving the set from an actual diff of `app.css` definitions against the post-S04 canon vocabulary plus the app-side shapes S03/S04 name as promotion sources, per TI09. Working from any enumeration – the plan's, this FIS's, or S03's – under-delivers FR4's "no app-local re-implementation remains". Two examples the enumerations missed and the diff caught: `.toggle-switch` / `.toggle-slider` (S03 promotes them into `.form-toggle`) and `.pager-link`.
- **Constraint**: `.settings-tabs` is *deleted*, not kept as a layout shim -- Workaround: S03 ships `.tabs--sticky` carrying its behaviour, and S03's What-We're-NOT-Doing assigns the deletion here.
- **Critical**: canon is closed to this story -- Must handle by: reporting, not authoring. `tokens.css`, `components.css` and `icons.css` are writable only by S01–S04 (`plan.json#sharedDecisions`), so a gap this story finds – a canonical primitive that cannot absorb a call site, or a canon-owned rule S03/S04 did not ship – stops the pass and is reported for hoisting into the owning P1 story, per `docs/specs/0.22.1/canon-hoist-manifest.md`. This story touches `dev/design-system/` not at all and re-syncs nothing new; `check_design_system_sync.sh` is a *verification* here (proof the purge left the served copies untouched), not a re-sync step. `DESIGN.md` and `showcase.html` are not drift-checked and stay writable, but this story has no reason to write them.

## Implementation Plan

### Implementation Tasks

- [ ] **TI01** The form family has exactly one implementation, and it is canon's
  - Delete the bespoke `.form-group` / `-toggle` / `-checkbox`, `.form-label`, `.form-input`, `.form-select`, `.form-textarea`, `.form-error`, `.form-hint` rules from `app.css`, together with `.toggle-switch` / `.toggle-slider` (`app.css:752-783` plus the ≤768px 48px block at `:3793-3798`, which S03 promoted into `.form-toggle`) – its markup lives at `settings.html:280,282,564,566,571,573` **and `scheduling.html:13,22`**, so the scheduling pair moves in this pass too or the purge strands it; move `settings.html`, `task_detail.html`, `tasks.html`, `channel_detail.html`, `workflow_list.html`, `project_form.dart`, `task_form.dart` and the variable-field HTML strings built inside `dc_workflows_controller.js#selectWorkflow` (:159-181) onto `form-field` / `form-label` / `form-input` / `form-select` / `form-textarea` / `form-error` plus S03's checkbox and toggle primitives; update the `dc_settings_controller.js` selectors at :210, :229, :230, :277, :322, :375, :398 – the four `.form-group-toggle` guards (:210, :277, :375, :398) move together onto the `.form-toggle`-based detection (e.g. `group.querySelector('.form-toggle')`).
  - The ≤768px `font-size: 16px` iOS-zoom floor (`app.css:3812-3820`) names `.form-input` and `.form-select` among its selectors. Once canon owns the controls that floor is canon-owned, and `font-size` on a canon class head is barred by Structural Criteria 2 and 3 – so drop `.form-input` and `.form-select` from the selector list and leave only the non-canonical selectors (`.custom-select-trigger`, `.pairing-input`, `.well-content .form-row *`) behind in `app.css`. **Then confirm canon actually carries the floor**: canon's controls take `font: inherit` and S02's `--text-base` is 14px, so without a canon-side ≤768px floor the swap re-introduces iOS focus-zoom on every settings and dialog field. Canon is closed to this story – if the post-S03 `components.css` has no such rule, **stop and report it for hoisting into S03** (`canon-hoist-manifest.md`); do not author it and do not keep the app-side rule as a workaround.
  - **Verify**: `rg -n 'form-group|toggle-switch|toggle-slider' packages/dartclaw_server/lib/src/{templates,static,web} packages/dartclaw_server/test` exits with code exactly 1 (0 means residue remains, 2 means the search itself failed – pre-story it exits 0 across ten files, so the check is not vacuous), a `<select class="form-select">` on `/settings` still shows its dropdown chevron at every step of the pass, `/settings`, `/tasks` (New Task), `/projects` (Add Project) and `/channels/*` render fields with label, control and error slot at their pre-swap positions, and at a 768px viewport on `/settings` `getComputedStyle(document.querySelector('input.form-input')).fontSize` reads ≥ 16px – below that the iOS-zoom floor did not survive the move to canon, which is a stop-and-report, not an app-side re-add

- [ ] **TI02** One tab component ships, and both divergent tab bars are gone
  - `.settings-tabs` / `.settings-tab`, `.tab-bar` / `.tab-btn`, `.tab-header-actions` and the now-redundant `.knowledge-tabs` wrapper are removed from `app.css` outright – S03's canon absorbed all of their layout (`.tabs`, `.tabs--sticky`, `.tabs-actions`), so no app-side shim survives. `settings.html` carries `class="tabs tabs--sticky"`; `memory_dashboard.html`, `knowledge_hub.html`, `kg_timeline.html` and `task_form.dart` carry `tabs` / `tab`, with `memory_dashboard.html`'s trailing controls on `tabs-actions`; `dc_settings_controller.js:4,16,717` and `dc_memory_controller.js:43,64` query the canonical tab class. `.tab-panel` stays app-local – canon ships no panel primitive.
  - **Verify**: `rg -n '\bsettings-tabs?\b|\btab-btn\b|\btab-bar\b|\bknowledge-tabs\b|\btab-header-actions\b' packages/dartclaw_server/lib/src packages/dartclaw_server/test` exits with code exactly 1 – the bare-token patterns catch CSS selectors, `class="…"` markup and JS strings alike; clicking a settings tab and a memory file tab switches panels, and the settings strip still scrolls without wrapping at 768px

- [ ] **TI03** One dialog frame ships, and the private `.task-dialog` recipe is retired
  - All `.task-dialog*` rules removed from `app.css`; `task_form.dart` and `project_form.dart` emit the canonical `dialog` class with a `dialog--` width modifier from S04's `--sm` | `--md` ladder plus `dialog-header` / `dialog-body` / `dialog-footer` / `dialog-actions`. Ids `new-task-dialog`, `add-project-dialog`, `task-dialog-submit` and the `data-task-dialog-open` / `data-task-dialog-close` hooks are unchanged, so `dc_tasks_controller.js:503,507,512,786` and `dc_workflows_controller.js:241,264,265` keep working untouched. Both dialogs keep their `card card-glass` surface classes alongside the canonical `dialog` class (S04's canonical markup shape). Three `.task-dialog*` blocks are layout, not appearance, and carry over re-keyed on the canonical classes instead of being deleted: the `min-height` touch-target floors on the dialog's controls – `.form-input`, `.form-select` *and* `.custom-select-trigger` (44px base at `app.css:2299-2303`, 48px at ≤768px at `app.css:3822-3826`) – survive as app-local size rules keyed on the preserved dialog ids (`#new-task-dialog`, `#add-project-dialog`), never on a canon class head – `min-height` is sizing, which the Structural Criteria permit in a descendant position. Read the post-S03 `components.css` before carrying them: if canon already floors the canonical controls, drop the `.form-input` / `.form-select` share and keep only the `.custom-select-trigger` share app-side. Likewise id-keyed: `.task-dialog-body .tab-panel.active`'s flex column + `--sp-4` gap (`app.css:2021-2025`, else the bare `.tab-panel.active { display: block }` takes over and the field stack collapses). `.task-dialog-tabs`' inset padding (`app.css:2284`) carries over id-keyed app-side, but its `border-bottom: none` suppression is a border treatment, which the appearance criterion bars from any selector naming a canon class – and canon is closed to this story, so it is neither authored here nor kept app-side: **stop and report it for hoisting into S04**, which owns how a tab bar composes inside the dialog frame. Until it lands, the dialog's tab strip carries canon `.tabs`' bottom border; record that as a TI07 entry if the swap ships first.
  - **Verify**: `rg -n 'task-dialog' packages/dartclaw_server/lib/src packages/dartclaw_server/test | rg -v 'data-task-dialog-(open|close)|task-dialog-submit|new-task-dialog'` prints nothing – the preserved ids and hooks are the only surviving `task-dialog` substrings; opening New Task and Add Project shows the canon `::backdrop` scrim, both dialogs submit successfully, and the New Task field stack keeps its `--sp-4` gap in both panels

- [ ] **TI09** No app-local re-implementation of any S01–S04 canon primitive survives, inside the three families or outside them _(runs after TI03, before TI04)_
  - **Derive the set, do not trust an enumeration**: list every class `app.css` defines, list every class the post-S04 `dev/design-system/components.css` defines plus the app-side shapes S03/S04 name as their promotion sources, and purge the overlap. Same-name collisions are deleted outright, markup already carrying the name: `.btn-sm` (`:569`), `.btn-icon-sm` (`:788`, `:803`), `.btn-danger-fill` (`:1156`, `:1161`), `.empty-state-title` (`:1809`), `.pager` / `.pager-label` (`:3183`, `:3199`). Renamed replacements need a markup edit too: `.pager-link` (`:3191`) becomes `class="btn btn-ghost"` per S03's pager contract, and `.knowledge-search-strip` / `.knowledge-search-form` (`:3064`, `:3070`, `:3076`, `:3205`) become `.list-toolbar` + `.form-input--search` – both at `knowledge_hub.html:20-21,63,65`, the only consumer. The enumeration is a floor: anything else the diff surfaces is in scope, and the derivation command below is the gate, not this list.
  - Purge means *replacing an existing app-local implementation*. Applying a canonical primitive where the app never had an equivalent – pagers on unpaginated lists, empty-state titles on pages lacking one, `.value-absent` / `.meter--empty` – stays with S16 and the surface sweeps.
  - **Verify**: `rg -n '^\.(btn-sm|btn-icon-sm|btn-danger-fill|empty-state-title|pager|pager-link|pager-label|knowledge-search-strip|knowledge-search-form|toggle-switch|toggle-slider)([ ,{:]|$)' packages/dartclaw_server/lib/src/static/app.css` exits with code exactly 1; the TI06 intersection command returns to exactly the ten pre-existing shadow names; and `/tasks`, `/knowledge` and `/projects` render small buttons, the knowledge toolbar, the Previous/Next pager and empty-state titles through canon rather than the pre-purge `--text-xs` / `--fg-sub0` treatment

- [ ] **TI04** Regression tests assert the canonical classes and still guard the mobile touch-target floor
  - Re-point each assertion group at its post-swap owner, preserving intent: (a) the mobile touch-target block (`app_js_test.dart:236-241`) names **three** classes this story retires, not one – `.btn-icon-sm` (TI09), `.toggle-switch`'s 48px square (TI01, `app.css:3793-3798`) and `.settings-tab` (TI02) – and each re-points at whichever file owns that floor afterwards, canon if S03 ships it, the surviving id-keyed app-local rule otherwise; the same rule applies to the dialog's 44/48px `min-height` floors, covering `.form-input`, `.form-select` and `.custom-select-trigger`, not the trigger alone. Every 48px assertion keeps its intent: no touch target shrinks below 48px anywhere it was floored before the swap; (b) the backdrop group asserts against `design-system.css` – the `--bg-pit` 64% `color-mix` now lives on canon `.dialog::backdrop`, and the vacuous `isFalse` regex on the removed `.task-dialog::backdrop` (`app_js_test.dart:396`) is replaced by a positive assertion on the canon backdrop token; (c) the tab-strip scroll group (`app_js_test.dart:269-279`) moves to `design-system.css` in full – `.settings-tabs` is deleted, so the single-row/`overflow-x`/thin-scrollbar assertions now guard canon `.tabs` / `.tabs--sticky`; (d) `test/templates/projects_test.dart:199` and `test/web/pages/task_detail_test.dart:79,80,126` re-point at the canonical container/dialog classes. Add a regression assertion that all four toggle-exclusion guards use the `.form-toggle`-based detection (scenario S06).
  - **Verify**: `dart test packages/dartclaw_server/test/static/app_js_test.dart packages/dartclaw_server/test/templates/projects_test.dart packages/dartclaw_server/test/web/pages/task_detail_test.dart` passes, and each re-pointed assertion fails when its guarded declaration is removed from whichever file now owns it – including the 48px floor, the backdrop token, and the toggle-guard hook

- [ ] **TI05** `app.css` carries no fallout from the S01–S04 re-tone and re-scale on the swapped surfaces
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

- [ ] **TI06** Canon and served CSS are provably identical, and no canon name keeps an `app.css` rule head
  - This story authors no canon rule and re-syncs nothing: canon closed after P1, so the drift check runs here purely as proof that the purge stayed out of `dev/design-system/` and left the three served copies byte-identical to what S01–S04 landed. `lib/src/generated/embedded_assets.g.dart` is left stale – S14 owns the single release-level regeneration.
  - **Verify**: `bash dev/tools/fitness/check_design_system_sync.sh` exits 0, `git status --porcelain dev/design-system/ packages/dartclaw_server/lib/src/generated/` prints nothing, and `comm -12 <(rg -o '^\s*\.[a-zA-Z][a-zA-Z0-9_-]*' dev/design-system/components.css | tr -d ' ' | sed 's/^\.//' | sort -u) <(rg -o '^\s*\.[a-zA-Z][a-zA-Z0-9_-]*' packages/dartclaw_server/lib/src/static/app.css | tr -d ' ' | sed 's/^\.//' | sort -u)` (TI03's carried-over layout rules are keyed on the preserved dialog *ids*, so no canon class name gains an `app.css` rule head and the intersection stays at exactly ten) prints exactly the ten shadow names, one per line: `banner`, `data-table`, `input-area`, `session-item`, `shell`, `sidebar`, `terminal-frame-body`, `theme-toggle`, `topbar`, `well-content`

- [ ] **TI07** Every behaviour-changing swap is recorded against its owning story instead of being made
  - Each swap that would alter behaviour or appearance beyond the class change is left unmade and appended to this FIS's Implementation Observations with the owning P3 story named: S06 for confirmation call sites, S07 for global type, colour and stacking, S16 for the shared fragments, states and data formatting, and **S08–S12 and S15** by surface. S15 is not optional in that list – this story edits `workflow_list.html` and `dc_workflows_controller.js`, and S15 is the only owner of the workflows and projects surfaces, so a deferred workflow- or project-surface swap routed to S08–S12 lands on a story that excludes it. Known entries: the sticky settings tab-strip slab (audit `settings/tab-bar`, owner S11) and `.well-content .form-row`'s bespoke input recipe (owner S08 – its only consumer is `scheduling.html`).
  - Deferrals go into the **canonical** FIS at `dartclaw-private/docs/specs/0.22.1/fis/`, not only the `dev/bundle/` copy, which is deleted before merge – `plan.json#executionNotes` makes this the condition on success metric 5, and S14's ledger reads Implementation Observations and nothing else.
  - **Verify**: Implementation Observations lists one entry per unmade swap; every entry names a story ID drawn from {S06, S07, S08, S09, S10, S11, S12, S15, S16}, and no entry names a story that excludes the surface it defers – check each against the owning FIS's What We're NOT Doing before writing it

- [ ] **TI08** The swapped surfaces are visually clean in both themes at both viewports
  - Before TI01 starts, capture `/settings`, `/tasks`, task detail, `/memory`, `/knowledge`, `/knowledge/timeline`, `/projects`, `/workflows` and a channel detail page at the post-S04 boundary on the `visual` profile (port 3338) in dark and light at 1440px and 768px – this story's comparison baseline, since the audit's 92-screenshot capture predates the S01–S04 re-tone and cannot separate swap regressions from intended canon changes. Re-capture the same set after TI07 and diff; keep the audit capture as the milestone-level before/after reference.
  - **Verify**: every diff against the post-S04 capture traces to a TI05 plane-role correction or is recorded under TI07 – a mechanical swap introduces no other visual change; no swapped control loses its focus-visible ring, and no status is conveyed by colour alone

### Testing Strategy

_(Empty – regression proof is carried by TI04's re-pointed assertions, including the scenario-S06 toggle-guard assertion, and each task's Verify line; this story adds no new test harness.)_

### Validation

- Full-surface visual pass after each family swap and at story close: both themes, 1440px and 768px, `visual` profile (port 3338), diffed against the post-S04 capture per TI08.

### Execution Contract

- Task order is TI01 → TI02 → TI03 → TI09 → TI04 → TI05 → TI06 → TI07 → TI08; TI09 is numbered out of sequence because it was added after the family tasks were tagged, and it must land before TI04 aggregates the regression assertions.
- TI01–TI03 are one family per pass, each followed by `dart test packages/dartclaw_server/test/static/app_js_test.dart packages/dartclaw_server/test/templates/projects_test.dart packages/dartclaw_server/test/web/pages/task_detail_test.dart`, `bash dev/tools/fitness/check_design_system_sync.sh` (story-boundary invariant – it reads only the canon↔served CSS pairs and does not exercise this story's app-side edits) and a full-surface visual pass, before the next family starts – the plan riskSummary's stated mitigation for this story's latent-coupling risk.
- Expected intermediate breakage, excluded from the per-pass regression criteria and re-checked after TI03: after TI01, New Task dialog and settings fields still carry `.task-dialog`-scoped `.form-*` overrides (`app.css:2291-2325`); after TI02, `.task-dialog-tabs .tab-btn` (`app.css:2286`) is orphaned until TI03 removes the family.
- Test assertions that name a family's classes are re-pointed in the same pass that swaps that family's markup (`projects_test.dart:199` and the `.toggle-switch` 48px assertion at `app_js_test.dart:239` with TI01, the `.settings-tab*` groups with TI02, `task_detail_test.dart:80,126` and the dialog groups with TI03, the `.btn-icon-sm` 48px assertion at `app_js_test.dart:237` with TI09) – otherwise the per-pass test gate fails on its own schedule; TI04 aggregates, adds the toggle-guard assertion, and closes with the full run. `test/generated/embedded_assets_test.dart` is excluded from every pass gate for the whole story (Structural Criteria).

## Final Validation Checklist

- [ ] `bash dev/tools/fitness/check_design_system_sync.sh` exits 0, and `git status --porcelain dev/design-system/ packages/dartclaw_server/lib/src/generated/` prints nothing – this story neither authored canon nor regenerated the embedded bundle
- [ ] `dart test packages/dartclaw_server` green except `test/generated/embedded_assets_test.dart`, red since S01's first re-sync and closed by S14's single regeneration (Structural Criteria)
- [ ] The hook-preservation loop (Structural Criteria) prints nothing
- [ ] The four purge greps (TI01 `form-group`, TI02 tab tokens, TI03 `task-dialog` with preserved-hook exclusions, TI09 the five promoted names) exit exactly 1 / print nothing
- [ ] TI05's record-driven loop prints no `UNFIXED` line and one line per entry in S01's plane-role shift record
- [ ] TI08 visual pass complete; Implementation Observations carries one entry per unmade swap, each naming an owning story that does not exclude the surface

## Implementation Observations

_No observations recorded yet._
