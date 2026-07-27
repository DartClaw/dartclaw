# Surface sweep: tasks, task detail, scheduling

**Plan**: docs/specs/0.22.1/plan.json
**Story-ID**: S08

## Feature Overview and Goal

**Intent**: Tasks, task detail and scheduling are the surfaces an operator actually works in and the ones the audit found least served by the design system – table headers shatter mid-word inside a 900px column, every table draws a border over nothing, the one numeric payload on task detail renders as 14px metadata, and the scheduled-task toggle paints a blank grey square in both of its states; this story puts the operational loop onto the canon the P1 stories just revised.

**Expected Outcomes**:

- [OC01] Tabular data on tasks and scheduling is legible at a glance: headers hold one line, rows are one line tall, and each table sits on a visible surface inside the wide container tier.
- [OC02] These surfaces have a visible hierarchy – section headings sit above body text, metadata labels are readable rather than placeholder-grey, and generated payloads (KPIs, diffs, composed prompts) render in the tier and treatment canon defines for them.
- [OC03] Every control signals its state without relying on colour or an `aria-label` alone – the scheduled-task toggle, the status column, the runner cards, and the 768px layouts.
- [OC04] Absent values, empty lists and destructive confirmations each have exactly one designed treatment on these surfaces, replacing seven em-dash literals, three empty-state variants and two confirmation experiences.


## Required Context

### From `docs/specs/0.22.1/plan.json` – Binding constraint: canon-first
<!-- source: plan.json#bindingConstraints -->
<!-- extracted: e18cf85 -->
> *Constraint:* **canon-first is mandatory.** The 0.22 drift check requires `design-system.css` byte-identical to `dev/design-system/components.css`. Any app-side edit to a canon-owned rule fails CI.

### From `docs/specs/0.22.1/plan.json` – Binding constraint: zero-npm / server-first
<!-- source: plan.json#bindingConstraints -->
<!-- extracted: e18cf85 -->
> *Constraint:* zero-npm / server-first; no build step; no new runtime JS dependencies (FR8 *removes* runtime dependencies, it does not add any).

### From `docs/specs/0.22.1/plan.json` – Binding constraint: no backend work
<!-- source: plan.json#bindingConstraints -->
<!-- extracted: e18cf85 -->
> **No backend work.** Any finding needing a service, schema or API change is out of scope by definition.

### From `docs/specs/0.22.1/plan.json` – Binding constraint: out of scope
<!-- source: plan.json#bindingConstraints -->
<!-- extracted: e18cf85 -->
> New UX capabilities of any kind. This release adds no features; it refines what exists.

### From `docs/specs/0.22.1/plan.json` – Binding constraint: surface contrast (FR1)
<!-- source: plan.json#bindingConstraints -->
<!-- extracted: e18cf85 -->
> Card-vs-ground contrast ≥ 1.15:1 in both themes; no gradient stop equals the card fill.

### From `docs/specs/0.22.1/plan.json` – Binding constraint: native dialogs (FR5)
<!-- source: plan.json#bindingConstraints -->
<!-- extracted: e18cf85 -->
> Zero `window.alert` / `window.confirm` / `window.prompt` / bare `alert(` / `confirm(` / `prompt(` in `lib/src/static/controllers/`.

### From `docs/specs/0.22.1/plan.json` – Binding constraint: accessibility
<!-- source: plan.json#bindingConstraints -->
<!-- extracted: e18cf85 -->
> WCAG AA text contrast preserved in both themes after the surface remap; `prefers-reduced-motion` honored; focus-visible on every interactive element; status never conveyed by colour alone

### From `docs/specs/0.22.1/plan.json` – Binding constraint: visual quality
<!-- source: plan.json#bindingConstraints -->
<!-- extracted: e18cf85 -->
> Both themes at desktop + 768px per story; UI smoke test at phase boundaries; the 92-screenshot audit capture reused as the before/after baseline

### From `docs/specs/0.22.1/prd.md` – "FR3: Second layout container tier"
<!-- source: prd.md#fr3-second-layout-container-tier -->
<!-- extracted: e18cf85 -->
> **Description**: Add `--container-wide: 1280px` and a `.content-inner--wide` / `.page-inner--wide` modifier; document beside `container-max` in DESIGN.md § Layout. Apply to tasks, health, memory, scheduling, workflows, audit. Keep 900px for chat, session-info, knowledge results and settings forms. Add `white-space: nowrap` to `.data-table th`.
>
> **Acceptance Criteria**:
> - [ ] No table header wraps mid-word at any viewport ≥ 1024px.
> - [ ] Prose surfaces retain the 900px measure.

