# Surface sweep: health, memory and session-info dashboards

**Plan**: docs/specs/0.22.1/plan.json
**Story-ID**: S09

## Feature Overview and Goal

**Intent**: The three surfaces whose entire job is showing numbers are the three that show them worst – the health dashboard buries its whole KPI row below the fold and pads the first viewport with 13px label/value rows that restate each other, memory's five-tile row strands a bare `%` at the far edge of the card and paints category colour where state belongs, and the guard audit is the one table in the app without the canonical table treatment, with browser-default filter buttons and an inline-styled empty state; this story makes the dashboards read as dashboards using primitives that already exist and are already served. (The audit route's own naked-fragment defect – the same table served unstyled on direct navigation – is S10's by plan ruling.)

**Expected Outcomes**:

- [OC01] The health dashboard's first viewport carries its KPI numbers rather than filler – the metric row leads the page, every fact appears once, and no row asserts a status the app never measured.
- [OC02] Every dashboard metric row reads as one designed component: uniform tile anatomy, numerals centred under their own labels, a legible budget percentage, no card orphaned on a final row at any breakpoint, and colour that signals state rather than category.
- [OC03] The three surfaces drop their private look-alikes for the canonical treatments already in canon – `.data-table`, `button.chip`, `.section-title`, the canonical `.empty-state` and absent-value treatments, the wide container – and every load-bearing label meets WCAG AA in both themes with no raw machine timestamp left on the surface.
- [OC04] Reading a dashboard is uninterrupted: the 30s polls preserve the open tab, loaded preview, scroll position and expanded audit row, and `/memory` stays inside the `100dvh` shell.


## Required Context

### From `docs/specs/0.22.1/prd.md` – "FR6: Re-sync + adoption sweep"
<!-- source: docs/specs/0.22.1/prd.md#fr6-re-sync--adoption-sweep -->
<!-- extracted: e18cf85 -->
> **Description**: Re-sync canon into the served CSS with the drift check green, purge app-local duplicates obsoleted by FR4, then work the 118 adoption findings. Priority clusters: health/memory/session-info metric + meter adoption; wide-container application; type-tier migration; empty/loading/error state coverage (31 findings — em-dash placeholders where an absent-value treatment belongs, undesigned empty states, no skeleton/`.scan-bar` loading treatment).
>
> **Acceptance Criteria**:
> - [ ] Drift check green; `design-system.css` byte-identical to canon.
> - [ ] `health_dashboard.html` uses `.metric-value` and `.meter`.
> - [ ] Every page has a designed empty state; no bare em-dash stands in for an absent value.
>
> **Priority**: Must / P0

_Scope split: the app-local duplicate purge and the type-tier migration are S05 and S07; this story owns the three dashboards' adoption._

