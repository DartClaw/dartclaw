# Surface sweep: workflows, projects and settings

**Plan**: docs/specs/0.22.1/plan.json
**Story-ID**: S11

## Feature Overview and Goal

**Intent**: These three surfaces carry the release's deepest canon-adoption debt and its only silent data loss – workflow detail forks the metric, pipeline and approval families canon already ships, projects hangs its entire card anatomy on six classes that have no CSS in any stylesheet, and settings computes a dirty flag and throws it away, so unsaved edits vanish on a tab switch with no warning.

**Expected Outcomes**:

- [OC01] An operator editing settings can see whether there are unsaved changes, and switching tabs never discards them silently.
- [OC02] Workflows, projects and settings render from the canonical component families – no page-local fork of a family canon ships, and no class in their markup lacks backing CSS.
- [OC03] These surfaces state what they do not know instead of fabricating it: an unknown step count, an in-flight load and a failed load each get a designed treatment rather than zeros, a permanently disabled form, or a toast that expires.
- [OC04] Progress agrees with status: a Completed run never reports 0 %, and a Failed run's progress never renders in the success hue.


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

### From `prd.md` – "FR6: Re-sync + adoption sweep" (the adoption clusters this story owns)
<!-- source: prd.md#fr6-re-sync--adoption-sweep -->
<!-- extracted: e18cf85 -->
> […] type-tier migration; empty/loading/error state coverage (31 findings — em-dash placeholders where an absent-value treatment belongs, undesigned empty states, no skeleton/`.scan-bar` loading treatment).
>
> - [ ] Drift check green; `design-system.css` byte-identical to canon.
> - [ ] Every page has a designed empty state; no bare em-dash stands in for an absent value.