### From `docs/specs/0.22.1/prd.md` – "FR6: Re-sync + adoption sweep" and "FR7: Glitch sweep"
<!-- source: prd.md#fr6-re-sync--adoption-sweep -->
<!-- extracted: e18cf85; FR7 gained the durable-backlog criterion after this extraction (uncommitted) -->
> **Description**: Re-sync canon into the served CSS with the drift check green, purge app-local duplicates obsoleted by FR4, then work the 118 adoption findings. Priority clusters: health/memory/session-info metric + meter adoption; wide-container application; type-tier migration; empty/loading/error state coverage (31 findings — em-dash placeholders where an absent-value treatment belongs, undesigned empty states, no skeleton/`.scan-bar` loading treatment).
>
> **Acceptance Criteria**:
> - [ ] Drift check green; `design-system.css` byte-identical to canon.
> - [ ] […elided: `health_dashboard.html` criterion — S09's surface, not this story's…]
> - [ ] Every page has a designed empty state; no bare em-dash stands in for an absent value.
>
> **FR7 Description**: Close the 64 distinct defects catalogued in the audit. No design decisions required. […elided: the global data-formatting pass — S16's…]
>
> **FR7 Acceptance Criteria**:
> - [ ] All 23 high-severity glitches closed.
> - [ ] Remaining glitches closed or explicitly deferred with a recorded reason.
> - [ ] […elided: every deferral carried into a durable backlog, with its reason and no target milestone — the release-boundary hand-off S14 owns; this story's part is recording the deferral in its own Implementation Observations…]
> - [ ] […elided: UI smoke test TC-01…TC-31 green — a phase-boundary gate S14 owns…]

### From `docs/specs/0.22.1/plan.json` – Shared decisions this story consumes
<!-- source: plan.json#sharedDecisions -->
<!-- extracted: 2026-07-25, post-remediation plan.json -->
> **Canon-first, and canon closes after P1** — … ONLY the P1 stories S01–S04 hold that right, and only for the three DRIFT-CHECKED files — `tokens.css`, `components.css` and `icons.css`. Those close once P1 completes, because the check pins a sha256 on line 2 of each served copy and concurrent edits in the parallel P3 wave conflict on that line by construction. … **A P3 story that finds it needs a canon RULE stops and reports it for hoisting into the owning P1 story** (surfaces and chrome to S01, type and icons to S02, form/control/tab/state to S03, dialog and feedback to S04); it does not add the rule itself. `DESIGN.md` and `showcase.html` are NOT closed and NOT drift-checked — they are prose and a demo, never synced — so any story that establishes a documented contract writes it there directly, and S14 reconciles the whole document at release close.

> **Surface token roles — three distinct planes** — S01 fixes the structural rule that every later story consumes … No downstream story re-tones a card, chrome, or ground locally — surface complaints go back to S01's tokens.
>
> **Composite type-class vocabulary** — S02 fixes the seven composite class names, each binding font-size + weight + line-height + letter-spacing: `.t-caption`, `.t-body`, `.t-label`, `.t-heading`, `.t-page-title`, `.t-display`, `.t-metric`. All consumers apply these classes; raw `--text-*` tokens are for one-offs only.
>
> **Wide-container assignment** — S02 ships `--container-wide` plus the `.content-inner--wide` / `.page-inner--wide` modifiers. Assignment is fixed here so P3 stories do not each re-litigate it: wide applies to tasks, task detail, health (dashboard + audit), memory, scheduling, workflows … The modifier is opt-in, never the default.
>
> **Shared-surface ownership in the sweep phase** — … (2) OFF-SCALE FONT SIZES: **S07 alone normalizes every hard-coded off-scale font-size** (`.provider-badge`, `.channel-mode-badge`, `.workflow-artifact-badge` and siblings); sweep stories keep only their own semantic edits to those rules and must not re-declare the size.
>
> **One dialog frame and one confirmation API** — S04 ships the canonical `.dialog` family … S06 ships exactly one `confirmDialog({title, body, confirmLabel, danger})` in `shared.js` plus one `htmx:confirm` listener in `dc_shell_controller.js` — every current and future confirmation routes through those two, and no story adds a second dialog implementation. **Row-scoped destructive actions resolve to the inline `.delete-confirm-bar`, per S04's canon decision table — this covers the scheduled-TASK row delete as well as the scheduled-JOB delete, so S06 removes the native `confirm()` at that call site but the replacement pattern is S08's inline bar, not a modal. The title-not-id naming requirement travels with the pattern to S08.**

### From `docs/specs/0.22.1/canon-hoist-manifest.md` – what was hoisted out of this story
<!-- source: canon-hoist-manifest.md#hoist-table -->
<!-- extracted: 2026-07-25 -->
> | Canon change | Discovered by | Hoist to |
> |---|---|---|
> | `.data-table thead` band — canon-owned selector (`components.css:1566-1588`) | S08 D03 | **S01** |
> | `.msg-user .msg-content p` — canon-owned (`components.css:443`, `:476`) | S08 D06 | **S02** |
> | `icon-chevron-up`; icon tokens + `[data-icon]` mappings for task-event icons | S08 TI05 | **S02** |
>
> **S08** — drop the `icons.css` edit and the `components.css` edits (D03/D06); keep the app-side adoption. Canon footprint returns to zero. Its Execution Contract's S12 coordination note becomes unnecessary.


## Deeper Context

- `docs/specs/0.22.1/audit-ui-polish-2026-07-25.md#b-glitches--visibly-broken-no-design-decision-needed-72` – read the `tasks` (7), `task-detail` (4), `scheduling` (2), `scheduling (mobile)` (2), `tasks + task-detail` (1) and `scheduling, task-detail timeline` (1) sub-sections for the pixel-level *Evidence* behind every task below; the five `tasks` header findings are one defect described five ways.
- `docs/specs/0.22.1/audit-ui-polish-2026-07-25.md#c-adoption-gaps--canon-has-the-answer-the-app-does-not-use-it-118` – the `tasks` (4), `task-detail` (4), `scheduling` (4), `tasks + task-detail` (3), `tasks / scheduling / memory-dashboard` (1) and `tasks, task-detail` (1) sub-sections: which canon component each surface reinvented and what the canonical answer is.
- `docs/specs/0.22.1/fis/s01-canon-surface-ladder-depth-colour-rest-states.md` – the surface ladder this story adopts, and the `.data-table thead` band hoisted into S01 (TI04 consumes it).
- `docs/specs/0.22.1/fis/s02-canon-type-and-container-tiers.md` – the `.t-*` values, `.page-inner--wide`, and the `.data-table th` nowrap rule this story consumes; its TI12 hands dense-table overflow findings to this story. Also ships the two canon rules hoisted out of this story: the task-event icon tokens plus their `.icon-*` and `[data-icon]` mappings (TI05 consumes), and `.msg-user .msg-content p { white-space: pre-wrap }` (TI16 consumes).
- `docs/specs/0.22.1/fis/s03-canon-form-control-tab-state-primitives.md` – `.value-absent`, `.meter--empty`, `.empty-state-title`, `.list-toolbar`, `.btn-sm` shapes this story adopts.
- `docs/specs/0.22.1/fis/s04-canon-dialog-and-feedback-table.md` – the five-row feedback decision table; row-scoped destructive resolves to `.delete-confirm-bar`, which S04 promotes into canon.
- `docs/wireframes/ux-spec-empty-states.md#design-principles` – centred layout for page-level empties, placeholder rows for list/table empties, `btn-primary` for the primary action.
- `docs/wireframes/ux-spec-pagination.md` – pager shape, should any of these lists gain one.
- `../dartclaw-public/dev/guidelines/TRELLIS-GUIDELINES.md`, `../dartclaw-public/dev/guidelines/HTMX-GUIDELINES.md` – escaping rules (`tl:text` vs `tl:utext`) and fragment/swap conventions for every template edit here.
- `../dartclaw-public/dev/guidelines/VISUAL-VALIDATION-WORKFLOW.md` – the per-story gate; the `visual` profile (port 3338) is the only one rendering all three surfaces with data.


## Acceptance Scenarios

- [ ] **S01 [OC01] [TI01,TI02] Tasks table headers hold one line at the wide container tier**
  - **Given** the `visual` profile at 1440×900 with both the Review and Accepted status groups populated
  - **When** `/tasks` renders
  - **Then** the `PROVIDER`, `CREATED BY`, `CREATED`, `STATUS` and `TOKENS` headers each render their full label **unclipped** — each `th`'s `scrollWidth` is ≤ its `clientWidth`, so no label is cut off or ellipsised — the header row is one text line tall rather than three, no data row wraps `101d ago` or a project name onto a second line, the table does not overflow `.task-status-group .table-wrap` at this viewport, and `.page-inner--wide` resolves the content column wider than the 900px `--container-max`
  - **Note** "renders on one line" is *not* the falsifier here: once canon's `.data-table th { white-space: nowrap }` governs, a single line is true by construction and a still-too-narrow column fails by clipping instead of wrapping. The `scrollWidth ≤ clientWidth` check is what distinguishes a real fix from removing the override alone.

- [ ] **S02 [OC01] [TI04,TI11] Tables and the agent pool read as designed surfaces, not outlines**
  - **Given** `/tasks` and `/scheduling` in dark and light theme
  - **When** the page background immediately outside a `.table-wrap` and the table body immediately inside it are sampled
  - **Then** the two differ by ≥ 1.15:1 in both themes, the `<thead>` band is distinct from the body, and the Agent Pool renders a `.meter` whose `.meter-fill` width tracks the *active* runner percentage – 0 active shows an empty track with the `.meter--empty` treatment, not a full-width solid slab

- [ ] **S03 [OC02] [TI06,TI07,TI08,TI14] Task detail reads as a hierarchy on shared baselines**
  - **Given** a completed task with a trace summary (`traceCount > 0`) so the token block renders
  - **When** `/tasks/{id}` renders
  - **Then** every `.task-meta-label` in the meta row sits on one baseline and every value on a second, the six token KPIs render as `.card.card-metric--*` with `.metric-value` at the 32px metric tier, the `Session` / `Artifacts` / timeline panels are all canon `.card` containers on the same side of the surface ladder, and the `.task-status-group h3` / `.task-chat-column h3` / `.task-artifact-column h3` / `.agent-overview h3` headings **compute** the `.t-heading` size (18px) rather than resolving to body size — the class being present in the markup is not sufficient, since the app-local `font-size` on those rules out-specifies it (see TI14)

- [ ] **S04 [OC02] [TI09,TI16] Server-generated content renders in its intended structure**
  - **Given** a task artifact whose content is a JSON diff with at least one added line, one removed line and one hunk header, and a task session whose composed prompt begins `## Task: code-review — Publish Summary` followed by a blank line and a body paragraph
  - **When** `/tasks/{id}` renders both
  - **Then** added lines carry `.diff-line--add`, removed lines `.diff-line--del`, and the hunk header `.diff-line--hunk` – each visibly tinted rather than uniformly `--fg-sub0` – and the composed prompt's heading and body appear on separate lines instead of running together

- [ ] **S05 [OC03] [TI05,TI15] Controls and statuses carry their state in the glyph, not only in an attribute**
  - **Given** the scheduling page with one enabled and one disabled scheduled task
  - **When** their Actions cells render
  - **Then** the two toggles paint *different* glyphs (a check mask vs a circle-x mask), neither is a featureless filled square, and each button matches its `.btn-icon-sm` siblings in width
  - **And** every status cell in the tasks table renders a `.status-pill status-pill--{live|error|warning|info}` carrying a `.status-dot`, with the same status value cased identically on `/tasks` and `/tasks/{id}`

- [ ] **S06 [OC03] [TI03] At 768px the surfaces keep their state signals, geometry and borders**
  - **Given** the `visual` profile at 768px width with both scheduling tables and two consecutive tasks status groups populated
  - **When** `/scheduling` and `/tasks` render
  - **Then** the Scheduled Tasks table still shows its Status column, both tasks status tables place their surviving columns at identical x-offsets and neither overflows its wrapper, and each table's right border is visible rather than erased by the `.table-fade-wrap::after` gradient

- [ ] **S07 [OC04] [TI10,TI12,TI13] Absent values, empty lists and destructive confirmations have one treatment each**
  - **Given** a task with no `createdBy` and no final token count, a heartbeat that is disabled, a task with zero timeline events, and a scheduled task row
  - **When** each renders
  - **Then** the absent values render as `<span class="value-absent"></span>` in `--fg-sub0` rather than a literal `—` string, the disabled heartbeat renders as a status treatment rather than a 32px `Disabled` and a 32px em-dash in `.metric-value`, the timeline panel is not emitted at all, and clicking the row's delete control produces the same in-row `.delete-confirm-bar` confirmation as the Scheduled Jobs row directly above it, **naming the scheduled task by its title** — the visible confirmation text contains `task.title` and does not contain the row's id/UUID

- [ ] **S08 [OC04] [TI10] A task with events still renders its timeline and its filters**
  - **Given** the same task after five events are recorded — three `toolCalled` and two `statusChanged`
  - **When** `/tasks/{id}` renders
  - **Then** the timeline panel appears with a `.chip-row` of `button.chip[aria-pressed]` filters carrying per-filter counts (All 5, Tools 3, Status 2, Artifacts 0, Errors 0), and selecting one still pushes the `?filter=` URL and re-renders server-side
  - **And** with `?filter=tools` active the All chip still reads 5 and the Status chip still reads 2 — counts come from the unfiltered `events` argument, not from the post-`_applyFilter` list, so an implementation counting the filtered list is distinguishable here
  - **And** with `?filter=errors` active — zero matches on a task that *has* events — the panel and its chip row still render and the event list shows the empty-state treatment, so the operator can return to All without hand-editing the URL

- [ ] **S09 [OC03] [TI17] The retained `.custom-select` family still works beside the new canonical form controls**
  - **Given** the tasks filter bar (`tasks.html`) and the new-task dialog (`task_form.dart`), both of which use the app-owned `.custom-select` listbox that S05 deliberately retains per DESIGN.md § Native selects
  - **When** each renders after S03's canonical `.form-*` controls and S04's `.dialog` frame have landed
  - **Then** the `.custom-select` trigger, caret, menu, option and check parts still paint correctly in both themes, opening/closing and keyboard selection still work through `dc_shell_controller.js` / `shared.js`, the ≤768px 48px touch-target floor still applies to `.custom-select-trigger`, and the control reads as a deliberate sibling of the canonical controls rather than an unstyled leftover


## Structural Criteria

- [ ] **This story changes no canon file and re-syncs nothing.** `git diff --name-only <story-start-commit> -- dev/design-system/ packages/dartclaw_server/lib/src/static/tokens.css packages/dartclaw_server/lib/src/static/design-system.css packages/dartclaw_server/lib/src/static/icons.css` prints nothing. Canon closes after P1 (plan `sharedDecisions`, *Canon-first, and canon closes after P1*); the three rules this story previously proposed to author are hoisted — `.data-table thead` to S01, `.msg-user .msg-content p` and the task-event icon tokens/mappings to S02 (`canon-hoist-manifest.md`). Any further canon rule this story discovers it needs is **stopped and reported for hoisting**, never added here.
- [ ] `dc_tasks_controller.js` task-detail polling still starts and stops correctly. The invariant is that the badge's trimmed `textContent` remains **exactly the status label and nothing else** – `dc_tasks_controller.js` lowercases before comparing (`:385`, `:411`), so `Queued` / `Running` are fine and `task_detail.dart` already title-cases; what breaks polling is any added `.status-dot` child contributing text of its own.
- [ ] No `window.alert` / `window.confirm` / `window.prompt` / bare `alert(` / `confirm(` / `prompt(` is introduced anywhere under `packages/dartclaw_server/lib/src/static/controllers/`. (Pre-existing calls this story does not own – notably `dc_scheduling_controller.js#deleteScheduledTask` – are S06's; see What We're NOT Doing.)
- [ ] **No file under `packages/dartclaw_core/`, `packages/dartclaw_storage/` or `packages/dartclaw_server/lib/src/api/` changes at all** – no service, schema, SSE-payload or HTTP contract change, with no carve-out. `git diff --name-only <story-start-commit> -- packages/dartclaw_core/ packages/dartclaw_storage/ packages/dartclaw_server/lib/src/api/` prints nothing. TI05's emoji→mask move is therefore client-side plus templates only: the `task_event` SSE payload already carries `kind`, from which the mask class is derivable, so the payload is left untouched (see Constraints & Gotchas and the TI05 deferral).
- [ ] No new `var(--text-sm)` reference and no new literal-px `font-size` is introduced in `app.css`. Retiring the existing off-scale hardcodes (`0.625rem` on `.provider-badge`, `11px` on `.task-event`, `10px` on `.task-event-icon`) is **S07's** – this story must not re-declare those sizes (plan `sharedDecisions`, *Shared-surface ownership in the sweep phase*).
- [ ] The shared-surface edits this story makes are visually validated on the other surfaces that inherit them – memory dashboard, workflow detail and chat – not only on the three owned here. These are `.table-wrap` in `app.css` and `.provider-badge`'s `margin-left` removal (this story's only edit to that rule); the canon rules those surfaces also inherit (`.data-table thead`, `.msg-user .msg-content p`) arrive from S01/S02 and are validated here as consumers, not authors.
- [ ] The retained `.custom-select` family (`app.css:849-1000`, used by `tasks.html` and `task_form.dart`, driven by `dc_shell_controller.js` / `shared.js`) still renders and behaves correctly beside S03's canonical form controls, and is recorded in What We're NOT Doing as intentionally retained rather than an overlooked duplicate.


## Scope & Boundaries

### Work Areas
- `packages/dartclaw_server/lib/src/templates/` markup – `tasks.html`, `task_detail.html`, `scheduling.html`, `task_timeline.html`, `components.html`, `chat.html`
- `packages/dartclaw_server/lib/src/templates/` view models – `tasks.dart`, `task_detail.dart`, `scheduling.dart`, `task_timeline.dart`; `task_event_display.dart` is **read-only** (TI05 calls its existing `eventIconClass`; `compactEventIconChar` survives because its remaining caller is out of scope — see What We're NOT Doing)
- `packages/dartclaw_server/lib/src/web/pages/tasks_page.dart` – diff HTML rendering and timeline assignment
- `packages/dartclaw_server/lib/src/static/app.css` – the tasks (`~1600-1720`), task-detail (`~1770-1960`), agent-pool/timeline (`~2060-2270`), scheduling (`~1120-1160`) and shared `.table-wrap` / `.table-fade-wrap` blocks
- `packages/dartclaw_server/lib/src/templates/task_form.dart` – read-only for TI17's `.custom-select` verification (the app's `.skeleton` pattern also lives here); no edit expected
- `packages/dartclaw_server/lib/src/static/controllers/dc_scheduling_controller.js` and `dc_tasks_controller.js` – row-delete confirmation and the compact event-icon render path
- **Not in scope, listed to be explicit**: nothing under `dev/design-system/` (canon closed after P1 — TI04, TI05 and TI16 consume S01's and S02's rules), and nothing under `packages/dartclaw_server/lib/src/api/` (including `task_sse_routes.dart`)

### What We're NOT Doing
- **Any canon change at all.** Canon closes after P1: this story edits no file under `dev/design-system/` and re-syncs nothing. The three rules earlier drafts of this FIS proposed to author are hoisted (`canon-hoist-manifest.md`) — the `.data-table thead` band to S01, and both the `.msg-user .msg-content p` line-structure rule and the task-event icon tokens/`[data-icon]` mappings to S02. A canon rule this story discovers it still needs is stopped and reported for hoisting into its owning P1 story, never added here; a surface complaint goes back to the owning canon story rather than being re-toned locally.
- **Deleting or folding away the `.custom-select` family (`app.css:849-1000`: `.custom-select` plus `-trigger`, `-label`, `-caret`, `-menu`, `-option`, `-check`, and the `.native-select-hidden` child) -- intentionally retained, not an overlooked duplicate.** DESIGN.md § Native selects sanctions a custom listbox as the escape hatch where a native `<select>` cannot be branded, so it is *not* a duplicate of S03's canonical `.form-select`, and S05 deliberately left it app-owned. This story's obligation is verification only (TI17, scenario S09): confirm it still renders and behaves correctly beside the new canonical controls. Any future reader finding it beside `.form-select` should read this entry before filing it as drift.
- Adding `--icon-chevron-up` to canon -- `icon-chevron-up` is referenced at `dc_workflows_controller.js:561,576` and is genuinely missing from `icons.css`. This story's dry-run surfaced it; the hoist assigns it to **S02** along with the rest of the icon inventory, and its consumer is S15's workflows surface. This story's icon Verify stays scoped to the names its own three surfaces use, so it neither authors that token nor fails on another story's debt.
- Removing the native `window.confirm` call in `dc_scheduling_controller.js#deleteScheduledTask` -- S06 owns that call site as one of its nine. Per the plan's *One dialog frame and one confirmation API* decision, S06 removes the native call but does **not** build a modal for it: the replacement pattern is this story's inline `.delete-confirm-bar` (TI13), which owns both scheduling row deletes and the title-not-id naming that travels with the pattern.
- Retiring the SSE `task_event` payload's `iconChar` field and `task_event_display.dart#compactEventIconChar` -- `task_sse_routes.dart` lives under `lib/src/api/`, which the no-backend-work constraint puts out of scope. TI05 moves every *consumer* off the emoji path without touching the payload, so the field is left on the wire unread and its helper keeps that one caller. **Deferred with reason; record in Implementation Observations for the release ledger** — the next story that legitimately owns `lib/src/api/` deletes both.
- The `--icon-fallback` question-mark treatment the audit suggests for unmapped icon names -- it changes canon's base `.icon` / `[data-icon]::before` rules and is a new capability; recorded as a deferral, not built.
- `.run-card-step` and `.run-card--attention` on the agent-pool runner cards -- no step counter or blocked state is modelled for a pool runner; adopting them would mean inventing data.
- The task IA overhaul and any finding needing a service, schema or API change -- deferred to Cross-Surface UX and excluded by the no-backend-work constraint respectively.


## Architecture Decision

**Approach**: Adopt existing canon components on the three surfaces and delete the app-local recipes they replace. **Canon footprint is zero** — the three rules these surfaces need that canon owns (`.data-table thead`, `.msg-user .msg-content p`, the task-event icon tokens) ship from S01/S02 before this story runs, and this story consumes them. Everything this story writes is `app.css`, Trellis markup, view models and two controllers.
**Why this over alternatives**: every re-tone, re-scale and new primitive these surfaces need already landed in S01–S04, so per-page CSS would both duplicate canon and fail the byte-identity drift check. Authoring the canon rules here instead was rejected for a second reason: five parallel W2 stories each re-syncing canon collide on the served files' line-2 `sha256:` by construction, and a mechanically resolved conflict yields a red drift check that reads as a content conflict.
**Adoption is a two-part move, not one**: because `app.css` loads after `design-system.css` and its page-scoped selectors out-specify canon, applying a canonical class is inert unless the app-local declaration it replaces is deleted in the same edit. Every task below that adopts a class states the deletion explicitly; a task that only adds markup has not finished the job.


## Code Patterns & External References

```
# type | path#anchor or url                                                          | why needed (intent)
file   | packages/dartclaw_server/lib/src/static/app.css#.task-status-group          | The eight :nth-child width rules and the th/td wrapping block to re-key onto .task-col-* – the classes already exist on every th and td in tasks.html
file   | packages/dartclaw_server/lib/src/templates/tasks.html                       | Read-set for TI01/TI02/TI15: .task-col-* header/cell classes, the conditional Project column, the .task-event compact preview
file   | packages/dartclaw_server/lib/src/static/controllers/dc_scheduling_controller.js#confirmDeleteJob | The proven row-scoped .delete-confirm-bar construction to generalise for scheduled tasks (:179-213) – reuse the confirm-row insert, colSpan and row-hide handling; note it reads its label from button.dataset.jobName, which is why the task row needs an equivalent data-task-title
file   | packages/dartclaw_server/lib/src/templates/task_event_display.dart#eventIconClass | The mask-icon path (returns icon-* names) that already covers every event kind; NOTE compactEventIconClass is a different function returning task-event-icon-* COLOUR classes, and compactEventIconChar is the emoji path this story moves its consumers off
file   | packages/dartclaw_core/lib/src/task/task_event.dart#TaskEventKind | The 11 enum names the SSE payload's `kind` field carries verbatim, plus fromName's legacy alias 'error' → taskError – the key set the controller's kind→icon map must cover. Read-only
file   | packages/dartclaw_server/lib/src/static/controllers/dc_tasks_controller.js#(data.iconChar \|\| '●') | SSE consumer of iconChar/iconClass in updateDashboardEvents – moves to the mask path by deriving the icon name from data.kind, which the payload already carries, so task_sse_routes.dart is not touched. Located by call shape, not line, per Constraints & Gotchas
file   | packages/dartclaw_server/lib/src/web/pages/tasks_page.dart#_renderDiffHtml   | Diff builder emitting one <pre class="task-artifact-raw"> per hunk – the place to emit per-line .diff-line--add/--del/--hunk
file   | packages/dartclaw_server/lib/src/static/design-system.css#.diff-line         | Canon add/del/hunk treatment (the one sanctioned state-coloured exception) – match its element shape
file   | packages/dartclaw_server/lib/src/static/design-system.css#.status-pill       | Canon pill variants for table cells; .status-dot--{live|error|warning|idle|success} lives just above
file   | packages/dartclaw_server/lib/src/static/design-system.css#.chip              | Toggle-chip anatomy: button.chip[aria-pressed="true"] is the only pressed-state rule canon carries, and .chip-row is its container
file   | packages/dartclaw_server/lib/src/templates/components.dart#metricCardTemplate | Metric-card helper for the token summary; its value is rendered with tl:text and is therefore escaped
file   | packages/dartclaw_server/lib/src/templates/task_timeline.dart#taskTimelineHtml | Receives the *unfiltered* events list before _applyFilter – per-kind chip counts are derivable here with no service change
file   | packages/dartclaw_server/lib/src/templates/task_form.dart#L153              | The app's existing .skeleton placeholder pattern for htmx-loaded regions
```


## Constraints & Gotchas

- **Critical**: `app.css` loads *after* `design-system.css` (`layout.html:16-17`), so an app rule at equal specificity wins on every property it declares -- Must handle by: deleting the app-local rule when adopting a canonical class rather than layering the canonical class on top of it, otherwise the adoption is silently inert.
- **Constraint**: line numbers in the audit and in the PRD are from the pre-S05/S07/S16 build and have moved -- Workaround: locate every site by selector, symbol or call shape, never by line.
- **Avoid**: fixing a surface, type or spacing complaint in `app.css` because canon looks wrong -- Instead: the canon-owned rule belongs to its S01–S04 story; record the complaint and consume the token/class as shipped.
- **Critical**: `tl:text` escapes its value, so a `.value-absent` span cannot be smuggled through a Dart string that a template renders with `tl:text` -- Must handle by: passing the empty/absent condition into the template as a boolean and rendering the span in markup, or rendering through `tl:utext` only for values the server fully controls.
- **Constraint**: `.table-wrap` and `.provider-badge` (both app-owned) and the canon-owned `.data-table` / `.msg-content` families are shared with surfaces owned by S09, S11, S12 and S15 -- Workaround: this story writes only the two app-owned rules, and only its own semantics in them (`.provider-badge`'s sole edit here is the `margin-left` removal; S07 owns its `font-size`, per the plan's shared-surface decision). The canon-owned families arrive from S01/S02. Validate memory dashboard, workflow detail and chat alongside the three surfaces here (Structural Criteria).
- **Critical**: the compact `task_event` SSE payload must move off the emoji glyph **without touching `task_sse_routes.dart`**, which lives under `lib/src/api/` and is barred by the no-backend-work constraint -- Must handle by: deriving the mask icon in `dc_tasks_controller.js` from the `kind` field the payload already emits unconditionally (`task_sse_routes.dart:176`), not from a new payload field. Cost, accepted deliberately: the controller carries a kind→icon-name map that mirrors `task_event_display.dart#eventIconClass`, so a new `TaskEventKind` must be added in both places. It is keyed on the enum's own names and must also accept `fromName`'s legacy wire alias `'error'` (→ the `taskError` icon); TI05's Verify pins the key set to the enum so the duplication cannot rot silently.
- **Critical**: `.msg-user`, `.msg-content` and `.data-table` are **canon-owned**, not app-owned (`dev/design-system/components.css:443`, `:462-486`, `:1566-1588`), and canon is closed to this story -- Must handle by: consuming S01's `.data-table thead` band (TI04) and S02's `.msg-user .msg-content p` line-structure rule (TI16) from the *served* copies. Writing either into `app.css` breaches the plan's canon-first binding constraint even though the byte-identity script would not catch it — there is no `.msg-user .msg-content` and no `.data-table thead` rule in `app.css` today, and this story adds neither. If either rule is absent from `design-system.css` when this story starts, **stop and report it** (its P1 owner has not landed) rather than closing the gap locally.
- **Critical**: `dc_tasks_controller.js` decides whether to poll by reading `.task-meta-card .status-badge` `textContent`, trimming and **lower-casing** it, then comparing to `queued` / `running` (`:382-386`, `:408-412`) -- Must handle by: keeping any added `.status-dot` child empty so the badge's trimmed text stays exactly the status label. Case is *not* the hazard: `task_detail.dart:129` already renders `Queued` / `Running` via `titleCase`, which the lower-casing absorbs, so TI15's title-casing of the list page is safe and required.
- **Constraint**: the scheduled-tasks and scheduled-jobs mobile column-hiding rules are keyed to `:nth-child`, and the tasks table's are keyed to both `:nth-child` and `.task-col-*` -- Workaround: re-key consistently to the semantic classes so the conditional Project column (`tl:if="${showProjectColumn}"`) cannot shift every later column's width onto its left neighbour.


## Implementation Plan

### Implementation Tasks

- [ ] **TI01** Tasks, task detail and scheduling render at the wide container tier
  - Add `page-inner--wide` alongside `page-inner` on `tasks.html`, `task_detail.html` and `scheduling.html`; the modifier itself ships in `app.css` from S02 (`.page-inner--wide { max-width: var(--container-wide); }`). No other surface gains it.
  - **Verify**: `rg -l 'page-inner--wide' packages/dartclaw_server/lib/src/templates/{tasks,task_detail,scheduling}.html | wc -l` prints `3` (`-l` lists matching files and is exit-code clean; `rg -c` over multiple files prints `path:count` lines and silently omits non-matching files, so it cannot prove "one each"); at 1440px the content column measures wider than the 900px `--container-max`, and `chat`, `session_info`, `settings` and knowledge results still compute 900px

- [ ] **TI02** Tasks table headers hold one line and column widths are keyed to their semantic classes
  - In `app.css#.task-status-group`: scope the `white-space: normal; overflow-wrap: anywhere; word-break: break-word` block to `td` only so canon's `.data-table th { white-space: nowrap }` (shipped by S02) governs headers; re-key all eight width rules from `th/td:nth-child(n)` to the existing `.task-col-title/-project/-type/-provider/-created-by/-created/-status/-tokens` classes.
  - **Drop `table-layout: fixed` from the unscoped `.task-status-group .data-table` rule (`app.css:1617-1621`)** so auto layout sizes each column to its nowrap header and its content. This is the other half of what S02 handed over (`s02` § What We're NOT Doing: *"plus its `table-layout: fixed` percentage column widths"*) and what `plan.json#executionNotes` names as the proximate cause alongside `word-break`. Removing the override alone does not close FR3. TI03 re-introduces `table-layout: fixed` **inside the ≤768px media block only**, where the surviving-column geometry needs it.
  - Convert the re-keyed widths from percentages to `min-width` floors on `.task-col-created`, `.task-col-status` and `.task-col-tokens` wide enough for their labels and for `101d ago`, keeping `.task-col-title` as the flexible column that absorbs the remainder. Under auto layout percentages no longer need to sum to 100% and cannot be renormalised away — which is why widening three of eight percentage columns would not have worked.
  - Restore `overflow-x: auto` on `.task-status-group .table-wrap` with a table `min-width` so a genuinely narrow viewport scrolls instead of shattering.
  - **Verify**: `rg -c 'task-status-group .data-table (th|td):nth-child' packages/dartclaw_server/lib/src/static/app.css` returns no match — both halves, since the `td` rules carry width too (currently 11 `th` matches and 15 `td` matches, the latter including the `:1661-1665` block and the 768px rules); `rg -n 'table-layout: fixed' packages/dartclaw_server/lib/src/static/app.css` reports exactly one line and that line falls **inside** the `@media (max-width: 768px)` block (today it reports `:1620`, in the unscoped `.task-status-group .data-table` rule — a count alone cannot tell the two apart, so read the line number against the enclosing block); at 1024px and 1440px each of the `PROVIDER`, `CREATED BY`, `CREATED`, `STATUS` and `TOKENS` `th` elements has `scrollWidth <= clientWidth` (no clipped or ellipsised label — *not* "renders on one line", which `nowrap` makes true regardless) and the table does not overflow its wrapper; body rows measure one text line tall; hiding the Project column (`showProjectColumn` false) leaves every remaining column at its intended width

- [ ] **TI03** At 768px the three surfaces keep their state signals, share one table geometry and keep their borders
  - Inside the `@media (max-width: 768px)` block only, apply `table-layout: fixed` with percentage widths to the tasks table's three surviving columns so consecutive status groups align and nothing overflows the wrapper. This is the sole surviving use of fixed layout on this table — TI02 removes it from the unscoped rule — so the declaration must live in the media block, not be inherited from it.
  - On the scheduled-tasks table hide only the Type column and keep Status visible, matching the jobs table's rule: `app.css:1701-1711` currently hides `:nth-child(3)` *and* `:nth-child(4)` for `.scheduling-tasks-table`, and the columns are 1 Title, 2 Schedule, 3 Type, 4 Status, 5 Actions — so the `:nth-child(4)` block is what erases Status. The jobs table hides only `:nth-child(3)` (Delivery) and is already correct.
  - Make `.table-fade-wrap::after` (`app.css:638`, itself already inside the 768px block) stop short of the container's own border, or gate it on actual overflow, so a non-overflowing table still closes on its right edge.
  - **Verify**: at 768px both tasks status tables place their surviving columns at identical x-offsets with no horizontal overflow; the Scheduled Tasks row shows its status dot and `enabled`/`disabled` text; sampling the right edge of both scheduling tables at a header row and a body row finds the `--border` colour rather than a smooth decay to `--bg-base`

- [ ] **TI04** Every table on these surfaces sits on a visible surface
  - Give `.table-wrap` the canon card treatment (surface fill, `--shadow-sm`, `--border-highlight` top edge) in `app.css` — `.table-wrap` is app-owned (`app.css:635`; canon defines no such class), so this half is an app-side edit.
  - The `<thead>` band itself is **S01's**, hoisted there because `.data-table` is canon-owned and carries no `thead` rule today (`components.css:1566-1588`); this story consumes it and adds no `thead` rule of its own. Confirm it is present in the served copy before validating the band — if it is missing, S01 has not landed: stop and report rather than styling a canon component from `app.css`.
  - Shared with memory dashboard (`memory_dashboard.html`), which must be validated with this change; the canon `thead` rule reaches every `.data-table` in the app, so spot-check scheduling and the audit table too.
  - **Verify**: `rg -n 'data-table thead' packages/dartclaw_server/lib/src/static/design-system.css` shows S01's band (precondition — no match means stop and report, not fix here) while the same grep over `packages/dartclaw_server/lib/src/static/app.css` returns no match, before and after (dry-run: neither file matches today, so the first grep is this story's arrival gate on S01); sampled table-body fill vs the page ground immediately outside the wrapper is ≥ 1.15:1 in both themes on `/tasks`, `/scheduling` and `/memory`; the `<thead>` band is visually distinct from the first body row in both themes

- [ ] **TI05** Every icon on these surfaces resolves to a mask glyph, and the scheduled-task toggle carries its state
  - **Canon precondition, not this story's work.** S02 ships the two icon gaps into `dev/design-system/icons.css` and re-syncs: the missing `--icon-file-json` / `--icon-file-warning` / `--icon-layers` tokens plus their `.icon-*` class mappings (referenced by `task_event_display.dart#eventIconClass:11-18`, defined nowhere today), and the missing `[data-icon="check"]` / `[data-icon="circle-x"]` attribute mappings whose absence is why `scheduling.html:195`'s `data-icon="check"` paints a blank square today (the tokens and `.icon-*` classes for those two already exist at `icons.css:51`, `:63`, `:225`, `:229` — only the attribute rules were missing). Verify their arrival in the served copy first; if absent, stop and report — do not add them here.
  - In `scheduling.html` bind the toggle's `data-icon` to `${task.enabled ? 'check' : 'circle-x'}` and delete `app.css#.scheduling-action-toggle`'s `min-width: 5.5rem` (`app.css:1135`).
  - Move the compact event preview off the emoji path **without touching `task_sse_routes.dart`** (`lib/src/api/`, out of scope — see Structural Criteria). **The compact path does not currently carry a mask class** — `compactEventIconClass` (`task_event_display.dart:48-62`) returns `task-event-icon-*` *colour* classes, while the mask names come from `eventIconClass` (`:6-20`), which the compact path never calls. So each consumer carries **both**: the existing colour class and a mask class.
    - `tasks.dart` (the compact event view model, `:356`) – add a mask-class field from `eventIconClass(kind)`; drop the `iconChar` entry. The compact path has no `newStatus`, so `statusChanged` resolves through `eventIconClass`'s default to `icon-circle-check` — same value on both render paths, which is what keeps them consistent.
    - `tasks.html:58` – render `<span class="task-event-icon icon {maskClass} {colourClass}"></span>` with no text content, replacing `tl:text="${event.iconChar}"`.
    - `dc_tasks_controller.js` (the `task_event` render in `updateDashboardEvents`, located by the `data.iconChar || '●'` call shape) – build the same span, deriving the mask class from `data.kind` (already on the wire) through a module-level kind→icon-name map mirroring `eventIconClass`, keyed on the `TaskEventKind` enum names plus the legacy alias `'error'` → the `taskError` icon. Stop reading `data.iconChar`. When a kind resolves to no icon name (a kind added since the map was written), omit the `icon` and mask classes entirely rather than emitting a bare `.icon` — the base `.icon` rule paints `background-color: currentColor` under a missing mask, which is the solid-square defect this task exists to remove.
    - `task_sse_routes.dart` is **not** edited: its `iconChar` field stays on the wire unread and `compactEventIconChar` keeps that one caller. Recorded as a deferral (What We're NOT Doing) and written into Implementation Observations.
  - Add the four missing accent rules (`.task-event-icon-warning`, `.task-event-icon-compaction`, `.tl-event-warning`, `.tl-event-compaction`) beside their existing siblings in `app.css`.
  - **Verify**: `rg -n -- '--icon-file-json|--icon-file-warning|--icon-layers' packages/dartclaw_server/lib/src/static/icons.css` and `rg -n '\[data-icon="check"\]|\[data-icon="circle-x"\]' packages/dartclaw_server/lib/src/static/icons.css` both show matches (S02 arrival gate — dry-run: neither matches today, so this is a real precondition, and a miss means stop-and-report, not fix-here); `rg -n 'iconChar' packages/dartclaw_server/lib/src/templates/ packages/dartclaw_server/lib/src/static/controllers/` returns no matches (dry-run: three today — `tasks.html:58`, `tasks.dart:356`, `dc_tasks_controller.js:324`) while `rg -l 'compactEventIconChar' packages/dartclaw_server/lib/src/ | sort` prints exactly `…/api/task_sse_routes.dart` and `…/templates/task_event_display.dart` — the deferred pair, and no third file; the controller's kind map covers the whole enum — `for k in $(awk '/^enum TaskEventKind \{/,/;$/' packages/dartclaw_core/lib/src/task/task_event.dart | rg -o '^  ([a-z]\w+)[,;]' -r '$1'); do rg -q "\b$k\b" packages/dartclaw_server/lib/src/static/controllers/dc_tasks_controller.js || echo "MISSING $k"; done` prints nothing (dry-run: prints all 11 today) and `rg -q "'error'" packages/dartclaw_server/lib/src/static/controllers/dc_tasks_controller.js` succeeds for the legacy alias; every `icon-*` name returned by `eventIconClass` and every `data-icon="…"` used in `scheduling.html`, `tasks.html`, `task_detail.html` and `task_timeline.html` has a matching rule in the served `icons.css` — scope the check to these surfaces, **not** app-wide: `icon-chevron-up` (`dc_workflows_controller.js:561,576`) belongs to S02's inventory and S15's surface, so an app-wide sweep fails on debt this story does not own; an enabled and a disabled scheduled task render visibly different glyphs, both the size of their `.btn-icon-sm` siblings; a live `task_event` arriving over SSE renders the same glyph as the server-rendered row for the same kind

- [ ] **TI06** Task-detail metadata rows share one label baseline and one value baseline
  - Make `app.css#.task-meta-grid` a real two-row grid (`display: grid; grid-auto-flow: column; grid-template-rows: auto auto; align-items: start`) so pill-valued and bare-text items stop being centred independently; the class is already named `-grid`. Applies to both the meta card and the token-summary block that reuses it.
  - **Verify**: on `/tasks/{id}` in both themes and at 768px, the `TYPE`, `STATUS`, `PROVIDER` and `CREATED BY` labels share one y-offset (±1px) and their values share a second

- [ ] **TI07** Task-detail panels are all canon cards on one side of the surface ladder
  - Make `.task-timeline`, `.task-chat-embed` / `.task-no-session` and the Artifacts column use canon `.card` and delete the three bespoke `background` / `border` / `border-radius` recipes from `app.css`. They do not share a token set — `.task-timeline` (`:2130-2134`) uses `--bg-sub-base` + `--radius-lg`, while `.task-chat-embed` (`:1852-1855`) and `.task-no-session` (`:1871-1874`) use `--bg-mantle` + `--radius` — so grep for the selectors, not for a token. The Artifacts column currently drops a bare `.empty-state` straight onto the page ground.
  - **Verify**: sampled fills of the meta card, timeline panel, Session panel and Artifacts panel are identical in both themes and all sit on the same side of the page ground; each of the three recipes is gone from its own block — `for s in task-timeline task-chat-embed task-no-session; do awk -v s="$s" '$0 ~ "^\\." s "[ ,{]", /}/' packages/dartclaw_server/lib/src/static/app.css | rg -n 'background|border-radius|border:'; done` prints nothing (dry-run against current source prints all three: `--bg-sub-base`/`--radius-lg` for the first, `--bg-mantle`/`--radius` for the other two). Use the `awk -v` form, not `awk "…$s…"` — in zsh a `$s[` sequence parses as an array subscript and the command dies. (Do **not** use a whole-file `rg 'bg-sub-base|radius-lg'`: it returns ~14 unrelated matches, can never go empty because `.table-wrap` legitimately keeps a radius under TI04, and misses two of the three recipes outright. `--bg-sub-base` is also the card tone after S01's remap, so its presence is no longer evidence of a hand-rolled recipe.)

- [ ] **TI08** The task token summary renders as metric cards, not metadata rows
  - Replace the `.task-meta-grid` > `.task-meta-item` block in `task_detail.html` (Total Tokens, Input/Output, Cache, Duration, Tool Calls, Turns) with `metricCardTemplate` calls following `templates/components.dart#metricCardTemplate`, so the values reach `.metric-value` / `.t-metric`. Requires a task with `traceCount > 0` to exercise – the seeded `visual` profile tasks suppress the block.
  - **Verify**: `rg -c 'metricCardTemplate' packages/dartclaw_server/lib/src/templates/task_detail.dart` returns ≥ 1 (was 0 — the block is hand-rolled `.task-meta-item` markup today); with a seeded task carrying a trace summary, the six values render inside `.card.card-metric--*` and their `.metric-value` computes to 32px in both themes

- [ ] **TI09** Server-rendered diffs carry the canonical add / delete / hunk treatment
  - In `tasks_page.dart#_renderDiffHtml`, emit one element per line classed `.diff-line` plus `.diff-line--add` / `.diff-line--del` by leading `+` / `-` (currently every line of a hunk is joined into one `<pre class="task-artifact-raw">`), and the hunk header as `.diff-line--hunk` instead of `.empty-state-text`. Canon shapes live at `design-system.css#.diff-line` (`components.css:2223-2235`).
  - Also drop the `color: var(--fg-sub0)` declaration on `app.css#.diff-view` (`:1902`) — needed for the *unclassed* context lines, which otherwise stay muted. Note it is not what blocks the state colours: canon's `.diff-line--add` / `--del` / `--hunk` each declare their own `color`, and a direct declaration always beats an inherited one, so those three would tint correctly either way.
  - **Verify**: `rg -o 'diff-line--\w+' packages/dartclaw_server/lib/src/web/pages/tasks_page.dart | sort -u | wc -l` prints `3` — count distinct variants, not matching lines, since a single-line ternary emitting all three would satisfy a line count of 1; a rendered diff artifact shows added lines washed toward `--success`, removed toward `--error`, the hunk header toward `--info`, and context lines at the body colour, in both themes

- [ ] **TI10** Empty, absent and loading cases have one treatment each across the three surfaces
  - Suppress the timeline panel entirely when the **unfiltered** `events` argument is empty (`task_timeline.dart#taskTimelineHtml` returns empty so `task_detail.dart`'s `hasTimeline` is false). Test this *before* `_applyFilter`, which runs at `task_timeline.dart:17`: a filter that matches nothing on a task that does have events must still render the panel and its chip row, with the event list showing the empty-state treatment. Suppressing on the filtered list would delete the only control that returns the operator to All, stranding them on a URL they must hand-edit. The template already carries `hasEvents` for the inner case.
  - When shown, rebuild `.tl-filter-bar` as a `.chip-row` of `button.chip[aria-pressed]` carrying **per-filter counts** — one per existing bucket (All / Status / Tools / Artifacts / Errors), not one per `TaskEventKind`; the Status bucket aggregates `statusChanged` + `pushBack` + `tokenUpdate` per `eventMatchesFilter` (`task_timeline.dart:55-66`). Derive every count from the unfiltered `events` argument so the counts do not collapse to the active filter. Keep the existing `hx-get` / `hx-push-url` filter semantics, and delete `app.css#.tl-filter-link`. Give the Session, Artifacts and (when shown) timeline panels one `.empty-state` treatment with `.empty-state-title`. Replace the seven em-dash literals – `tasks.dart` (`finalTokenDisplay` default and fallback, `createdByDisplay`), `task_detail.dart` (`createdByDisplay`, `reasonLabel`), `scheduling.dart` (`intervalDisplay`, the Interval metric value) – with S03's `.value-absent` treatment, honouring the `tl:text` escaping constraint above. Any region on these surfaces that swaps content after first paint shows the canonical `.skeleton` / `.scan-bar` in-flight treatment following `templates/task_form.dart`; regions that are fully server-rendered on first paint are recorded as not applicable rather than given a synthetic loader.
  - **Verify**: `rg -n "'—'|\\\\u2014" packages/dartclaw_server/lib/src/templates/{tasks,task_detail,scheduling}.dart` returns no matches (dry-run confirms this matches all seven sites today — five literal em-dashes and the two `'—'` escapes in `scheduling.dart`); a task with **zero events of any kind** emits no `.task-timeline` element at all, while a task with events under `?filter=errors` that matches nothing still emits the panel and its chip row; a task with events renders `button.chip[aria-pressed]` filters whose counts are unchanged by the active filter, and `?filter=tools` still round-trips through the URL; the three task-detail panels use the same empty-state markup

- [ ] **TI11** The agent pool and its runner cards use the canonical meter and card anatomy
  - Replace `tasks.dart#_buildPoolBarHtml`'s `.agent-pool-bar` / `.bar-segment` with `.meter` + `.meter-fill` sized to the *active* percentage (0 active renders an empty track with S03's `.meter--empty`), keeping the `0/1 runners active` readout as a `.meter-label`, and delete the `.agent-pool-bar` rules from `app.css`. Rebuild the runner card as `.card.run-card` with a `.status-dot--{live|idle|error}` and a `.status-pill` footer in place of the stretched `.status-badge`, deleting `.agent-runner-card` / `.runner-metric` / `.agent-state-*` from `app.css`; `.run-card-step` and `.run-card--attention` are out of scope per What We're NOT Doing.
  - **Verify**: `rg -n 'agent-pool-bar|bar-segment|runner-metric|agent-state-|agent-runner-card' packages/dartclaw_server/lib/src/` returns no matches — `agent-runner-card` included, since the task deletes it too and it lives at `app.css:2089`, `:2125` and `tasks.dart:278`; with 0/1 runners active the pool renders an empty 6px meter track, not a full-width `--bg-surface1` slab; the `Idle` state renders as a dot plus pill sized to its content rather than a 184px full-card block

- [ ] **TI12** The scheduling heartbeat block uses the tier its content deserves
  - Stop feeding non-numeric strings through `metricCardTemplate` in `scheduling.dart`. Keep one existing `.status-badge` and remove the duplicate. When heartbeat is enabled, render its interval as a numeral plus a `MIN` unit label; when disabled, omit the interval entirely and show only the status. Delete the dead `intervalDisplay` context key that `scheduling.html` never reads.
  - **Verify**: `rg -n 'intervalDisplay' packages/dartclaw_server/lib/src/` returns no matches; enabled heartbeat renders one status plus a numeric interval and `MIN`; disabled heartbeat renders one status, no interval, no 32px `Disabled` and no 32px em-dash; the largest type on the page is a real heading

- [ ] **TI13** The two scheduling row-delete affordances resolve to one confirmation pattern
  - **This story owns the replacement pattern for both row deletes.** Per the plan's *One dialog frame and one confirmation API* decision, row-scoped destructive actions resolve to the inline `.delete-confirm-bar` (S04's canon decision table), and that covers the scheduled-TASK delete as well as the scheduled-JOB delete: S06 removes the native `window.confirm` at `deleteScheduledTask` but builds no modal for it, so the affordance is inert until this task lands the bar. Generalise `dc_scheduling_controller.js#confirmDeleteJob`'s row-scoped construction (`:179-213`) — parameterise the label and the `data-*` key it reads, keep one implementation, add no second dialog or confirmation API.
  - **The confirmation names the object by title, never by id** — the naming requirement travels with the pattern from S06's Scenario S04. `confirmDeleteJob` reads its label from `button.dataset.jobName`; the scheduled-task delete button carries only `data-task-id` today (`scheduling.html:200`), and the native call it replaces interpolated that id (`dc_scheduling_controller.js:403`: `'Delete scheduled task "' + taskId + '"?'`). So add `data-task-title=${task.title}` to that button — `task.title` is already rendered in the row's first cell (`scheduling.html:180`) — and have the generalised construction read the title for the message while the delete still fires on the id.
  - Derive the confirm row's `colSpan` from the row rather than re-hardcoding `5`; both tables happen to have five columns today, and a hardcoded span silently under-fills whichever table gains or loses one.
  - **Verify**: clicking `×` on a scheduled task and on a scheduled job produces visually identical in-row confirmations; the scheduled-task confirmation's visible text contains the task's title and does **not** contain its id/UUID (falsifier: the pre-change message is the id verbatim, so an untouched or half-migrated call site fails this); `rg -n 'data-task-title' packages/dartclaw_server/lib/src/templates/scheduling.html` shows the attribute on the delete button (dry-run: no match today) and `rg -c 'delete-confirm-bar' packages/dartclaw_server/lib/src/static/controllers/dc_scheduling_controller.js` still reports **one** construction serving both call sites; `rg -n 'confirmDialog|dialog--confirm' packages/dartclaw_server/lib/src/static/controllers/dc_scheduling_controller.js` returns no match, before and after — the row-scoped pattern is the bar, not a modal, and this file has no dialog usage today to be confused with one. **Do not assert zero `window.confirm` in this file** — `dc_scheduling_controller.js:403` is S06's call site to remove (What We're NOT Doing, Execution Contract), so a `rg 'window.confirm'` check here either fails through no fault of this story or forces it to breach its own Non-Goal. The release-wide zero-native-dialog constraint is proved by S06 and re-proved at S14, not here.

- [ ] **TI14** Type tiers, metadata colour and badge sizing follow canon on all three surfaces
  - Apply S02's composite classes: `.t-heading` on `.task-status-group h3`, `.task-chat-column h3` / `.task-artifact-column h3` and `.agent-overview h3`; `.t-caption` / `.t-body` per tier elsewhere.
  - **Adding the class is not enough — delete the app-local `font-size` it is meant to replace, in the same edit.** All three backing rules declare `font-size: var(--text-base)` at specificity (0,1,1): `.task-status-group h3` (`app.css:1610-1613`), `.task-chat-column h3, .task-artifact-column h3` (`:1848-1851`) and `.agent-overview h3` (`:2068-2071`). `.t-heading` is (0,1,0) and lives in `design-system.css`, which loads *before* `app.css`, so it loses on both specificity and order and the adoption is silently inert. Remove the `font-size` declaration from each of the three rules; keep their layout and colour declarations, which canon does not supply. This is the Critical gotcha at the top of Constraints & Gotchas, applied.
  - Move `.task-meta-label` (`:1828`), `.tl-event-timestamp` (`:2222`), `.task-goal-text` (`:1939`) and `.task-event` (`:2260`) from `--fg-overlay` to `--fg-sub0` (canon reserves `--fg-overlay` for placeholder and disabled text).
  - Drop `.provider-badge`'s baked-in `margin-left` (`var(--sp-2)`) so call sites own the spacing. **That is this story's only edit to `.provider-badge`** — the rule's off-scale `font-size: 0.625rem` is **S07's**, which owns the whole off-scale font-size sweep (plan `sharedDecisions`, *Shared-surface ownership in the sweep phase*); the same applies to `11px` on `.task-event` and `10px` on `.task-event-icon`. This story neither re-declares nor asserts those sizes, and touches neither `.channel-mode-badge` (S10's surface) nor `.workflow-artifact-badge` (**S15's** surface).
  - **Verify**: `awk '/^\.provider-badge[ ,{]/,/}/' packages/dartclaw_server/lib/src/static/app.css | rg -n 'margin-left'` prints nothing (dry-run against current source prints `margin-left: var(--sp-2);` — that declaration is exactly what this task deletes; the rule's `font-size` line is deliberately not asserted either way, since S07 owns it and this story must neither depend on nor block that edit); `for s in 'task-status-group h3' 'task-chat-column h3' 'agent-overview h3'; do awk -v s="$s" '$0 ~ "^\\." s, /}/' packages/dartclaw_server/lib/src/static/app.css | rg -n 'font-size'; done` prints nothing (dry-run against current source prints one `font-size: var(--text-base)` line per selector — those three declarations are exactly what this task deletes); in the browser all four `h3` groups **compute** 18px, visibly above body text — check the computed value, not the class list; `.task-meta-label` computes `--fg-sub0` and measures ≥ 4.5:1 against its card in both themes; the `CLAUDE` provider badge left-aligns with `0 turns` and `0 tokens` in the runner card

- [ ] **TI15** Status is conveyed by a dot and a pill, not by badge colour and inconsistent casing
  - Add an empty `.status-dot status-dot--{state}` child to the `statusBadge` fragment in `components.html`; switch the tasks-table STATUS column to `.status-pill status-pill--{live|error|warning|info}` per canon's table-cell assignment; pass `titleCase(statusName)` in `tasks.dart` so the list and detail pages case the same value identically. Depends on TI14's tier work for the pill's text treatment.
  - **Verify**: `rg -l 'status-pill' packages/dartclaw_server/lib/src/templates/ | wc -l` prints ≥ 1 (was 0 under `templates/`; `status-pill` does already exist in served canon `design-system.css:1283-1319`, which is the point — canon has the component and the app never used it); a task shown as `Accepted` on `/tasks/{id}` reads `Accepted` in the `/tasks` table; every `.status-badge` renders a dot and its trimmed `textContent` is still exactly the status label with no text contributed by the dot — `dc_tasks_controller.js` lower-cases before comparing, so the title-cased label is fine and polling still starts on `queued` / `running`

- [ ] **TI16** The task session's composed prompt keeps its line structure
  - The task session's "user" message is server-composed markdown, not browser free-text, and currently collapses onto one line with a literal `##` visible. The fix is `.msg-user .msg-content p { white-space: pre-wrap }` — preserving line structure without turning free-text chat input into rendered markdown.
  - **The rule is S02's, not this story's.** There is no `.msg-user .msg-content` rule in `app.css`; `.msg-user` (`components.css:443`) and `.msg-content p` (`:476`) are both canon-owned, and canon closed after P1, so the rule was hoisted into S02 (`canon-hoist-manifest.md`). This task's work is consumption plus the surface-level verification that motivated it: task detail is where the defect is visible. Writing the rule into `app.css` would style a canon component app-side against the plan's canon-first constraint; if it has not arrived from S02, stop and report.
  - Shared with the chat surface (S12) — because the rule now ships from a serial P1 story rather than from two parallel W2 stories, there is no `components.css` edit to coordinate. Still validate chat alongside task detail: this task's Verify is the second consumer's proof that S02's rule regressed neither surface.
  - **Verify**: `rg -n 'msg-user .msg-content p' packages/dartclaw_server/lib/src/static/design-system.css` shows S02's rule (precondition — dry-run: no match today, and no match at story start means stop and report) while the same grep over `packages/dartclaw_server/lib/src/static/app.css` returns no match, before and after; on `/tasks/{id}` for a workflow task, the composed prompt's `## Task: …` heading line and its body paragraph render on separate lines; a multi-line message typed in `/chat` keeps its breaks, no free-text input is parsed as markdown, and no message gains doubled blank lines from `pre-wrap` stacking on the existing paragraph margins

- [ ] **TI17** The three surfaces validate clean against the story-start baseline, and the retained `.custom-select` still works
  - Run the `visual` profile (`bash dev/testing/profiles/visual/run.sh`, port 3338) and compare `/tasks`, `/tasks/{id}`, `/tasks/{id}` for a workflow task and `/scheduling` against **this story's own story-start captures** in both themes at 1440×900 and 768px, plus the three shared-surface consumers named in the Structural Criteria. Per the plan's *Visual-baseline protocol* shared decision, the audit's 92-shot set is the release-level baseline S14 re-proves once — it cannot isolate this story's deltas, because S01 re-toned every surface and S02 re-scaled its type before this story ran. Record every audit finding for these surfaces as closed or explicitly deferred with a reason in this FIS's Implementation Observations block, for orchestrator transfer to the release glitch ledger. Per `plan.json#executionNotes`, deferrals go into the **canonical private FIS** (`dartclaw-private/docs/specs/0.22.1/fis/`), not only the `dev/bundle/` copy, which is deleted before merge. Four deferrals are known before execution and must appear by name: the unread SSE `iconChar` field plus `compactEventIconChar` (TI05, blocked by the no-backend-work constraint), the `--icon-fallback` treatment, `.run-card-step` / `.run-card--attention`, and the task IA overhaul.
  - **`.custom-select` regression check (scenario S09)**: exercise the tasks filter bar (`tasks.html`) and the new-task dialog (`task_form.dart`) in both themes and at ≤768px. Confirm the trigger, caret, menu, option and check parts still paint, open/close and keyboard selection still work through `dc_shell_controller.js` / `shared.js`, the 48px mobile touch-target floor still applies to `.custom-select-trigger`, and the control sits beside S03's canonical `.form-*` controls as a deliberate sibling rather than an unstyled leftover. This is verification only — the family is intentionally retained per DESIGN.md § Native selects (What We're NOT Doing).
  - **Verify**: the two `git diff --name-only` assertions in the Final Validation Checklist print nothing — this story owns no canon and no `lib/src/api/` change, so it neither runs nor re-proves the drift check (`check_design_system_sync.sh` is S05's and S14's gate); no surface regresses against the story-start baseline in either theme at either viewport (regression = clipping, overflow, overlap, truncation, contrast loss or layout break – the intended re-tone and re-scale are not regressions); every re-coloured or re-sized text run measures ≥ 4.5:1 against its background in both themes; the `.custom-select` checks above pass and the retention is recorded; each of the surfaces' audit findings appears in Implementation Observations as closed or deferred-with-reason

### Testing Strategy
> Default test approach: per-task Verify lines + scenario tests scaffolded from Acceptance Scenarios.

- This story is CSS, Trellis markup and view-model work with no behaviour contract to unit-test, with three exceptions worth a Dart test on `task_timeline.dart#taskTimelineHtml` (TI10):
  - returns empty for an empty **unfiltered** event list, so `hasTimeline` is false (Scenario S07);
  - returns a rendered panel *with* its chip row when the unfiltered list is non-empty but the active filter matches nothing (Scenario S08, third Then) — the regression this guards is suppressing on the post-`_applyFilter` list;
  - per-filter counts are derived from the unfiltered list: with `activeFilter: 'tools'` on a five-event fixture (three `toolCalled`, two `statusChanged`) the All count is 5 and the Status count is 2, not 3 and 0 (Scenario S08, second Then).
- Everything else is proved by visual validation against the story-start baseline.

### Execution Contract

- TI01 and TI02 must complete before TI03 – the mobile geometry rules are keyed to the same selectors TI02 re-keys, and TI03 re-introduces inside the 768px block the `table-layout: fixed` that TI02 removes from the unscoped rule.
- TI14's `font-size` deletions must land with the `.t-heading` markup edits in the same step. Splitting them leaves the class applied and inert, which validates as "adopted" in a diff and fails only at TI17's visual gate.
- This story makes **no** canon edit and runs no re-sync. TI04, TI05 and TI16 each open with an arrival gate on the rule their P1 owner ships (S01's `thead` band; S02's icon tokens/`[data-icon]` mappings and `.msg-user .msg-content p`). Run those greps against the **served** copies under `lib/src/static/` before starting the task — canon edits are invisible to the browser until re-synced. A gate that fails is a stop-and-report, not a licence to add the rule.
- TI13 assumes S06 has already removed the native `window.confirm` from `dc_scheduling_controller.js#deleteScheduledTask`. If it has not, do not remove it here – record the ordering and land the inline bar around whatever S06 has. Either way the replacement pattern is this task's: S06 builds no modal for that call site, so the scheduled-task delete has no working confirmation until TI13 lands. TI13's Verify is scoped accordingly and must not assert the absence of that call.


## Final Validation Checklist

- [ ] `git diff --name-only <story-start-commit> -- dev/design-system/ packages/dartclaw_server/lib/src/static/tokens.css packages/dartclaw_server/lib/src/static/design-system.css packages/dartclaw_server/lib/src/static/icons.css` prints nothing, and `git diff --name-only <story-start-commit> -- packages/dartclaw_core/ packages/dartclaw_storage/ packages/dartclaw_server/lib/src/api/` prints nothing. Diff against this story's start commit, not `main` — sibling P1/P3 stories change canon in the same branch.
- [ ] Memory dashboard, workflow detail and chat are visually unregressed by this story's shared `app.css` edits — `.table-wrap` and `.provider-badge`'s `margin-left` removal — and by the S01/S02 canon rules this story consumes, which reach every `.data-table` and every `.msg-content` in the app.
- [ ] The retained `.custom-select` family passes TI17's regression check and its retention is recorded in What We're NOT Doing.
- [ ] Every Verify line in this FIS was run as written, and the ones expressed as browser observations were checked against computed values (`scrollWidth`/`clientWidth`, computed `font-size`) rather than markup inspection.


## Implementation Observations

> _Managed by exec-spec post-implementation – append-only._

_No observations recorded yet._