_Disposition of the second acceptance criterion, whose premise the code contradicts (see `NOTICED:` in Constraints & Gotchas): the `.metric-value` half is **already true** — `health_dashboard.dart:144-149` composes four `.card-metric` tiles through `metricCardTemplate`. The `.meter` half is **deferred**: the health payload carries no bounded ratio to meter (TI03 records the deferral and its reason for S14's ledger, which carries the criterion as amended)._

### From `docs/specs/0.22.1/prd.md` – "FR7: Glitch sweep"
<!-- source: docs/specs/0.22.1/prd.md#fr7-glitch-sweep -->
<!-- extracted: e18cf85; FR7 gained the durable-backlog criterion after this extraction (uncommitted) -->
> **Description**: Close the 64 distinct defects catalogued in the audit. No design decisions required. Includes a global data-formatting pass — timestamps currently appear in three unrelated formats, never roll over past days, and one page prints raw ISO-8601 with milliseconds.
>
> **Acceptance Criteria**:
> - [ ] All 23 high-severity glitches closed.
> - [ ] Remaining glitches closed or explicitly deferred with a recorded reason.
> - [ ] […elided: every deferral carried into a durable backlog, with its reason and no target milestone — the release-boundary hand-off S14 owns; this story's part is recording the deferral in its own Implementation Observations…]
> - [ ] UI smoke test (TC-01…TC-31) green.
>
> **Priority**: Must / P0

### From `docs/specs/0.22.1/prd.md` – Binding constraint: canon-first
<!-- source: docs/specs/0.22.1/prd.md#key-constraints-assumptions--dependencies -->
<!-- extracted: e18cf85 -->
> *Constraint:* **canon-first is mandatory.** The 0.22 drift check requires `design-system.css` byte-identical to `dev/design-system/components.css`. Any app-side edit to a canon-owned rule fails CI.

### From `docs/specs/0.22.1/prd.md` – Binding constraint: zero-npm / no build step
<!-- source: docs/specs/0.22.1/prd.md#key-constraints-assumptions--dependencies -->
<!-- extracted: e18cf85 -->
> *Constraint:* zero-npm / server-first; no build step; no new runtime JS dependencies (FR8 *removes* runtime dependencies, it does not add any).

### From `docs/specs/0.22.1/prd.md` – Binding constraint: no backend work
<!-- source: docs/specs/0.22.1/prd.md#constraints -->
<!-- extracted: e18cf85 -->
> **No backend work.** Any finding needing a service, schema or API change is out of scope by definition.

### From `docs/specs/0.22.1/prd.md` – Binding constraint: out of scope
<!-- source: docs/specs/0.22.1/prd.md#out-of-scope -->
<!-- extracted: e18cf85 -->
> New UX capabilities of any kind. This release adds no features; it refines what exists.

### From `docs/specs/0.22.1/prd.md` – Binding constraint: FR1 surface contrast
<!-- source: docs/specs/0.22.1/prd.md#fr1-surface--depth-revision -->
<!-- extracted: e18cf85 -->
> Card-vs-ground contrast ≥ 1.15:1 in both themes; no gradient stop equals the card fill.

### From `docs/specs/0.22.1/prd.md` – Binding constraint: FR5 native dialog eradication
<!-- source: docs/specs/0.22.1/prd.md#fr5-feedback-decision-table-rewrite--native-dialog-eradication -->
<!-- extracted: e18cf85 -->
> Zero `window.alert` / `window.confirm` / `window.prompt` / bare `alert(` / `confirm(` / `prompt(` in `lib/src/static/controllers/`.

### From `docs/specs/0.22.1/prd.md` – Binding constraint: NFR accessibility
<!-- source: docs/specs/0.22.1/prd.md#non-functional-requirements -->
<!-- extracted: e18cf85 -->
> WCAG AA text contrast preserved in both themes after the surface remap; `prefers-reduced-motion` honored; focus-visible on every interactive element; status never conveyed by colour alone

### From `docs/specs/0.22.1/prd.md` – Binding constraint: NFR visual quality
<!-- source: docs/specs/0.22.1/prd.md#non-functional-requirements -->
<!-- extracted: e18cf85 -->
> Both themes at desktop + 768px per story; UI smoke test at phase boundaries; the 92-screenshot audit capture reused as the before/after baseline

### From `docs/specs/0.22.1/plan.json` – Shared decision: canon-first, and canon closes after P1
<!-- source: docs/specs/0.22.1/plan.json#sharedDecisions -->
<!-- extracted: 2026-07-25 plan remediation -->
> A story that changes a canon-owned rule edits `dev/design-system/` (tokens.css / components.css / icons.css / DESIGN.md / showcase.html) first, then re-syncs the served copies under `packages/dartclaw_server/lib/src/static/` — regenerating the two-line `/* Synced from … sha256: … */` provenance header — within the same story. `dev/tools/fitness/check_design_system_sync.sh` must be green at every story boundary. ONLY the P1 stories S01-S04 hold that right, and only for the three DRIFT-CHECKED files — `tokens.css`, `components.css` and `icons.css`. Those close once P1 completes, because the check pins a sha256 on line 2 of each served copy and concurrent edits in the parallel P3 wave conflict on that line by construction. S05 re-syncs nothing new — it verifies the check is green after its purge. A P3 story that finds it needs a canon RULE stops and reports it for hoisting into the owning P1 story (surfaces and chrome to S01, type and icons to S02, form/control/tab/state to S03, dialog and feedback to S04); it does not add the rule itself. `DESIGN.md` and `showcase.html` are NOT closed and NOT drift-checked — they are prose and a demo, never synced — so any story that establishes a documented contract writes it there directly, and S14 reconciles the whole document at release close.

_This story is P3: it consumes canon and edits none of the three drift-checked files. Its one canon need — the `.card-featured-*` background-layer grammar fix it discovered — is hoisted to **S01** per `docs/specs/0.22.1/canon-hoist-manifest.md`._

### From `docs/specs/0.22.1/plan.json` – Shared decision: shared-surface ownership in the sweep phase
<!-- source: docs/specs/0.22.1/plan.json#sharedDecisions -->
<!-- extracted: 2026-07-25 plan remediation -->
> Three shared surfaces were claimed by more than one parallel story and are assigned once here. (1) PAGE TITLE: the topbar owns the page title and is the only `<h1>` on a page; six templates currently carry an in-page `<h1>` (`settings`, `knowledge_hub`, `kg_timeline`, `channel_detail`, `projects`, `login`) and each duplicate is deleted by the story owning that surface — settings by S11, knowledge_hub + kg_timeline + channel_detail by S10, projects by S15; `login` renders no topbar and keeps its `<h1>`. S16 promotes the shared topbar fragment to `<h1>` and asserts only that the fragment emits one and that no NEW duplicate is introduced — it cannot assert one-per-page, because it is barred from editing per-surface templates. Pages carry a subtitle or description head, never a second `<h1>`. (2) OFF-SCALE FONT SIZES: S07 alone normalizes every hard-coded off-scale font-size (`.provider-badge`, `.channel-mode-badge`, `.workflow-artifact-badge` and siblings); sweep stories keep only their own semantic edits to those rules and must not re-declare the size. (3) AUDIT ROUTE: S10 owns the `/health-dashboard/audit` non-fragment behaviour and renders the full page inline (preserving the `page` param, which a redirect would drop); S09 does not touch that handler.

_Binding on this story twice: memory's page head carries no `<h1>` (TI05), and the `/health-dashboard/audit` handler is not this story's to edit (see What We're NOT Doing)._

### From `docs/specs/0.22.1/plan.json` – Shared decision: surface token roles
<!-- source: docs/specs/0.22.1/plan.json#sharedDecisions -->
<!-- extracted: e18cf85 -->
> S01 fixes the structural rule every later story consumes: chrome (`.sidebar`, `.topbar`), page ground and `.card` occupy three mutually distinct planes in BOTH themes, and the body gradient never terminates on the card tone. The token assignment differs per theme and is not fixed here — the PRD's dark remap is chrome→crust / ground→base / card→sub-base, while the light theme gets its own mapping (card white on a tinted ground, chrome at the mantle tier), and exact values in both are an S01 visual-validation outcome. Card hover is not independent: `.card:hover` paints over the same token as card rest, so it re-derives from whatever S01 lands on. No downstream story re-tones a card, chrome, or ground locally — surface complaints go back to S01's tokens.

### From `docs/specs/0.22.1/plan.json` – Shared decision: composite type-class vocabulary
<!-- source: docs/specs/0.22.1/plan.json#sharedDecisions -->
<!-- extracted: e18cf85 -->
> S02 fixes the seven composite class names, each binding font-size + weight + line-height + letter-spacing: `.t-caption`, `.t-body`, `.t-label`, `.t-heading`, `.t-page-title`, `.t-display`, `.t-metric`. All consumers apply these classes; raw `--text-*` tokens are for one-offs only, and no consumer hand-derives a tier from four separate properties.

### From `docs/specs/0.22.1/plan.json` – Shared decision: wide-container assignment
<!-- source: docs/specs/0.22.1/plan.json#sharedDecisions -->
<!-- extracted: 2026-07-25 plan remediation -->
> S02 ships `--container-wide` plus the `.content-inner--wide` / `.page-inner--wide` modifiers. Assignment is fixed here so P3 stories do not each re-litigate it: wide applies to tasks, task detail, health (dashboard + audit), memory, scheduling, the workflow list AND workflow detail; the 900px measure stays for chat, session info, knowledge results, settings forms, and projects. The modifier is opt-in, never the default — a surface not on the wide list keeps 900px unless the sweep documents a deviation.

### From `docs/specs/0.22.1/plan.json` – Shared decision: visual-baseline protocol
<!-- source: docs/specs/0.22.1/plan.json#sharedDecisions -->
<!-- extracted: e18cf85 -->
> The PRD's NFR reuses the audit's 92-screenshot capture as the before/after baseline. That works at release level but NOT per story: S01 re-tones every surface and S02 re-scales its type, so from S03 onward every capture differs for reasons outside the story under test and the audit set cannot isolate a story's own deltas. Protocol: each story captures its own story-start screenshots of the surfaces it touches, in both themes at desktop and 768px, and validates against those. The audit's 92-shot set stays the release-level baseline that S14 re-proves once. A story that finds a regression outside its own scope reports it rather than absorbing it.

_This supersedes the "NFR visual quality" constraint above for per-story validation; the 92-shot set remains the release-level baseline S14 re-proves._


## Deeper Context

- `docs/specs/0.22.1/audit-ui-polish-2026-07-25.md#worked-example-the-health-dashboard` – the release's headline illustration and this story's framing; read alongside the `NOTICED:` correction in Constraints & Gotchas before trusting its "uses neither" claim.
- `docs/specs/0.22.1/audit-ui-polish-2026-07-25.md#c-adoption-gaps--canon-has-the-answer-the-app-does-not-use-it-118` – the 15 adoption findings this story closes, under `memory-dashboard` (6), `health-audit` (3), `health-dashboard` (3), `health-dashboard (Guard Activity)`, `health-dashboard + scheduling`, `health-dashboard + scheduling + health-audit`. Read each *Evidence* block for the measured contrast ratios and pixel offsets the Verify lines assert against.
- `docs/specs/0.22.1/audit-ui-polish-2026-07-25.md#b-glitches--visibly-broken-no-design-decision-needed-72` – the glitches under `memory` (4), `memory-dashboard` (2), `health-audit` (2), `session-info` (2) and `health-dashboard` (1). Eleven entries, **eight** distinct defects: `memory-dashboard`'s two restate two of `memory`'s four (the 30s-poll defect and the meter-label defect), and `health-audit`'s two are one defect filed twice (both cite `web_routes.dart:398` serving the bare fragment; `:544` bundles the `.data-table` fix into its *Fix* line, `:549` does not). Of those eight, the naked-fragment route belongs to **S10** by plan ruling – seven whole defects stay here, plus the `class="data-table"` half of the eighth (TI07).
- `../dartclaw-public/dev/design-system/DESIGN.md#dashboard-layout` – the canonical composition TI03 restores: `grid-4` KPI row first, then hero + activity, then alerts.
- `../dartclaw-public/dev/design-system/DESIGN.md#chips` – the toggle-chip contract TI07 adopts: `button.chip` with `aria-pressed="true"`, accent tint marking *selection*, never outcome state.
- `../dartclaw-public/dev/guidelines/VISUAL-VALIDATION-WORKFLOW.md` – server/token setup and the agent-browser snapshot loop for the both-theme, two-viewport validation every scenario gates on.
- `../dartclaw-public/dev/guidelines/HTMX-GUIDELINES.md` – polling, `hx-trigger` filters and swap-scoping patterns for TI14.
- `docs/wireframes/health-dashboard.html`, `docs/wireframes/memory-dashboard.html` – the intended information hierarchy for both surfaces.


## Acceptance Scenarios

- [ ] **S01 [OC01] [TI03,TI04] The health dashboard's first viewport carries its numbers**
  - **Given** the `visual` testing profile on port 3338, health dashboard loaded at 1440×900
  - **When** the page renders in dark theme and again in light theme
  - **Then** the KPI row of `.card-metric` tiles is the first content under the topbar, fully visible above the fold, ahead of the Services card grid – and the row fills its track with no tile orphaned on a final row
  - **And** each of uptime, session count and DB size appears exactly once on the page, and no row prints the unmeasured constants `claude binary`, `active` or `file-based`
  - **And** the page renders no `.meter`, because no health KPI is a bounded ratio – and FR6's `.meter` half is recorded as an explicit deferral, with its reason, in this FIS's Implementation Observations, so S14's ledger carries the criterion as amended rather than as silently failed

- [ ] **S02 [OC02] [TI10,TI11,TI12,TI17] The memory Overview row reads as one component**
  - **Given** the memory dashboard rendered with a 32 KB budget at 0% consumed and 0 errors recorded
  - **When** the Overview row renders at 1440×900 and again at 768px, in both themes
  - **Then** the budget meter label reads `of 32 KB` on the left and `0%` as a single adjacent unit – not a stranded `%` at the card's right edge
  - **And** every tile in the row has the same anatomy with no tile left alone on a final row at either width, and each numeral centres under its own label rather than sitting ~23px left of it
  - **And** the Errors tile carries no `card-metric--error` modifier at a count of 0, while a workspace at ≥80% of its memory budget renders the Memory Size tile as `card-metric--warning`
  - **And** a meter at 0% carries `.meter--empty` so it reads as an empty track rather than as a solid rule

- [ ] **S03 [OC03] [TI01,TI02,TI05,TI06] The three dashboards adopt the canonical surface treatments**
  - **Given** the served `design-system.css` as S01–S04 left it – this story edits no canon file – with health, memory and session info loaded in both themes
  - **When** each page renders at 1440×900, and again at 1024px
  - **Then** the health hero card's `.card-featured-accent` gradient border is visibly distinct from its own fill in both themes, proving S01's hoisted background-grammar fix reaches this surface, and the health and memory pages render inside the wide container while session info stays at the 900px measure
  - **And** every page-section `<h2>` uses `.section-title`, memory carries a subtitle/description head above its first section that adds no second `<h1>`, and `.section-label` survives only on in-card subsections
  - **And** at 1024px every `th` in memory's three `.data-table`s – Recent Runs (`Date`, `Archived`, `Deduped`, `Remaining`, `Final Size`), Sections (`Section`, `Count`) and daily logs (`Date`, `Entries`, `Size`) – has `scrollWidth <= clientWidth`, so no header label is clipped or ellipsised, and none breaks mid-word
  - **And** no label carrying essential data – `.card-row-label`, `.metric-sub-inline`, `.meter-label`, `.detail-label`, `.pagination-info`, `.info-footer` – resolves to `--fg-overlay`; each measures ≥ 4.5:1 against the card fill in light theme

- [ ] **S04 [OC03] [TI07,TI08,TI13] Guard audit and the pruner use real, accessible controls**
  - **Given** the guard audit table rendered inside the health dashboard with no audit entries recorded, and the memory pruner card
  - **When** a keyboard user tabs through the audit toolbar, the empty state, a populated audit row and the pruner action
  - **Then** the nine filters are `button.chip` elements whose active one carries `aria-pressed="true"`, the table carries `class="data-table"` with open header rules rather than a boxed cell grid, and the empty state renders the canonical icon-plus-paragraph structure with no inline `style` override
  - **And** the row disclosure is a real `<button>` inside the first cell with `aria-expanded` and `aria-controls` pointing at the detail row's `id` – the `<tr>` carries no `role="button"` – and every one of these controls shows a visible focus ring
  - **And** "Prune Now" renders with button chrome at rest, and its confirm/success/failure states are conveyed by a class swap rather than by `element.style.color`
  - **And** with the same table rendered at 1024px, each of the `TIMESTAMP`, `GUARD`, `VERDICT` and `DETAIL` `th` elements has `scrollWidth <= clientWidth` – no header label clipped behind the retained `white-space: nowrap` – and `.table-scroll` itself does not overflow, so the retained `min-width: 700px` still fits inside the wide container at that width

- [ ] **S05 [OC04] [TI14,TI15] Reader state survives the 30s polls and `/memory` stays in the shell**
  - **Given** the memory dashboard with the `errors.md` tab selected, its preview loaded and scrolled, and the health dashboard with one audit detail row expanded
  - **When** more than 30 seconds elapse so both pages complete a poll cycle
  - **Then** `errors.md` is still the active tab with its loaded content and scroll position intact, and the expanded audit detail row is still open
  - **And** a full-page capture of `/memory` measures 1440×900 at desktop and 768×1024 at mobile, matching all 22 other surfaces, with no unstyled band below the app frame

- [ ] **S07 [OC02,OC03] [TI16,TI17] Session info shows three token cards on one row and a human date**
  - **Given** a session created at `2026-04-15T10:00:00.000` with input, output and total token counts recorded
  - **When** session info renders at 1440×900 and again at 768px
  - **Then** the three `.token-grid` metric cards occupy a single row with no orphaned card beside an empty column, and collapse cleanly at 768px
  - **And** the Created value renders in the release's single timestamp format rather than the raw `2026-04-15T10:00:00.000`, with the ISO string preserved in a `title` attribute
  - **And** a session with no recorded token counts shows the canonical absent-value treatment in each card, not a hardcoded `—` string
  - **And** the page still measures 900px wide – session info is on the plan's 900px list and must not pick up the wide modifier


## Structural Criteria

- [ ] **This story edits no canon file.** Canon closed after P1: `git diff --name-only` lists nothing under `dev/design-system/` and none of `lib/src/static/{tokens.css,design-system.css,icons.css}`. The drift check is not this story's to re-green – it is verified by S05 and S14 – and a canon rule this story turns out to need is reported for hoisting, not added here.
- [ ] No app-side rule re-tones a card, chrome or page ground, and no app-side rule re-declares a canon-owned selector to work around a canon defect.
- [ ] This story introduces no `window.alert` / `window.confirm` / `window.prompt` / bare `alert(` / `confirm(` / `prompt(` into `lib/src/static/controllers/`.
- [ ] No `var(--text-sm)` reference is introduced – S07 deletes the compatibility alias before this story runs.
- [ ] Both of this story's deferrals – the absent chart/sparkline component (TI11) and FR6's `.meter` half (TI03) – are written into this FIS's **Implementation Observations** with their reasons, not only into a prose bullet and not only into the transient `dev/bundle/` copy, since that block is the only input S14's glitch ledger reads.
- [ ] No service, schema or public API contract changes; the sole non-template Dart edit is the session-info `createdAt` formatting at `web_routes.dart:377` (TI16). No `embed_assets.dart` regeneration – `embedded_assets.g.dart` is S14's alone.


## Scope & Boundaries

### Work Areas
- `packages/dartclaw_server/lib/src/templates/health_dashboard.html` / `health_dashboard.dart` – KPI row ordering, card de-duplication, section headings, wide container (TI03, TI04, TI05, TI06)
- `packages/dartclaw_server/lib/src/templates/memory_dashboard.html` / `memory_dashboard.dart` – page head, meter label, tile anatomy, numeral centring, state-driven modifiers, poll scoping (TI05, TI06, TI10, TI11, TI12, TI14)
- `packages/dartclaw_server/lib/src/templates/audit_table.dart` – `.data-table`, `button.chip` filters, canonical empty state, row disclosure button, absent-value cells (TI07, TI08, TI17)
- `packages/dartclaw_server/lib/src/templates/session_info.html` / `session_info.dart` and `packages/dartclaw_server/lib/src/web/web_routes.dart` – token grid, absent-value cards, and the session-info `createdAt` formatting at `web_routes.dart:377` only. The `/health-dashboard/audit` handler in the same file is **S10's**, not this story's (TI16, TI17)
- `packages/dartclaw_server/lib/src/static/app.css` – label colour tokens, `.metrics-grid` / `.metrics-grid-5` / `.token-grid` track definitions, `.filter-btn` and the `#audit-table-container` table overrides, `.page-content` containment (TI02, TI03, TI07, TI11, TI15, TI16)
- `packages/dartclaw_server/lib/src/static/controllers/dc_memory_controller.js` and `dc_shell_controller.js` – tab/preview persistence across swaps, audit-row disclosure wiring, pruner state classes (TI08, TI13, TI14)
- `docs/specs/0.22.1/fis/s09-surface-sweep-health-memory-session-dashboards.md` § Implementation Observations **in the private repo** – the durable home for this story's two deferrals; the `dev/bundle/` copy is deleted before merge, so a record written only there is lost (TI03, TI11)

### What We're NOT Doing
- **The `/health-dashboard/audit` request handler in `web_routes.dart` – S10 owns it.** Per `plan.json`'s *Shared-surface ownership in the sweep phase* decision (3), S10 renders the full health page **inline** on a non-fragment request; the redirect this story previously specified is rejected because it drops the `page` param, which the inline render preserves, and S10 already owns `wantsFragment` plus the sibling wiki-route fix in the same file. This story's edits to `web_routes.dart` are confined to the session-info view-model (TI16). *Numbering:* the removed task (TI09) and scenario (S06) leave gaps that are deliberately not back-filled, so cross-story references keep resolving.
- **No `.meter` on the health dashboard – FR6's second acceptance criterion is half-deferred.** Verified in source: `healthDashboardTemplate` (`health_dashboard.dart:11-27`) receives only unbounded counters – `uptimeSeconds`, `sessionCount`, `dbSizeBytes`, `totalArtifactDiskBytes` – and `HealthService.getStatus()` (`health/health_service.dart:50-84`) emits no cap beside any of them, so nothing on this surface is a ratio a determinate meter could read. The only caps that exist (`sessions.maintenance.max_sessions`, `.max_disk_mb`) are absent from the payload, unset by default and unset in the `visual` profile, so surfacing one means a health-service change (barred by *No backend work*) plus a fact the page does not show today (barred by *New UX capabilities of any kind*). Recorded as a deferral in TI03 with that reason, so S14's ledger carries the criterion as amended instead of failing it silently.
- **No chart, sparkline or `--chart-*` backing component.** Canon defines a chart ramp with no component behind it; building one is a new UX capability the release explicitly excludes. Recorded as a deferral in TI11 so it counts against the glitch ledger rather than vanishing.
- **No canon edit and no re-sync.** Canon closed after P1. The `.card-featured-*` background-layer grammar fix this story's audit trail discovered is **S01's**, hoisted per `docs/specs/0.22.1/canon-hoist-manifest.md`; this story consumes it and asserts the visible result on the health hero card. A canon rule that turns out to be missing is reported for hoisting, never added here and never worked around with an app-side re-declaration.
- **The topbar page title and sidebar logo type tiers** – the `health-dashboard` typography finding names `.topbar .session-title-static` and `.sidebar-header .logo`, both canon-owned shell chrome. S02 raises the topbar title to the page-title tier and S12 sweeps the shell; this story fixes only the health page's own heading tiers.
- **Scheduling's two `.table-empty-cell` markup rows** – the audit's audit-empty-state fix reaches into `scheduling.html`, which is S08's surface. This story remaps the `.table-empty-cell` colour token in `app.css` (TI02) and leaves the markup swap to S08.
- **Wiring FTS5 Index / Runtime / Format to real probes** – that needs a health-service change, which the no-backend-work constraint excludes. TI04 removes the unmeasured assertions instead.
- **Re-toning any card, chrome or ground token** – S01 owns the surface ladder. Surface complaints found here go back to S01's tokens, not into `app.css`.


## Architecture Decision

**Approach**: Adopt what is already served – every fix uses a primitive that exists in canon today (`.card-metric`, `.meter`, `.data-table`, `button.chip[aria-pressed]`, `.empty-state`, `.section-title`, `.content-inner--wide`); nothing new is invented and nothing in `dev/design-system/` is touched.
**Why this over alternatives**: the audit's finding is that the primitives exist and were skipped, so an adoption sweep closes the gap without widening canon's surface. The one canon-grammar defect this surface exposed (`.card-featured-*`) is fixed upstream in S01 rather than here, because the drift check pins a sha256 on line 2 of every served copy and five parallel W2 branches editing canon collide on that line by construction – so this story's contribution is to *prove* the hoisted fix lands on the health hero card, not to author it.


## Code Patterns & External References

```
# type | path#anchor or url                                                        | why needed (intent)
file   | packages/dartclaw_server/lib/src/templates/components.html#metricCard     | The metric-card fragment health and session info compose; `.card-metric` + `.metric-value` + `.metric-label` anatomy TI11 must make uniform
file   | packages/dartclaw_server/lib/src/templates/memory_dashboard.html#.metrics-grid-5 | The five-tile Overview row: meter-label three-child bug, hardcoded --accent/--error modifiers, sub-inline inside the centred value box
file   | packages/dartclaw_server/lib/src/templates/health_dashboard.dart#healthDashboardTemplate | cardDefs + metricsHtml assembly – where the duplicated rows and hardcoded constants live
file   | packages/dartclaw_server/lib/src/templates/audit_table.dart#auditTableFragment | Filter toolbar, empty state, `<table>` without .data-table, `<tr role="button">` disclosure, pagination
file   | packages/dartclaw_server/lib/src/web/web_routes.dart#sessionInfoTemplate   | `:377` – the `createdAt: session.createdAt.toIso8601String()` argument TI16 formats; this story's only edit in this file
file   | packages/dartclaw_server/lib/src/templates/scheduling.html                 | Sibling surface already using `class="data-table"` correctly – the shape TI07 converges on
file   | dev/design-system/components.css#.data-table                               | Read-only: canon's open-header treatment TI07 hands the audit table back to – note `th` carries no `white-space: nowrap`, so the app-side nowrap TI07 retains is what keeps audit headers on one line
file   | dev/design-system/components.css#.chip                                     | `button.chip[aria-pressed="true"]` toggle-filter treatment, fully backed – adopt, do not re-declare
file   | dev/design-system/components.css#.empty-state                              | Canonical icon + `<p>` structure and `--sp-12`/`--sp-4` padding the audit empty state overrides away
file   | packages/dartclaw_server/lib/src/static/controllers/dc_memory_controller.js#initializeView | Reads the persisted view toggle back from localStorage on connect (the matching write lives in the toggle handler) – the persist-and-reapply pattern TI14 extends to the active tab
wire   | docs/wireframes/health-dashboard.html                                      | Intended health information hierarchy
```


## Constraints & Gotchas

- **NOTICED**: FR6's acceptance criterion "`health_dashboard.html` uses `.metric-value` and `.meter`" and the audit's worked example ("uses **neither**… verified by grep") rest on a grep of `health_dashboard.html` alone. The page *does* render four `.card-metric` tiles with `.metric-value`, composed in `health_dashboard.dart:144-149` via `metricCardTemplate` → `components.html#metricCard`. What is actually true: health uses no `.meter` anywhere, and its KPI row sits below the fold. **Disposition, both halves:** the `.metric-value` half needs no work – do not add one that is already there. The `.meter` half is **deferred, not silently dropped**: the surface has no bounded ratio to meter (payload evidence in What We're NOT Doing), so TI03 records the deferral with its reason in Implementation Observations and S14's ledger carries the criterion as amended. Implement the measured defects (ordering, duplication) and leave the criterion's meter half to the ledger.
- **Constraint**: `app.css` loads *after* `design-system.css` (`layout.html:16-17`), so an app rule of equal specificity wins. Deleting an app override (TI07's `#audit-table-container` cell borders, TI02's colour declarations) hands the property back to canon – re-validate the surface visually after each deletion rather than assuming the canon value matches what shipped.
- **Constraint**: this story runs after S01's re-tone and S02's type/container work, in parallel with S08/S10/S11/S12 which also touch `app.css`. Every rule this story edits must be located by selector, never by the line numbers the audit records – they are from the audited build and have moved. Keep edits inside the `SESSION INFO`, `AUDIT TABLE`, `SCHEDULING`, `SCHEDULING: JOB MANAGEMENT` and `MEMORY DASHBOARD` blocks so the parallel sweeps conflict as little as possible – `SESSION INFO` holds TI16's `.token-grid`, and the two scheduling blocks hold TI02's `.cron-*` / `.info-footer` / `.table-empty-cell` token edits even though S08 owns that surface's markup.
- **Critical**: `.card-featured-*` fails because a bare `<color>` is only valid in a `<final-bg-layer>` of the `background` shorthand, so the whole declaration is dropped and only `border: 1px solid transparent` survives. **S01 fixes this in canon** (hoist manifest); this story only consumes it. If the health hero card's ring is still indistinguishable from its fill when this story runs, that is an S01 regression to report – **not** an app-side override to write: `app.css` loads after `design-system.css`, so a local patch would silently win and hide the canon defect from every other featured card in the app.
- **Assumption** (recorded for the orchestrator): TI16 edits `web_routes.dart:377`, which the plan overview's "zero backend surface" summary does not anticipate. The binding constraint is narrower – "any finding needing a service, schema or API change" – and formatting a `DateTime` inside a page handler's view-model changes no service, schema or API contract. If the orchestrator reads the summary as binding, TI16's Created-date half is the piece to lift out. The file is a W2 hotspot (S09, S10, S12); with the audit route now S10's, this story's only region in it is the session-info handler at `:371-388`, so the overlap is textually disjoint.
- **Avoid**: conveying the pruner's confirm/success/failure states through `--warning` / `--success` / `--error` text colour alone – status must never be conveyed by colour alone. Locate by symbol, not line: `dc_memory_controller.js` carries **five** `style.color` assignments across the confirm, result and reset paths (the audit records only three), and TI13's Verify requires all five gone. Instead: swap the button's class so the state inherits real button chrome plus its label change.


## Implementation Plan

### Implementation Tasks

- [ ] **TI01** S01's featured-card gradient border is proved on the health hero card – this story authors no canon
  - Consume, do not author: S01 replaces the bare colour layer in all eight `.card-featured-{accent,info,error,warning}` base and `:hover` rules with the `linear-gradient(<card-fill>, <card-fill>) padding-box, linear-gradient(135deg, …) border-box` idiom and re-syncs the served copy (hoist manifest, row 1). This story's job is to confirm the fix reaches `health_dashboard.html:15`, whose `statusCardClass` resolves to `card-featured-accent` when healthy, `--warning` when degraded and `--error` otherwise (`health_dashboard.dart:33-37`) – and to report a miss upstream rather than patching `app.css`.
  - **Verify**: `git diff --name-only` for this story lists no path under `dev/design-system/` and none of `lib/src/static/{tokens.css,design-system.css,icons.css}`; pixel-sampling the health hero card's border ring against its own fill shows a visible delta in both themes, where the audited build measured Δ6 in light and indistinguishable in dark; `rg -n "card-featured" packages/dartclaw_server/lib/src/static/app.css` returns no matches (exit 1), proving no app-side re-declaration was added to compensate

- [ ] **TI02** Load-bearing dashboard labels sit on `--fg-sub0`, leaving `--fg-overlay` to placeholders and disabled controls
  - In `app.css`, move `.card-row-label`, `.cron-expr`, `.cron-human`, `.info-footer`, `.pagination-info`, `.detail-label`, `.table-empty-cell`, `.metric-sub-inline` and `.meter-label` from `--fg-overlay` to `--fg-sub0`, and drop the `opacity: 0.6` from `.cron-human--sub-id`, differentiating the Schedule column by tier instead. Locate by selector, not by line number.
  - **Verify**: each listed selector computes `--fg-sub0` (light `#62677d`, ≥ 4.5:1 on the card fill) with no `--fg-overlay` and no `opacity` left on `.cron-human--sub-id`; contrast-check every one in light theme on health, health/audit, memory and scheduling

- [ ] **TI03** The health dashboard's KPI row is the first content under the topbar and fills its track
  - Move the metrics grid above the Services grid in `health_dashboard.html`, and give `.metrics-grid` a `repeat(auto-fit, minmax(…, 1fr))` track in `app.css` so four tiles form one row rather than 3+1 under the current `repeat(3, 1fr)` (`app.css:586-589`). Matches DESIGN.md § Composition Patterns → Dashboard layout, whose KPI row leads.
  - **Also record FR6's `.meter` deferral here**, because this is the task that owns the health KPI row. Re-check the live payload first: if every value the row can reach is an unbounded counter, write the deferral into this FIS's **Implementation Observations** naming FR6 acceptance criterion 2 verbatim, the half already satisfied (`.metric-value`, via `metricCardTemplate`), the half not satisfiable (`.meter`), and the reason – no bounded ratio in `healthDashboardTemplate`'s parameters or in `HealthService.getStatus()`, and the only caps that exist (`sessions.maintenance.max_sessions`, `.max_disk_mb`) are outside the payload, unset by default and unset in the `visual` profile, so surfacing one is a service change plus a new fact on the page. If the re-check instead finds a bounded pair the page already carries, the deferral is void: ship `.meter` + `.meter-fill` on it, paired with a visible label per DESIGN.md § Meters, and say so in Implementation Observations.
  - **Verify**: at 1440×900 in both themes the four `.card-metric` tiles render on one row, entirely above y=900, ahead of the Services `.card-grid`; the row still collapses without an orphan at 1024px and at 768px – the `auto-fit` track is what makes 1024px a real check, since it can resolve to 3+1 there while looking correct at both other widths. For the deferral: `rg -n "meter" packages/dartclaw_server/lib/src/templates/health_dashboard.html packages/dartclaw_server/lib/src/templates/health_dashboard.dart` returns no matches (exit 1, no output) **and** `sed -n '/^## Implementation Observations/,$p' docs/specs/0.22.1/fis/s09-surface-sweep-health-memory-session-dashboards.md` in the **private** repo prints a record naming FR6 and `.meter` with its reason – both halves required, since absence alone is exactly the silent omission success metric 5 fails on, and a record written only into the `dev/bundle/` copy is deleted before merge

- [ ] **TI04** Health service cards state each fact once and assert nothing the app did not measure
  - In `health_dashboard.dart`, drop the rows that restate their own card badge (Worker→State, Sessions→Total), collapse the Database and Storage cards into one (both report the same byte count), and remove the hardcoded `'claude binary'`, `'active'` and `'file-based'` values rather than wiring probes for them – probes are backend work this release excludes.
  - **Verify**: `rg -n "claude binary|'active'|file-based" packages/dartclaw_server/lib/src/templates/health_dashboard.dart` returns no matches; the rendered page shows uptime, session count and DB size exactly once each

- [ ] **TI05** Page-section headings use `.section-title`, and memory has a subtitle head that adds no second `<h1>`
  - Swap `class="section-label"` → `class="section-title"` on the page-section `<h2>`s in `health_dashboard.html` and `memory_dashboard.html`, keeping `.section-label` for in-card subsections such as memory's "Recent Runs". Add a page head above memory's first section carrying a **subtitle/description only** – no `<h1>`: per the plan's *Shared-surface ownership* decision the shared topbar owns the page's single `<h1>`, and S16 TI02 has already promoted it, so the memory page's title is `pageTopbarTemplate(title: 'Memory Dashboard')` (`memory_dashboard.dart:21`) and a second one here would make the rendered page carry two. Use **S16 TI03's** shared `components.html#pageHeader` fragment with its optional `<h2>` omitted and its subtitle retained; otherwise emit the subtitle directly. `kg_timeline.html:7-12` is the *structural* model (`.pagehead` wrapper + `.page-subtitle`), **not** a markup copy – its `<h1 class="page-title">` is one of the six in-page duplicates S10 deletes. `.section-title` currently has zero consumers app-wide.
  - **Verify**: `rg -c 'class="section-title"' packages/dartclaw_server/lib/src/templates/*.html` prints a count line for both `health_dashboard.html` and `memory_dashboard.html` (today it matches no file at all and exits 1); `rg -n '<h1' packages/dartclaw_server/lib/src/templates/memory_dashboard.html` returns no matches (exit 1, no output) both before and after this task – i.e. this story adds none; the rendered `/memory` page carries **exactly one** `<h1>` and its text is the topbar's "Memory Dashboard", not the new head; "MEMORY PRUNING" (page section) is now typographically distinct from "RECENT RUNS" (in-card)

- [ ] **TI06** Health and memory take the wide container; session info keeps the 900px measure
  - Add `content-inner--wide` to the health dashboard's `.content-inner` and `page-inner--wide` to memory's `.page-inner`, per the plan's fixed assignment. `session_info.html` keeps bare `.content-inner`. Both modifiers ship from S02 – do not redefine them. The container is also what decides whether memory's three existing `.data-table`s have room for their headers, so prove that in the same pass.
  - **Verify**: at 1440px health and memory compute a container wider than 900px while session info still computes `max-width: 900px`; all three still centre and collapse cleanly at 768px; and at **1024px** – the lower bound of FR3's "any viewport ≥ 1024px", which no story checks on this story's tables – every `th` in memory's three `.data-table`s (Recent Runs, Sections, daily logs; locate by the table, not by line) has `scrollWidth <= clientWidth` and no computed `word-break`/`overflow-wrap` that permits a mid-word break. Assert clipping, not line count: canon's `.data-table th` carries **no** `white-space: nowrap` (`components.css:1578-1585`, verified), so a header here can legitimately wrap between words – `Final Size` is the only two-word header – and what FR3 forbids is a break *inside* a word or a label cut off by its column

- [ ] **TI07** The guard audit renders as a canonical data table with chip filters and a canonical empty state
  - In `audit_table.dart`: add `class="data-table"` to the `<table>`, emit `class="chip"` with `aria-pressed` for the nine filters, replace the raw `<span style="margin-left:auto">` spacer with a layout class, and emit the canonical `<div class="empty-state"><span class="icon icon-shield-alert"></span><p>No guard events recorded yet</p></div>` with no inline `style` – `icon-shield-alert` is canon's only shield icon, and this story may not add one to `icons.css`. In `app.css` delete `.filter-btn` and, from `#audit-table-container .table-scroll th, td` (`:551`), the `border: var(--border)` declaration plus the `th` background/colour fill at `:552`, so the cells fall back to canon's open header rule. **Keep both `white-space: nowrap` at `:551` and `min-width: 700px` at `:550`** – canon's `.data-table th` declares no nowrap, so dropping the app-side one would silently change how every audit header and the long Detail cells break, which is outside this finding.
  - **Verify**: `rg -n "filter-btn|style=\"margin-left:auto\"|style=\"padding:var\(--sp-6\)" packages/dartclaw_server/lib/src/templates/audit_table.dart packages/dartclaw_server/lib/src/static/app.css` returns no matches; `rg -c 'class="chip' packages/dartclaw_server/lib/src/templates/audit_table.dart` returns a non-zero count; `rg -n "white-space: nowrap" packages/dartclaw_server/lib/src/static/app.css` still reports the `#audit-table-container .table-scroll` line; the audit table renders with canon's open header rule (no boxed cells, no filled header bar), and the active filter's accent tint resolves from canon's `.chip[aria-pressed="true"]` rule rather than any `app.css` rule – today's `.filter-btn` already emits `aria-pressed` and already tints, so an `aria-pressed`-only check passes pre-implementation. At **1024px** each of the four `th`s (`Timestamp`, `Guard`, `Verdict`, `Detail`) has `scrollWidth <= clientWidth` – with nowrap retained, "renders on one line" is true by construction, so the real failure mode is a label clipped by its column – and `.table-scroll` has `scrollWidth <= clientWidth` too, proving the retained `min-width: 700px` still fits inside the wide container at that width rather than forcing a horizontal scrollbar onto the reader

- [ ] **TI08** The audit row disclosure is a real button with `aria-controls` and a visible focus ring
  - Drop `role="button"` and `tabindex="0"` from the `<tr class="audit-row">` in `audit_table.dart`; move the trigger into the first cell as a `<button>` carrying a canonical button class (so it inherits canon's `:where(.btn, …):focus-visible` ring with no canon edit), with `aria-expanded` and `aria-controls` pointing at an `id` given to the sibling `.audit-detail-row`. Repoint `dc_shell_controller.js`'s `toggleAuditRow` at the button.
  - **Verify**: `rg -n 'role="button"|tabindex="0"' packages/dartclaw_server/lib/src/templates/audit_table.dart` returns no matches; the toggle is keyboard-reachable, shows a focus ring, flips `aria-expanded`, and its `aria-controls` resolves to the detail row's `id`

- [ ] **TI10** The memory budget meter label renders its percentage as one unit
  - `.meter-label` is `display: flex; justify-content: space-between`, and `memory_dashboard.html` currently feeds it three children – the bare `%` text node becomes an anonymous third flex item and is flung to the card's right edge. Wrap value and unit in one element so the label has exactly two children.
  - **Verify**: at 1440×900 and 768px the label reads `of 32 KB` left and `0%` right as two adjacent glyph runs, with no `%` detached at the far edge; the rendered `.meter-label` has exactly two element children and no loose text node

- [ ] **TI11** The memory Overview row has uniform tile anatomy, no orphan tile, and numerals centred under their labels
  - Give every tile in the row the same anatomy (Active/Archived currently come from the plain `metricCardTemplate` and end short of their metered neighbours – the audit measures the same gap twice, at ~55px and ~30px) and replace `.metrics-grid-5`'s fixed `repeat(5,1fr)` / `repeat(3,1fr)` / `repeat(2,1fr)` ladder with an `auto-fit` track so no tile is left alone. Make `.metric-value` centre the numeral independently of its `.metric-sub-inline` suffix, and split the byte unit out of the Memory Size value in `memory_dashboard.dart` so `0 B` and `3 / 50` share one treatment. Record the absent chart/sparkline component as an explicit deferral with its reason in this FIS's **Implementation Observations** in the private repo – not only in the `dev/bundle/` copy, which is deleted before merge – per the release's glitch-ledger rule.
  - **Verify**: at 1440×900, 900px and 768px no tile in the Overview row sits alone on a final row and every tile ends at the same baseline; each numeral's glyph centre aligns with its label's centre (the audited build measured a ~23px offset on ERRORS and LEARNINGS); `sed -n '/^## Implementation Observations/,$p' docs/specs/0.22.1/fis/s09-surface-sweep-health-memory-session-dashboards.md` in the **private** repo prints the sparkline deferral with its written reason

- [ ] **TI12** Memory KPI colour is driven by state, not by category
  - `memory_dashboard.html` hardcodes `card-metric--error` on Errors and `card-metric--accent` on Memory Size, so red labels the file rather than a state and a workspace at 95% of budget still shows a green numeral. Drive the modifier from data in `memory_dashboard.dart` – it already computes `budgetWarn = budgetPercent >= 80` and routes it only to `budgetWarnClass` – passing the card modifier through the context map alongside it. Keep the percentage and add a visible text cue: `Near limit` from 80% through 100%, `Over limit` above 100%, and no warning cue below 80%.
  - **Verify**: at 0 errors the Errors tile carries no `card-metric--error`; with `errorsCount > 0` it does; the Memory Size tile is unmodified below 80% of budget, `card-metric--warning` with visible `Near limit` text at 80–100%, and `card-metric--error` with visible `Over limit` text above 100%; removing colour still leaves each threshold state explicit

- [ ] **TI13** "Prune Now" is a real control whose confirm and result states are class-driven
  - `.btn-ghost` gives the pruner's only action – which archives and de-duplicates the agent's memory – no chrome at rest. Use `.btn-danger` given it is destructive, and drive the confirm/success/failure states in `dc_memory_controller.js` by swapping the button class instead of assigning `element.style.color`. Introduce no native `confirm()`; the existing two-step in-place confirm stays.
  - **Verify**: `rg -n "style.color" packages/dartclaw_server/lib/src/static/controllers/dc_memory_controller.js` returns no matches; "Prune Now" renders with a visible border and fill at rest in both themes, and each state change is legible with colour removed; the story's diff introduces no `window.alert` / `window.confirm` / `window.prompt` / bare `alert(` / `confirm(` / `prompt(` under `lib/src/static/controllers/` and no new `var(--text-sm)` reference anywhere (proves Structural Criteria 3 and 4)

- [ ] **TI14** The 30s polls on memory and the guard audit preserve reader state
  - Memory's whole-body swap (`hx-get="/memory/content" hx-trigger="every 30s" hx-swap="innerHTML" hx-select="#memory-inner"`) discards the active file tab, `preview.dataset.rawContent` and preview scroll every cycle; the audit's `outerHTML` poll on `#audit-table-container` collapses any expanded detail row. Scope memory's poll to the volatile regions and leave the files card out of the swap, or persist the active tab id to localStorage the way `initializeView()` already persists the view toggle and re-apply it after the swap; gate the audit poll so it does not fire while a detail row is open. Consumes TI08's disclosure markup.
  - **Verify**: with `errors.md` selected, loaded and scrolled, and an audit detail row expanded, both survive a poll cycle >30s; no second `/api/memory/files/*` fetch is issued per poll

- [ ] **TI15** `/memory` renders inside the `100dvh` shell
  - `/memory` is the only surface whose document escapes `.shell { height: 100dvh }`, painting a 433px band below the app frame that `background-attachment: fixed` leaves ungradiented. Diagnose the min-content overflow inside `#memory-inner` – likeliest a grid/flex descendant without `min-height: 0` / `min-width: 0` forcing the shell's `1fr` row past its track, `.page-content` being the row-2 child. Fix the cause, not the symptom.
  - **Verify**: full-page captures of `/memory` measure 1440×900 desktop and 768×1024 mobile in both themes, matching all 22 other surfaces, where the audited build measured 1440×1333 and 768×1705

- [ ] **TI16** Session info fits three token cards on one row and shows a human Created date
  - `.token-grid`'s unconditional `grid-template-columns: 1fr 1fr` orphans the third of `sessionInfoTemplate`'s three metric cards inside a bordered `.well`; give it an `auto-fit` track. Separately, `createdAt: session.createdAt.toIso8601String()` in `web_routes.dart` reaches `.meta-value` unformatted. Reuse the single timestamp format **S16 TI08's** data-formatting pass settled (`helpers.dart#formatRelativeTime`) – do not introduce a second one – and keep the ISO string in a `title` attribute.
  - **Verify**: the three cards render on one row at 1440px with no empty column and collapse cleanly at 768px; `rg -n "toIso8601String" packages/dartclaw_server/lib/src/web/web_routes.dart` shows no unformatted value reaching the session-info Created field (today it reports `:377`, the file's only occurrence), and the surface no longer prints `2026-04-15T10:00:00.000`; `git diff --name-only` for this story lists no `.dart` file outside `lib/src/templates/` other than `lib/src/web/web_routes.dart`, and its diff hunks in that file fall inside the session-info handler at `:371-388` – nothing in the `/health-dashboard/audit` handler at `:398-414`, which is S10's (proves Structural Criterion 6)

- [ ] **TI17** Absent values and empty meters on the three dashboards use the canonical treatments
  - Replace the hardcoded `'—'` stand-ins with the `.value-absent` element S03 ships – `session_info.dart`'s three token-card values and `createdAt`, and `audit_table.dart`'s Session / Channel / Peer detail cells – and apply `.meter--empty` to memory's meters at 0% so a zero budget reads as an empty track rather than a solid `--bg-crust` rule. Both classes come from S03; do not redeclare them.
  - **Verify**: `rg -n "u2014|—" packages/dartclaw_server/lib/src/templates/session_info.dart packages/dartclaw_server/lib/src/templates/audit_table.dart packages/dartclaw_server/lib/src/templates/session_info.html` returns no bare em-dash stand-in for an absent value; an absent token count and an absent audit Session render the `.value-absent` glyph in `--fg-sub0`, and a 0% meter is visibly distinct from the same meter without the modifier

### Testing Strategy
> Default test approach: per-task Verify lines + scenario tests scaffolded from Acceptance Scenarios.

- The story is overwhelmingly CSS/template work proved visually, with one exception worth automated coverage: `[TI10]`'s meter-label shape is exactly the regression the audit asks to pin – assert at the template-render layer that `.meter-label` yields two element children and no loose text node, so the pattern cannot regress in the other meter usages. (The audit route's request/response behaviour was the story's other automatable seam; it moved to S10 with the route, and S10's TI07 carries the test.)

### Validation

- Every scenario gates on both themes at 1440×900 and 768px against **this story's own story-start captures**, not the audit's 92-screenshot set – S01's re-tone and S02's re-scale have already moved every surface, so the audit set cannot isolate this story's deltas and stays the release-level baseline S14 re-proves once. Capture health, memory and session-info in both themes at both viewports before the first edit, then diff the post-sweep captures against those. The guard audit's baseline is the table **as rendered inside `/health-dashboard`**, captured empty, populated and with a filter applied – not the `/health-dashboard/audit` URL, which serves a naked fragment until S10 lands and is therefore no baseline for this story's table work. A regression outside this story's scope is reported, not absorbed. Use the `visual` testing profile on port 3338 – the only profile that renders all 23 surfaces.
- Three assertions need a **1024px** pass beyond the standard two viewports – TI06's memory tables, TI07's audit table and TI03's KPI row track – because FR3's criterion binds at "any viewport ≥ 1024px" and the release capture matrix is 1440×900 and 768×1024 only.
- Contrast-check every label TI02 re-tokens in light theme specifically; light is where the audited build failed (3.22:1 against 4.5:1 required).


## Final Validation Checklist

- [ ] `git diff --name-only` lists no path under `dev/design-system/` and none of `lib/src/static/{tokens.css,design-system.css,icons.css}` – this story authored no canon and re-synced nothing.
- [ ] Both deferrals – the chart/sparkline component and FR6's `.meter` half – are written into this FIS's Implementation Observations **in the private repo** with their reasons, ready for S14's glitch ledger.
- [ ] The three swept surfaces plus the in-page guard audit are re-captured in both themes at both viewports and diffed against this story's story-start captures, with the extra 1024px pass for the two `.data-table` families and the health KPI row.
- [ ] `git diff --name-only` lists no `.dart` file outside `lib/src/templates/` other than `lib/src/web/web_routes.dart`, whose hunks stay inside the session-info handler – the `/health-dashboard/audit` handler is untouched.


## Implementation Observations

> _Managed by exec-spec post-implementation – append-only. Spec authors: leave this section empty._

_No observations recorded yet._