### From `prd.md` – "FR7: Glitch sweep" (closure bar)
<!-- source: prd.md#fr7-glitch-sweep -->
<!-- extracted: e18cf85; FR7 gained the durable-backlog criterion after this extraction (uncommitted) -->
> - [ ] All 23 high-severity glitches closed.
> - [ ] Remaining glitches closed or explicitly deferred with a recorded reason.
> - [ ] […elided: every deferral carried into a durable backlog, with its reason and no target milestone — the release-boundary hand-off S14 owns; this story's part is recording the deferral in its own Implementation Observations…]

### From `prd.md` – "FR1: Surface & depth revision" (contrast floor this sweep must not break)
<!-- source: prd.md#fr1-surface--depth-revision -->
<!-- extracted: e18cf85 -->
> Card-vs-ground contrast ≥ 1.15:1 in both themes; no gradient stop equals the card fill.

### From `prd.md` – "FR5: Feedback decision-table rewrite + native dialog eradication" (regression guard on the two controllers this story edits)
<!-- source: prd.md#fr5-feedback-decision-table-rewrite--native-dialog-eradication -->
<!-- extracted: e18cf85 -->
> Zero `window.alert` / `window.confirm` / `window.prompt` / bare `alert(` / `confirm(` / `prompt(` in `lib/src/static/controllers/`.

### From `prd.md` – "Non-Functional Requirements" (accessibility)
<!-- source: prd.md#non-functional-requirements -->
<!-- extracted: e18cf85 -->
> WCAG AA text contrast preserved in both themes after the surface remap; `prefers-reduced-motion` honored; focus-visible on every interactive element; status never conveyed by colour alone

### From `prd.md` – "Non-Functional Requirements" (visual quality gate)
<!-- source: prd.md#non-functional-requirements -->
<!-- extracted: e18cf85 -->
> Both themes at desktop + 768px per story; UI smoke test at phase boundaries; the 92-screenshot audit capture reused as the before/after baseline

### From `plan.json` – shared decision "Canon-first with per-story re-sync"
<!-- source: plan.json#sharedDecisions -->
<!-- extracted: 2026-07-25 -->
> Every story that changes a canon-owned rule edits `dev/design-system/` (tokens.css / components.css / icons.css / DESIGN.md / showcase.html) first, then re-syncs the served copies under `packages/dartclaw_server/lib/src/static/` — regenerating the two-line `/* Synced from … sha256: … */` provenance header — within the same story. `dev/tools/fitness/check_design_system_sync.sh` must be green at every story boundary; no story may leave canon and the served CSS divergent.

### From `plan.json` – shared decision "Surface token roles — three distinct planes"
<!-- source: plan.json#sharedDecisions -->
<!-- extracted: 2026-07-25 -->
> […] Card hover is not independent: `.card:hover` paints over the same token as card rest, so it re-derives from whatever S01 lands on. No downstream story re-tones a card, chrome, or ground locally — surface complaints go back to S01's tokens.

### From `plan.json` – shared decision "Composite type-class vocabulary"
<!-- source: plan.json#sharedDecisions -->
<!-- extracted: 2026-07-25 -->
> S02 fixes the seven composite class names, each binding font-size + weight + line-height + letter-spacing: `.t-caption`, `.t-body`, `.t-label`, `.t-heading`, `.t-page-title`, `.t-display`, `.t-metric`. All consumers apply these classes; raw `--text-*` tokens are for one-offs only, and no consumer hand-derives a tier from four separate properties.

### From `plan.json` – shared decision "Wide-container assignment"
<!-- source: plan.json#sharedDecisions -->
<!-- extracted: 2026-07-25 -->
> S02 ships `--container-wide` plus the `.content-inner--wide` / `.page-inner--wide` modifiers. Assignment is fixed here so P3 stories do not each re-litigate it: wide applies to tasks, task detail, health (dashboard + audit), memory, scheduling, workflows; the 900px measure stays for chat, session info, knowledge results and settings forms. The modifier is opt-in, never the default.

### From `plan.json` – shared decision "Visual-baseline protocol — story-start captures, not the audit set"
<!-- source: plan.json#sharedDecisions -->
<!-- extracted: 2026-07-25 -->
> Protocol: each story captures its own story-start screenshots of the surfaces it touches, in both themes at desktop and 768px, and validates against those. The audit's 92-shot set stays the release-level baseline that S14 re-proves once. A story that finds a regression outside its own scope reports it rather than absorbing it.

### From `plan.json` – shared decision "One dialog frame and one confirmation API"
<!-- source: plan.json#sharedDecisions -->
<!-- extracted: 2026-07-25 -->
> S06 ships exactly one `confirmDialog({title, body, confirmLabel, danger})` in `shared.js` plus one `htmx:confirm` listener in `dc_shell_controller.js` — every current and future confirmation routes through those two, and no story adds a second dialog implementation.


## Deeper Context

- `docs/specs/0.22.1/audit-ui-polish-2026-07-25.md#c-adoption-gaps--canon-has-the-answer-the-app-does-not-use-it-118` – the `workflow-detail` (5), `workflows` (3), `settings/all-tabs` (4), `settings/security` (3), `settings/tab-bar` (2), `settings` (1), `projects / workflows` (2), `projects / workflow-detail` (1), `projects / workflows / workflow-detail` (1) and `workflows / workflow-detail` (1) entries – per-finding evidence and the audit's own proposed fix for every adoption task below.
- `docs/specs/0.22.1/audit-ui-polish-2026-07-25.md#b-glitches--visibly-broken-no-design-decision-needed-72` – the `projects` (3), `workflows` (2), `workflows / workflow-detail` (2), `workflow-detail` (1), `settings/tab-bar` (2), `settings/agent` (1), `settings/all-tabs` (1), `settings/security` (1), `settings/restart-banner` (1) entries – measured pixel evidence per glitch.
- `docs/wireframes/settings-page.html`, `docs/wireframes/settings-page-providers.html` – intended settings card grouping and field density.
- `docs/wireframes/workflow-list.html`, `docs/wireframes/workflow-run-board.html`, `docs/wireframes/workflow-detail.html`, `docs/wireframes/workflow-step-detail.html` – intended run-board and pipeline anatomy.
- `docs/wireframes/project-management.html` – intended project card anatomy.
- `../dartclaw-public/dev/guidelines/TRELLIS-GUIDELINES.md` – `tl:` attribute and escaping rules for every template edit here.
- `../dartclaw-public/dev/guidelines/HTMX-GUIDELINES.md` – swap-target and `hx-trigger` patterns for the projects in-place refresh.
- `../dartclaw-public/dev/testing/UI-SMOKE-TEST.md` – TC-09 (Settings), TC-26 (Workflows List), TC-27 (Workflow Run Detail), TC-29 (Projects List) are this story's live smoke cases.


## Acceptance Scenarios

- [ ] **S01 [OC01] [TI02] Save reflects whether there is anything to save**
  - **Given** `/settings` is loaded on the `visual` profile and the Agent card's fields hold their persisted values
  - **When** the operator types a new value into Max Turns and then restores the original value
  - **Then** the Save control becomes actionable while the value differs and returns to its non-actionable state once it matches again, and pressing Save on the pristine form is not the way the operator learns there were no changes

- [ ] **S02 [OC01] [TI02] Switching tabs with unsaved edits does not discard them silently**
  - **Given** the Agent card has an edited, unsaved Model value
  - **When** the operator clicks the Providers tab
  - **Then** the operator is warned the edit is unsaved before the Agent card is hidden; dismissing the warning leaves the operator on the Agent tab with the edit intact, and confirming proceeds to Providers – in no path is the card hidden without the operator having seen the warning

- [ ] **S03 [OC02] [TI13,TI14,TI15] Workflow detail renders from the canonical families, not its own fork**
  - **Given** a workflow run with steps in mixed states, including one awaiting approval, on the `visual` profile
  - **When** `/workflows/{runId}` renders
  - **Then** the KPI row is `.card card-metric` tiles, the run spine is an `<ol class="pipeline">` of `.pipeline-step--{done|running|failed|blocked|pending}` with `.pipeline-node`, the approval step body is an `.approval-card` with `.approval-card-plan` and `.approval-card-actions`, and `.metric-card`, `.workflow-pipeline` and `.workflow-step-card` appear nowhere in the response

- [ ] **S04 [OC02] [TI08,TI09] A project card is composed from canon and refreshes in place**
  - **Given** `/projects` shows a project badged Error carrying the message "GitHub projects require a GitHub token credential reference."
  - **When** the page renders and the operator then removes a project
  - **Then** the error message renders as `banner banner-error` with its alert glyph, the card's actions sit right-aligned in a `.card-header` row, every class in the card resolves to a rule in `design-system.css` or `app.css`, and the removal swaps `#projects-content` rather than reloading the document

- [ ] **S05 [OC03] [TI12] An unknown step count is stated as unknown, not fabricated as zero**
  - **Given** a Completed run whose stored `definitionJson` fails `WorkflowDefinition.fromJson`
  - **When** `/workflows` renders that run's card
  - **Then** the step count renders the canonical absent-value treatment instead of "0/0 steps" and no `.meter` is emitted for that card

- [ ] **S06 [OC04] [TI12] Progress never contradicts run status**
  - **Given** one Failed run and one Completed run, both with a parseable definition
  - **When** `/workflows` and `/workflows/{runId}` render them
  - **Then** the Completed run reports 100 % rather than a step-derived shortfall, and the Failed run's percentage and meter fill resolve from `--error` rather than `--accent`, so the two runs are distinguishable without reading the badge

- [ ] **S07 [OC03] [TI05,TI07] Settings says what it knows when it knows nothing**
  - **Given** `/api/config` returns an error for the settings page load, and `agent.effort` still declares no allowed values
  - **When** `/settings` renders and the fetch rejects
  - **Then** the card body carries a persistent `banner banner-error` with a Retry control rather than 22 permanently disabled inputs behind an expired toast, in-flight fields render `.skeleton` rather than `placeholder="Loading..."`, and the Effort control is not presented as an enabled picker whose only option is blank


## Structural Criteria

- [ ] Story-start captures of `/settings`, `/projects`, `/workflows`, `/workflows/{runId}` and a workflow step detail exist in both themes at 1440px and 768px, and every close-out diff against them traces to a task in this FIS or is reported rather than absorbed.
- [ ] `settings.html`'s tab strip carries `role="tablist"`, each control carries `role="tab"` with `aria-selected` and `aria-controls`, each panel carries `role="tabpanel"`, panels toggle the `hidden` attribute rather than inline `display`, and no `aria-current="page"` remains on a tab.
- [ ] Every `settings.html` field cluster sits inside a `.well`, and no short numeric control (Port, Max Turns, Reset Hour) stretches to the container measure.
- [ ] `app.css` declares no rule head for a family canon ships: `.metric-card`, `.workflow-metrics-grid`, `.workflow-pipeline`, `.workflow-step-*`, `.workflow-run-card`, `.workflow-run-link`, `.workflow-run-meter`, `.btn-active`, and the `.guard-editor-table` border / `th` / padding declarations `.data-table` already provides.
- [ ] Every class emitted by `projects.html`, `workflow_list.html`, `workflow_detail.html` and `settings.html` resolves to a rule in `design-system.css` or `app.css`.
- [ ] The composite `.t-*` classes carry the type on all five swept routes, this story adds no new `--text-sm` usage, and `--container-wide` is applied only where the plan's wide-container decision assigns it.
- [ ] Card-vs-ground contrast is ≥ 1.15:1 and WCAG AA text contrast holds on the swept routes in both themes; no status on these surfaces is conveyed by colour alone.
- [ ] `dev/tools/fitness/check_design_system_sync.sh` exits 0, this story leaves `lib/src/generated/embedded_assets.g.dart` untouched, and the existing template and JS tests pass with assertions re-pointed at the canonical classes.
- [ ] No `window.alert` / `window.confirm` / `window.prompt` / bare `alert(` / `confirm(` / `prompt(` appears in `dc_settings_controller.js` or `dc_projects_controller.js`.


## Scope & Boundaries

### Work Areas
- `templates/settings.html` + `static/controllers/dc_settings_controller.js` – ten-tab strip, 31 form fields, guard-editor table, dirty state, load/failure states.
- `templates/projects.html` + `static/controllers/dc_projects_controller.js` – card anatomy composed from canon, in-place refresh.
- `templates/workflow_list.html`, `templates/workflow_detail.html`, `templates/workflow_step_detail.html` – status filters, run cards, pipeline spine, approval body, empty states, section labels.
- `web/pages/workflows_page.dart` + `templates/workflow_detail.dart` + `static/controllers/dc_workflows_controller.js` – the step-count and progress view-model behind S05/S06, and the step selectors that move with the pipeline markup.
- `static/app.css` – deletion of the forked families and the fallout their removal leaves behind.
- `test/static/app_js_test.dart`, `test/static/workflow_controller_test.dart`, `test/templates/projects_test.dart`, `test/templates/workflow_list_template_test.dart`, `test/templates/workflow_detail_template_test.dart`, `test/web/pages/workflows_page_test.dart` – re-pointed assertions plus the new dirty-state and progress guards.

### What We're NOT Doing
- The restart-banner missing-`.btn` fix (`restart_banner.html`) -- the audit records it twice, as `settings/restart-banner` and as `shell/restart-banner`; S12 owns the shell surface, and two parallel W2 stories editing one file is a merge conflict for no gain. Report it to the orchestrator, do not fix it here.
- `allowedValues` for `agent.effort` / `agent.provider` in `dartclaw_config` -- a config-metadata change that alters the `/api/config` meta payload, and the legal value set is a product decision; barred by the no-backend-work constraint. Record as a deferral for the S14 glitch ledger; TI07 closes the UI half only.
- Settings information architecture -- regrouping ten flat tabs into 3–4 sections and surfacing pending-pairing counts on the tab strip are new UX capabilities, barred by Out of Scope. Record both as deferrals with reasons.
- DM and group allowlist delete confirmations (`dc_settings_controller.js`) -- S06 recorded these as deferrals for the S14 ledger when it scoped the single confirmation API; this story does not re-open that decision.
- Workflow authoring and run-launch surfaces -- deferred to 0.25/0.26 per the plan's story boundary.


## Architecture Decision

**Approach**: adopt, do not extend – every fork on these three surfaces is deleted from `app.css` and its markup re-rendered from the canon family that already ships (`.card-metric`, `.pipeline`, `.approval-card`, `.run-card`, `.data-table`, `.tabs`, `.well`, `.empty-state`); the only genuinely new logic is settings dirty state and an honest step count in the workflows view-model.
**Why this over alternatives**: styling the six dead `.project-card-*` classes, or patching `.workflow-step-*` in place, would leave two implementations of families canon already defines – a divergence the drift check cannot see, and exactly the rot 0.22 produced.


## Technical Overview


## Code Patterns & External References

```
# type | path#anchor or url                                                          | why needed (intent)
file   | dev/design-system/components.css#.run-card--attention                       | Run-board card is composition-first: `.card run-card`, plus `.run-card-step`; copy the anatomy, do not re-declare it
file   | dev/design-system/components.css#.pipeline                                   | Canon run spine: `.pipeline-step--{state}` + `.pipeline-node` (pulse ring on running, dashed connector on pending)
file   | dev/design-system/components.css#.approval-card--waiting                     | Approval gate anatomy: `.card approval-card approval-card--{waiting|approved|rejected|expired}` + `-meta` / `-plan` / `-actions` / `-resolution`
file   | dev/design-system/components.css#.data-table                                 | Open-header table treatment replacing the boxed `.guard-editor-table` grid
file   | dev/design-system/showcase.html                                              | Rendered reference for the run-card, pipeline and approval-card panels being adopted
file   | packages/dartclaw_server/lib/src/templates/components.dart#metricCardTemplate | Shared `.card.card-metric.card-metric--{color}` emitter; follow `templates/memory_dashboard.dart` for how a page feeds it
file   | packages/dartclaw_server/lib/src/templates/workflow_detail.html              | The `banner banner-error` + Retry block in the step-detail slot is the in-page failure recipe TI05 reuses on settings
file   | packages/dartclaw_server/lib/src/web/pages/workflows_page.dart#_stepStatusForRunDetail | Where step status is derived; the null-definition and terminal-status coupling in TI12 belong beside it
file   | packages/dartclaw_server/lib/src/static/controllers/dc_settings_controller.js#updateFormDirtyState | Computes `dirty` and discards it; TI02's outcome is that its result reaches observable state
file   | packages/dartclaw_server/lib/src/static/controllers/dc_projects_controller.js#removeProject | Post-S06 confirmation call site; TI09 changes only what follows it
wire   | docs/wireframes/workflow-run-board.html                                      | Intended run-board density and status signalling
```


## Constraints & Gotchas

- **Assumption**: `web/pages/workflows_page.dart` and `templates/workflow_detail.dart` are in scope. The plan's overview summarises the release as "CSS, Trellis template, or Stimulus controller work", but the binding constraint is narrower and governs: "any finding needing a service, schema or API change". These two files are the presentation view-model that feeds the Trellis templates – no service, schema or API contract moves – and TI12's findings cannot be closed without them. Flagged to the plan orchestrator rather than resolved here.
- **Assumption**: the plan's wide-container decision names "workflows" without naming workflow detail, while it names "tasks, task detail" as an explicit pair. Read conservatively – the modifier is opt-in and never the default – `--container-wide` therefore goes to the workflows *list* only. If the orchestrator intended workflow detail too, that is a one-line change to TI17.
- **Critical**: `test/templates/tasks_s11_test.dart` is pre-existing and belongs to a *previous* milestone's story numbering -- it is not this story's test file and must not be repurposed. New assertions go in the files named under Work Areas.
- **Constraint**: S05 already swapped these templates onto the canonical `form-*`, `tabs` / `tab` and `dialog` classes and deleted the app-local originals -- Workaround: locate call sites by role, not by the audit's pre-S05 class names or line numbers, which have all moved.
- **Constraint**: this story runs in the same parallel wave as S08–S10, which also edit `app.css` -- Workaround: confine edits to the `.workflow-*`, `.metric-card`, `.project-*` and settings blocks this FIS names; do not reflow unrelated regions of the file.
- **Avoid**: regenerating `lib/src/generated/embedded_assets.g.dart` -- Instead: leave it stale; S14 owns the single end-of-release regeneration, and doing it per story conflicts across the P3 waves.
- **Avoid**: fixing a surface complaint by re-declaring a card, chrome or ground tone locally -- Instead: report it against S01's tokens per the surface-token shared decision.
- **Critical**: any rule this story needs that canon should own (for example the sticky tab strip's material) is a canon change -- Must handle by: editing `dev/design-system/` first and re-syncing the served copy with a regenerated `sha256:` provenance header in the same task, so the drift check stays green at the story boundary.


## Implementation Plan

### Implementation Tasks

- [ ] **TI01** This story has its own before-image to validate against
  - Capture `/settings`, `/projects`, `/workflows`, `/workflows/{runId}` and a workflow step detail on the `visual` profile (port 3338, `bash dev/testing/profiles/visual/run.sh`) in dark and light at 1440px and 768px, per the plan's visual-baseline shared decision – the audit's 92-shot set predates S01's re-tone and cannot isolate this story's deltas.
  - **Verify**: 20 story-start captures exist (5 routes × 2 themes × 2 viewports) and are the diff target used at story close

- [ ] **TI02** The settings form's dirty state is observable, and a tab switch cannot discard it silently
  - `dc_settings_controller.js#updateFormDirtyState` currently computes `dirty` and returns without using it (its six call sites already fire on `input`, `change`, submit-failure and cancel); its result must reach the form and the Save control, and `dc_settings_controller.js#activateSettingsTab` must consult it before hiding a card. No second dialog implementation: any warning routes through the `confirmDialog({title, body, confirmLabel, danger})` helper S06 put in `shared.js`.
  - **Verify**: `Test: app_js_test.dart asserts updateFormDirtyState assigns its computed dirty result to observable form/button state and that activateSettingsTab consults it before hiding a card – each assertion fails when its declaration is removed`; live on `/settings`, scenarios S01 and S02 hold, and `rg -n 'window\.(alert|confirm|prompt)|[^.a-zA-Z](alert|confirm|prompt)\(' lib/src/static/controllers/dc_settings_controller.js` exits with code exactly 1

- [ ] **TI03** The settings tab strip is a real tab widget and all ten sections are reachable at 768px
  - Post-S05 the strip carries the canonical `tabs` / `tab` classes; this task adds the semantics S05 left alone – `role="tablist"` on the strip, `role="tab"` + `aria-selected` + `aria-controls` per control, `role="tabpanel"` + `id` per `[data-tab]` card, the `hidden` attribute in place of inline `display`, and `aria-current="page"` dropped. S03's `.tabs--sticky` already takes its background from S01's token, so check the sticky strip first; if it still paints a flat slab over the body gradient (S05 recorded that finding as owned here), the correction goes on the canonical rule in `dev/design-system/components.css` and is re-synced, never into `app.css`.
  - **Verify**: `rg -n 'role="tablist"|role="tab"|role="tabpanel"|aria-selected|aria-controls' lib/src/templates/settings.html` returns all five and `rg -n 'aria-current' lib/src/static/controllers/dc_settings_controller.js` exits with code exactly 1; at 768px the tenth tab ("Security") is reachable and none is clipped mid-word; the sticky strip shows no hard seam against the body gradient in light theme at scroll-top

- [ ] **TI04** A settings card reads as heading → label → value, and short fields are short
  - Cluster each card's semantically related fields (the four workflow role pairs, the four Server sub-cards) in `.well` with a `.t-caption` uppercase cluster label per canon § Wells; move the card title to `.t-heading` and the field value below `.t-label` so three sizes are visible. Capping Port, Max Turns and Reset Hour needs a field-width scale canon does not ship (S03 declined the audit's `--num` / `--short` suggestion) – add it canon-first to `dev/design-system/components.css` and re-sync in this task; an `app.css` width cap on a canon form class fails the drift check. The always-on "Changes apply after a server restart" note becomes plain `--fg-overlay` helper copy on a single divider, so the undiluted `--warning` token means the actual pending-restart state.
  - **Verify**: `rg -c 'class="well' lib/src/templates/settings.html` is at least 8, `rg -n 'section-note-restart' lib/src/static/app.css` shows no `--warning` blend, and the new width modifier resolves to a rule in `design-system.css`, not `app.css`; on `/settings` the Agent card renders "Agent Configuration", "Provider" and the value at three distinguishable sizes, and Max Turns is visibly narrower than the card

- [ ] **TI05** Settings has a loading treatment and a failure that outlives a toast
  - In-flight fields render `.skeleton` / `.skeleton-text` rather than 22 `placeholder="Loading..."` disabled inputs; on populate, a nullable field's placeholder states the effective/inherited default rather than being cleared; on `/api/config` rejection the card body carries a persistent `banner banner-error` with a Retry control, following the recipe already in `templates/workflow_detail.html`'s step-detail error slot. TI02's dirty tracking must survive a Retry-driven repopulate.
  - **Verify**: `rg -n 'placeholder="Loading\.\.\."' lib/src/templates/settings.html` exits with code exactly 1 (no match; `rg -c` would print nothing rather than `0`) and `rg -n 'skeleton|banner banner-error' lib/src/templates/settings.html lib/src/static/controllers/dc_settings_controller.js` returns both; scenario S07 holds with `/api/config` forced to fail, and the failure state is still on screen after 10 s

- [ ] **TI06** The guard-extension table is the canonical open-header table
  - `settings.html`'s `guard-editor-table` markup carries `class="data-table guard-editor-table"`, and the `app.css` rule keeps only the genuinely local parts (`min-width`, the mono/break-all value cell), deleting the per-cell borders, the bare uppercase `th` and the padding that `dev/design-system/components.css#.data-table` already provides.
  - **Verify**: `rg -n 'class="data-table guard-editor-table"' lib/src/templates/settings.html` returns the markup and `awk '/\.guard-editor-table/,/}/' lib/src/static/app.css | rg -n 'border|text-transform|padding'` exits with code exactly 1; the table renders with a bottom-rule header at `tracking-caps` and a row hover, matching the guard-editor wireframe

- [ ] **TI07** The Effort control never presents an enabled picker whose only choice is blank
  - `agent.effort` declares no allowed values in config metadata and adding them is out of scope here, so the control must not claim to be settable: give the empty option a real label ("Default") and leave the control non-actionable while its allowed-value list is empty. The unconditional enable is in `dc_settings_controller.js`'s populate path, which currently clears `disabled` for every field regardless of whether options were injected. Record the `allowedValues` half as an explicit deferral for the S14 glitch ledger, with the reason.
  - **Verify**: `rg -n '<option value="">—</option>' lib/src/templates/settings.html` exits with code exactly 1; on `/settings` the Effort field is not a focusable picker offering a single blank row, and the deferral is recorded in Implementation Observations

- [ ] **TI08** Every class a project card emits has backing CSS, because the card is composed from canon
  - `.project-card-header`, `-title-row`, `-actions`, `-meta`, `.project-error-banner` and `.project-url` have zero rules in any served stylesheet today; recompose the card from `.card-header` (title + badges + actions right-aligned), `.card-footer` for the meta row, and `banner banner-error` with `icon-triangle-alert` for the error line. Promote the card's single visible action off `.btn-ghost`, which at rest reads as prose.
  - **Verify**: `rg -n 'project-card-|project-error-banner|project-url' lib/src/templates/projects.html` exits with code exactly 1; `Test: projects_test.dart asserts the error project renders "banner banner-error" and that the card's action row is inside .card-header`

- [ ] **TI09** Project mutations refresh the list without discarding the page
  - The four `window.location.reload()` calls in `dc_projects_controller.js` (add, edit, fetch and – following S06's confirmation change – remove) swap `#projects-content` via htmx instead, preserving scroll position and sidebar state. S06 owns the confirmation itself; this task changes only what happens after it resolves.
  - **Verify**: `rg -n 'location\.reload' lib/src/static/controllers/dc_projects_controller.js` exits with code exactly 1, `rg -n '#projects-content' lib/src/static/controllers/dc_projects_controller.js` returns the swap target, and `rg -n 'window\.(alert|confirm|prompt)|[^.a-zA-Z](alert|confirm|prompt)\(' lib/src/static/controllers/dc_projects_controller.js` exits with code exactly 1; removing a project on `/projects` updates the list with the sidebar and scroll position intact

- [ ] **TI10** The workflow status filter reads as a selection, not a hover artifact
  - `workflow_list.html`'s six status filters render with the canonical `tabs` / `tab` component (accent text + accent underline) and the page-local `.btn-active` rule is gone, so a selected filter is distinguishable from `.btn-ghost:hover`. Keep the existing `hx-get` / `hx-target` / `hx-push-url` attributes on each control unchanged.
  - **Verify**: `rg -n 'btn-active' lib/src/static/app.css lib/src/templates/workflow_list.html` exits with code exactly 1; on `/workflows` the selected filter shows accent text and an accent underline, and clicking another filter still pushes the URL and swaps `#main-content`

- [ ] **TI11** Workflow run cards are canon run cards at canon density
  - `workflow_list.html`'s run rows render as `.card run-card` with `.run-card-step`, dropping the inner `.workflow-run-link` padding so `.card` owns the inset, and the `app.css` `transition` and `:hover` overrides that flatten the canon lift and accent glow are gone. The 60×4px `.workflow-run-meter` no longer contradicts the canon `.meter`.
  - **Verify**: `rg -n '^\.workflow-run-(card|link|meter)' lib/src/static/app.css` exits with code exactly 1 and `rg -n 'card run-card' lib/src/templates/workflow_list.html` returns the run row; a two-line run card measures materially shorter than its ~110px pre-story height and hovers with the canon lift rather than a flat fill

- [ ] **TI12** Workflow progress states only what the run actually reports
  - In `workflows_page.dart` (list) and `templates/workflow_detail.dart` (detail): when the stored definition is absent or unparseable, emit canon's `.value-absent` treatment in place of "0/0 steps" and no `.meter` element at all – an unknown total is not a 0 % of a known total, so S03's `.meter--empty` is the wrong reach here; for terminal statuses, couple progress to `run.status` so Completed reads 100 %; and drive the percentage and meter fill from status (`--error` on failed, `--warning` on paused/cancelled) instead of a fixed `--accent`. Presentation-layer view-model only – no service, schema or API change (see the scope assumption in Constraints & Gotchas).
  - **Verify**: `Test: workflows_page_test.dart asserts a run with unparseable definitionJson renders .value-absent with no .meter and no "0/0 steps", a Completed run renders 100%, and a Failed run's progress resolves --error not --accent`; scenarios S05 and S06 hold on the `visual` profile

- [ ] **TI13** Workflow detail KPIs sit on the same metric tier as every other dashboard
  - The four hand-written `.metric-card` divs render through `templates/components.dart#metricCardTemplate` as `.card.card-metric.card-metric--{accent|info|warning|error}` inside `.metrics-grid`, following `templates/memory_dashboard.dart`; the STATUS tile gets a real value in the value slot rather than a 12px badge, so the row shares one baseline. `.metric-card` and `.workflow-metrics-grid` leave `app.css`.
  - **Verify**: `rg -n 'metric-card' lib/src/templates/workflow_detail.html lib/src/static/app.css` exits with code exactly 1 (`card-metric` does not contain the substring, so canon usage does not mask a leftover) and `rg -n 'metricCardTemplate' lib/src/templates/workflow_detail.dart` returns the four tiles (the `card card-metric` markup itself is emitted by `components.dart`, not written in the template); they render at the canon metric tier with a shared value baseline

- [ ] **TI14** The run spine is the canonical pipeline
  - `workflow_detail.html`'s `.workflow-pipeline` / `.workflow-step-wrapper` / `.workflow-step-connector` / `.workflow-step-card` become `<ol class="pipeline">` › `li.pipeline-step.pipeline-step--{done|running|failed|blocked|pending}` › `.pipeline-node` + `.pipeline-step-body` (`.pipeline-step-name` + `.pipeline-step-meta`), mapping `queued`→`pending`, `running`→`running`, `completed`→`done`, `awaiting_approval`→`blocked`. This removes the audit's contradictory state colours (running was green-bordered with a blue icon) and the unanchored pulse bar in one move; the ~120 `.workflow-step-*` lines in `app.css` go with it. `dc_workflows_controller.js` also carries these class names in its selectors and must move with the markup; keep the `data-step-index` / `data-step-status` / `data-step-id` hooks and the `hx-get` step-detail slot working.
  - **Verify**: `rg -n 'workflow-pipeline|workflow-step-wrapper|workflow-step-connector|workflow-step-card' lib/src/templates lib/src/static` exits with code exactly 1; `Test: workflow_detail_template_test.dart asserts a running step renders .pipeline-step--running with .pipeline-node and a pending step renders .pipeline-step--pending`; expanding a step still loads its detail

- [ ] **TI15** An approval gate renders as the governance object canon defines
  - The approval step body becomes `.card approval-card approval-card--waiting` with `.approval-card-plan` for the request text and `.approval-card-actions` for the footer, and the resolved states use `--approved` / `--rejected` / `--expired` with `.approval-card-resolution`; the bare `.workflow-approval-detail` / `-message` / `-feedback` divs are retired. Status must not rest on colour alone – keep a text cue beside the state.
  - **Verify**: `rg -n 'workflow-approval-' lib/src/templates lib/src/static` exits with code exactly 1; a waiting approval renders `.approval-card--waiting` with a visible non-colour state cue, and an approved one renders `.approval-card-resolution`

- [ ] **TI16** The workflow pages have one source of vertical rhythm, no empty action rail, and designed empty states
  - Drop the redundant `margin-bottom` from the `.workflow-*` blocks and let `.content-inner`'s gap own spacing; guard the always-rendered `.workflow-actions` with a `hasActions` condition computed in `workflow_detail.dart` so a Completed run stops paying ~64px for an empty flex box. Both pages' empty states use the full `.empty-state` recipe (icon, `.empty-state-title`, text, primary CTA) – "No workflow runs found." and "No steps defined." are currently a bare span and a stray sentence. `workflow_list.html`'s "Available Workflows" moves off the sidebar's inset `.sidebar-section-label` onto `.section-label`, with a peer label above the runs list.
  - **Verify**: `rg -n 'sidebar-section-label' lib/src/templates/workflow_list.html` exits with code exactly 1 and `rg -c 'class="section-label"' lib/src/templates/workflow_list.html` returns 2 (runs list and definitions); on a Completed run there is no ~100px void between the progress row and the pipeline, and both empty states render an icon, an `.empty-state-title` and a CTA

- [ ] **TI17** The swept surfaces carry canon type and the container tier the plan assigns them
  - Apply the composite `.t-*` classes (`.t-caption`, `.t-body`, `.t-label`, `.t-heading`, `.t-page-title`, `.t-display`, `.t-metric`) across `settings.html`, `projects.html`, `workflow_list.html` and `workflow_detail.html` so card titles step above their own metadata rather than sitting 1px apart. The remaining `--text-sm` call sites live in `app.css` and belong to S07; this story must not add one while editing the same file.
  - **Verify**: `git diff -U0 "$(git merge-base main HEAD)" -- packages/dartclaw_server/lib/src/static/app.css | grep '^+' | grep 'var(--text-sm)'` prints nothing (merge-base against the working tree, so committed and uncommitted story work are both covered); `rg -n 'content-inner--wide|page-inner--wide' lib/src/templates` matches `workflow_list.html` and no other file this story touches; measured card-vs-ground contrast on all five routes is ≥ 1.15:1 in both themes and text contrast meets WCAG AA

- [ ] **TI18** Canon and the served CSS are provably identical, and the test suite guards the new shapes
  - Re-sync any canon file TI03 had to touch with a regenerated two-line `/* Synced from … sha256: … */` header (run `date +%Y-%m-%d` for the date). Re-point existing assertions at the canonical classes, preserving each assertion's original intent, in every test that names a retired class – `projects_test.dart`, `workflow_list_template_test.dart`, `workflow_detail_template_test.dart`, `app_js_test.dart`, plus `test/static/workflow_controller_test.dart` and `test/web/pages/workflows_page_test.dart`, which both assert on the `.workflow-step-*` shapes TI14 retires. Leave `lib/src/generated/embedded_assets.g.dart` untouched – S14 owns the single release-level regeneration.
  - **Verify**: `bash dev/tools/fitness/check_design_system_sync.sh` exits 0; `dart test packages/dartclaw_server/test` passes; `git status --porcelain packages/dartclaw_server/lib/src/generated/embedded_assets.g.dart` prints nothing

### Testing Strategy

- The repo has no JS runtime harness (zero-npm), so TI02's dirty-state guard is a source-level assertion in `app_js_test.dart` – it must assert that the computed result reaches observable state and that the tab switch consults it, not merely that the function exists, and each assertion must fail when its guarded declaration is deleted. The live behavioural proof for S01/S02 is UI-SMOKE-TEST TC-09 on the `visual` profile, run as part of this story rather than deferred to S14.
- TI12's progress semantics are the one place a Dart-level test can assert behaviour directly: `workflows_page_test.dart` covers the null-definition, Completed and Failed cases without a browser.

### Validation

- Live UI smoke cases for this story: TC-09 (Settings), TC-26 (Workflows List), TC-27 (Workflow Run Detail), TC-29 (Projects List) on the `visual` profile at port 3338.
- Close-out visual pass against TI01's story-start captures in both themes at 1440px and 768px. A diff that does not trace to a task here is reported, not absorbed.

### Execution Contract

- TI01 must complete before any other task – its captures are the only valid comparison baseline for this story.
- TI13, TI14 and TI15 all rewrite `workflow_detail.html`; run them in that order so the KPI row, spine and approval body land on a file that is edited once per family.


## Final Validation Checklist

- [ ] Every deferral this FIS names (the `allowedValues` half of TI07, the settings IA regroup, the tab-strip pairing counts, and the `restart_banner.html` fix handed to S12) is recorded in Implementation Observations with its reason, so it counts against the release's glitch ledger rather than vanishing.


## Implementation Observations

_No observations recorded yet._
