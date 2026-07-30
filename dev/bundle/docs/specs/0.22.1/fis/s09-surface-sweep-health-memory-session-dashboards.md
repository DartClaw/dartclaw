# Surface sweep: health, memory and session-info dashboards

**Plan**: dev/bundle/docs/specs/0.22.1/plan.json
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
> A story that changes a canon-owned rule edits `dev/design-system/` (tokens.css / components.css / icons.css / DESIGN.md / showcase.html) first, then re-syncs the served copies under `packages/dartclaw_server/lib/src/static/` — regenerating the two-line `/* Synced from … sha256: … */` provenance header — within the same story. `dev/tools/fitness/check_design_system_sync.sh` must be green at every story boundary. ONLY the P1 stories S01-S04 hold that right, and only for the three DRIFT-CHECKED files — `tokens.css`, `components.css` and `icons.css`. Those close once P1 completes; the serialized P3 stories consume the settled copies without re-syncing them. S05 re-syncs nothing new — it verifies the check is green after its purge. A P3 story that finds it needs a canon RULE stops and reports it for hoisting into the owning P1 story (surfaces and chrome to S01, type and icons to S02, form/control/tab/state to S03, dialog and feedback to S04); it does not add the rule itself. `DESIGN.md` and `showcase.html` are NOT closed and NOT drift-checked — they are prose and a demo, never synced — so any story that establishes a documented contract writes it there directly, and S14 reconciles the whole document at release close.

_This story is P3: it consumes canon and edits none of the three drift-checked files. Its one canon need — the `.card-featured-*` background-layer grammar fix it discovered — is hoisted to **S01** per `docs/specs/0.22.1/canon-hoist-manifest.md`._

### From `docs/specs/0.22.1/plan.json` – Shared decision: shared-surface ownership in the sweep phase
<!-- source: docs/specs/0.22.1/plan.json#sharedDecisions -->
<!-- extracted: 2026-07-25 plan remediation -->
> Three shared surfaces were claimed by more than one sweep story and are assigned once here. (1) PAGE TITLE: the topbar owns the page title and is the only `<h1>` on a page; six templates currently carry an in-page `<h1>` (`settings`, `knowledge_hub`, `kg_timeline`, `channel_detail`, `projects`, `login`) and each duplicate is deleted by the story owning that surface — settings by S11, knowledge_hub + kg_timeline + channel_detail by S10, projects by S15; `login` renders no topbar and keeps its `<h1>`. S16 promotes the shared topbar fragment to `<h1>` and asserts only that the fragment emits one and that no NEW duplicate is introduced — it cannot assert one-per-page, because it is barred from editing per-surface templates. Pages carry a subtitle or description head, never a second `<h1>`. (2) OFF-SCALE FONT SIZES: S07 alone normalizes every hard-coded off-scale font-size (`.provider-badge`, `.channel-mode-badge`, `.workflow-artifact-badge` and siblings); sweep stories keep only their own semantic edits to those rules and must not re-declare the size. (3) AUDIT ROUTE: S10 owns the `/health-dashboard/audit` non-fragment behaviour and renders the full page inline (preserving the `page` param, which a redirect would drop); S09 does not touch that handler.

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
> The PRD's NFR reuses the audit's 92-screenshot capture as the before/after baseline. That works at release level but NOT per story: S01 re-tones every surface before S02 re-scales its type, and each later story accumulates further intended deltas, so from S02 onward the audit set cannot isolate one story's work. Protocol: from S02 onward, each story captures its own story-start screenshots of the surfaces it touches, in both themes at desktop and 768px, and validates against those. S01 runs first on the still-audited tree, so the audit's 92-shot capture IS its story-start state — S01 alone validates against the audit set (its existing audit-baseline gate). Beyond S01, the 92-shot set stays the release-level baseline that S14 re-proves once. A story that finds a regression outside its own scope reports it rather than absorbing it.

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

- [x] **S01 [OC01] [TI03,TI04] The health dashboard's first viewport carries its numbers**
  - **Given** the `visual` testing profile on port 3338, health dashboard loaded at 1440×900
  - **When** the page renders in dark theme and again in light theme
  - **Then** the KPI row of `.card-metric` tiles is the first content under the topbar, fully visible above the fold, ahead of the Services card grid – and the row fills its track with no tile orphaned on a final row
  - **And** each of uptime, session count and DB size appears exactly once on the page, and no row prints the unmeasured constants `claude binary`, `active` or `file-based`
  - **And** the page renders no `.meter`, because no health KPI is a bounded ratio – and FR6's `.meter` half is recorded as an explicit deferral, with its reason, in this FIS's Implementation Observations, so S14's ledger carries the criterion as amended rather than as silently failed

- [x] **S02 [OC02] [TI10,TI11,TI12,TI17] The memory Overview row reads as one component**
  - **Given** the memory dashboard rendered with a 32 KB budget at 0% consumed and 0 errors recorded
  - **When** the Overview row renders at 1440×900 and again at 768px, in both themes
  - **Then** the budget meter label reads `of 32 KB` on the left and `0%` as a single adjacent unit – not a stranded `%` at the card's right edge
  - **And** every tile in the row has the same anatomy with no tile left alone on a final row at either width, and each numeral centres under its own label rather than sitting ~23px left of it
  - **And** the Errors tile carries no `card-metric--error` modifier at a count of 0, while a workspace at ≥80% of its memory budget renders the Memory Size tile as `card-metric--warning`
  - **And** a meter at 0% carries `.meter--empty` so it reads as an empty track rather than as a solid rule

- [x] **S03 [OC03] [TI01,TI02,TI05,TI06] The three dashboards adopt the canonical surface treatments**
  - **Given** the served `design-system.css` as S01–S04 left it – this story edits no canon file – with health, memory and session info loaded in both themes
  - **When** each page renders at 1440×900, and again at 1024px
  - **Then** the health hero card's `.card-featured-accent` gradient border is visibly distinct from its own fill in both themes, proving S01's hoisted background-grammar fix reaches this surface, and the health and memory pages render inside the wide container while session info stays at the 900px measure
  - **And** every page-section `<h2>` uses `.section-title`; memory's subtitle-only head and session info's title/session-id head both render through S16's shared `pageHeader`, add no second `<h1>`, and `.section-label` survives only on in-card subsections
  - **And** at 1024px every `th` in memory's three `.data-table`s – Recent Runs (`Date`, `Archived`, `Deduped`, `Remaining`, `Final Size`), Sections (`Section`, `Count`) and daily logs (`Date`, `Entries`, `Size`) – has `scrollWidth <= clientWidth`, so no header label is clipped or ellipsised, and none breaks mid-word
  - **And** no label carrying essential data – `.card-row-label`, `.metric-sub-inline`, `.meter-label`, `.detail-label`, `.pagination-info`, `.info-footer` – resolves to `--fg-overlay`; each measures ≥ 4.5:1 against the card fill in light theme

- [x] **S04 [OC03] [TI07,TI08,TI13] Guard audit and the pruner use real, accessible controls**
  - **Given** the guard audit table rendered inside the health dashboard with no audit entries recorded, and the memory pruner card
  - **When** a keyboard user tabs through the audit toolbar, the empty state, a populated audit row and the pruner action
  - **Then** the nine filters are `button.chip` elements whose active one carries `aria-pressed="true"`, the table carries `class="data-table"` with open header rules rather than a boxed cell grid, and the empty state rendered through S16's `emptyStateTemplate` contains the canonical hidden decorative icon, `.empty-state-title` and body paragraph with no inline `style` override
  - **And** the row disclosure is a real `<button>` inside the first cell with `aria-expanded` and `aria-controls` pointing at the detail row's `id` – the `<tr>` carries no `role="button"` – and every one of these controls shows a visible focus ring
  - **And** "Prune Now" renders with button chrome at rest, and its confirm/success/failure states are conveyed by a class swap rather than by `element.style.color`
  - **And** with the same table rendered at 1024px, each of the `TIMESTAMP`, `GUARD`, `VERDICT` and `DETAIL` `th` elements has `scrollWidth <= clientWidth` – no header label clipped behind the retained `white-space: nowrap` – and `.table-scroll` itself does not overflow, so the retained `min-width: 700px` still fits inside the wide container at that width

- [x] **S05 [OC04] [TI14,TI15] Reader state survives the 30s polls and `/memory` stays in the shell**
  - **Given** the memory dashboard with the `errors.md` tab selected, its preview loaded and scrolled, and audit page 2 filtered by verdict and guard with one detail row expanded from a fixture that also contains delimiter near-collisions, null-versus-empty values and a reordered result set
  - **When** a deterministic controller test advances a fake clock through two 30s intervals and dispatches the synthetic HTMX swap lifecycle for each response – without a wall-clock sleep – then repeats with the expanded entry removed
  - **Then** polling never pauses; `errors.md` is still the active tab with its loaded content and scroll position intact; the audit remains on page 2 with both filters; reordering restores only the same collision-safe row identity; and removing that identity leaves every row collapsed
  - **And** a full-page capture of `/memory` measures 1440×900 at desktop and 768×1024 at mobile, matching all 22 other surfaces, with no unstyled band below the app frame

- [x] **S07 [OC02,OC03] [TI16,TI17] Session info shows three token cards on one row and a human date**
  - **Given** a session created at `2026-04-15T10:00:00.000` with input, output and total token counts recorded
  - **When** session info renders at 1440×900 and again at 768px
  - **Then** the three `.token-grid` metric cards occupy a single row with no orphaned card beside an empty column, and collapse cleanly at 768px
  - **And** the Created value renders in the release's single timestamp format rather than the raw `2026-04-15T10:00:00.000`, with the ISO string preserved in a `title` attribute
  - **And** a session with no recorded token counts shows the canonical absent-value treatment in each card, not a hardcoded `—` string
  - **And** the page still measures 900px wide – session info is on the plan's 900px list and must not pick up the wide modifier


## Structural Criteria

- [x] **This story edits no canon file.** Canon closed after P1: with `BASE=.agent_temp/0.22.1-s09-entry`, `git diff --no-index --quiet "$BASE/dev/design-system" dev/design-system` exits 0 and the three `cmp -s` checks against the snapshotted served `tokens.css`, `design-system.css` and `icons.css` all exit 0. The drift check is not this story's to re-green – it is verified by S05 and S14 – and a canon rule this story turns out to need is reported for hoisting, not added here.
- [x] No app-side rule re-tones a card, chrome or page ground, and no app-side rule re-declares a canon-owned selector to work around a canon defect.
- [x] This story introduces no `window.alert` / `window.confirm` / `window.prompt` / bare `alert(` / `confirm(` / `prompt(` into `lib/src/static/controllers/`.
- [x] No `var(--text-sm)` reference is introduced – S07 deletes the compatibility alias before this story runs.
- [x] Both of this story's deferrals – the absent chart/sparkline component (TI11) and FR6's `.meter` half (TI03) – are written into this FIS's **Implementation Observations** with their reasons, not only into a prose bullet and not only into the transient `dev/bundle/` copy, since that block is the only input S14's glitch ledger reads.
- [x] No service, schema or public API contract changes. Session-info/audit absent values, session-info timestamp formatting, shared `pageHeader`, and the shell / `.page-content` overflow repair are S16's work; this story only adopts or regression-checks them and adds no duplicate helper, markup fallback or containment rule.
- [x] After targeted checks, run `dart run dev/tools/embed_assets.dart`, require `dart test packages/dartclaw_server/test/generated/embedded_assets_test.dart` green, then run the full `dart test packages/dartclaw_server/test` suite. The story closes only with all three stages green; S14 later performs release-wide idempotency reconciliation rather than owning this story's parity.


## Scope & Boundaries

### Work Areas
- `packages/dartclaw_server/lib/src/templates/health_dashboard.html` / `health_dashboard.dart` – KPI row ordering, card de-duplication, section headings, wide container (TI03, TI04, TI05, TI06)
- `packages/dartclaw_server/lib/src/templates/memory_dashboard.html` / `memory_dashboard.dart` – page head, meter label, tile anatomy, numeral centring, state-driven modifiers, poll scoping (TI05, TI06, TI10, TI11, TI12, TI14)
- `packages/dartclaw_server/lib/src/templates/audit_table.dart` – `.data-table`, `button.chip` filters, canonical empty state, row disclosure button, stable poll identity and regression consumption of S16's rendered absent values (TI07, TI08, TI14, TI17)
- `packages/dartclaw_server/lib/src/templates/session_info.html` / `session_info.dart` – shared `pageHeader` adoption, token grid, and regression consumption of S16's rendered absent values plus relative Created text with its ISO `title` (TI05, TI16, TI17)
- `packages/dartclaw_server/lib/src/static/app.css` – label colour tokens, `.metrics-grid` / `.metrics-grid-5` / `.token-grid` track definitions, `.filter-btn` and the `#audit-table-container` table overrides (TI02, TI03, TI07, TI11, TI16)
- `packages/dartclaw_server/lib/src/static/controllers/dc_memory_controller.js` and `dc_shell_controller.js` – tab/preview persistence across swaps, audit-row disclosure wiring, pruner state classes (TI08, TI13, TI14)
- `../dartclaw-private/docs/specs/0.22.1/fis/s09-surface-sweep-health-memory-session-dashboards.md` § Implementation Observations – the durable home for this story's two deferrals; the `dev/bundle/` copy is deleted before merge, so a record written only there is lost (TI03, TI11)

### What We're NOT Doing
- **The `/health-dashboard/audit` request handler in `web_routes.dart` – S10 owns it.** Per `plan.json`'s *Shared-surface ownership in the sweep phase* decision (3), S10 renders the full health page **inline** on a non-fragment request; the redirect this story previously specified is rejected because it drops the `page` param, which the inline render preserves, and S10 already owns `wantsFragment` plus the sibling wiki-route fix in the same file. Session-info `createdAt` formatting is likewise **S16's** shared-helper and call-site work; S09 consumes its rendered relative text and ISO `title` without editing `web_routes.dart`. *Numbering:* the removed task (TI09) and scenario (S06) leave gaps that are deliberately not back-filled, so cross-story references keep resolving.
- **Diagnosing or repairing shell / `.page-content` min-content overflow – S16 TI01 owns it.** S16 supplies the shrinkable `.shell` row plus app-owned `.page-content { min-height: 0; }` contract. S09 only proves that shared repair still holds on `/memory`; it adds no competing containment rule or per-memory workaround.
- **Replacing session-info or audit-table absent values, or repeating their em-dash grep – S16 TI09 owns those call sites.** S09 keeps rendered regression coverage for absent token/audit values and owns only `.meter--empty` on memory's 0% meters.
- **Implementing or bypassing `pageHeader` – S16 TI03 owns the fragment.** S09 adopts that exact seam for memory's subtitle head and session info's existing `.info-title` / `.info-subtitle` head; if it has not arrived, stop and report rather than emitting a direct subtitle/header fallback.
- **No `.meter` on the health dashboard – FR6's second acceptance criterion is half-deferred.** Verified in source: `healthDashboardTemplate` (`health_dashboard.dart:11-27`) receives only unbounded counters – `uptimeSeconds`, `sessionCount`, `dbSizeBytes`, `totalArtifactDiskBytes` – and `HealthService.getStatus()` (`health/health_service.dart:50-84`) emits no cap beside any of them, so nothing on this surface is a ratio a determinate meter could read. The only caps that exist (`sessions.maintenance.max_sessions`, `.max_disk_mb`) are absent from the payload, unset by default and unset in the `visual` profile, so surfacing one means a health-service change (barred by *No backend work*) plus a fact the page does not show today (barred by *New UX capabilities of any kind*). Recorded as a deferral in TI03 with that reason, so S14's ledger carries the criterion as amended instead of failing it silently.
- **No chart, sparkline or `--chart-*` backing component.** Canon defines a chart ramp with no component behind it; building one is a new UX capability the release explicitly excludes. Recorded as a deferral in TI11 so it counts against the glitch ledger rather than vanishing.
- **No canon edit and no re-sync.** Canon closed after P1. The `.card-featured-*` background-layer grammar fix this story's audit trail discovered is **S01's**, hoisted per `docs/specs/0.22.1/canon-hoist-manifest.md`; this story consumes it and asserts the visible result on the health hero card. A canon rule that turns out to be missing is reported for hoisting, never added here and never worked around with an app-side re-declaration.
- **The topbar page title and sidebar logo type tiers** – the `health-dashboard` typography finding names `.topbar .session-title-static` and `.sidebar-header .logo`, both canon-owned shell chrome. S02 raises the topbar title to the page-title tier and S12 sweeps the shell; this story fixes only the health page's own heading tiers.
- **Per-surface empty-state markup** – S16 TI04 deletes `.table-empty-cell` and ships the shared `emptyStateTemplate`; S08 adopts it for scheduling. S09's audit adopts that same fragment in TI07 and must not restore, style or verify the retired selector.
- **Wiring FTS5 Index / Runtime / Format to real probes** – that needs a health-service change, which the no-backend-work constraint excludes. TI04 removes the unmeasured assertions instead.
- **Re-toning any card, chrome or ground token** – S01 owns the surface ladder. Surface complaints found here go back to S01's tokens, not into `app.css`.


## Architecture Decision

**Approach**: Adopt what is already served – every fix uses a primitive that exists in canon today (`.card-metric`, `.meter`, `.data-table`, `button.chip[aria-pressed]`, `.empty-state`, `.section-title`, `.content-inner--wide`); nothing new is invented and nothing in `dev/design-system/` is touched.
**Why this over alternatives**: the audit's finding is that the primitives exist and were skipped, so an adoption sweep closes the gap without widening canon's surface. The one canon-grammar defect this surface exposed (`.card-featured-*`) is fixed upstream in S01 rather than here; S09 executes alone in W5 and consumes the settled canon, so its contribution is to *prove* the hoisted fix lands on the health hero card, not to author it.


## Code Patterns & External References

```
# type | path#anchor or url                                                        | why needed (intent)
file   | packages/dartclaw_server/lib/src/templates/components.html#metricCard     | The metric-card fragment health and session info compose; `.card-metric` + `.metric-value` + `.metric-label` anatomy TI11 must make uniform
file   | packages/dartclaw_server/lib/src/templates/memory_dashboard.html#.metrics-grid-5 | The five-tile Overview row: meter-label three-child bug, hardcoded --accent/--error modifiers, sub-inline inside the centred value box
file   | packages/dartclaw_server/lib/src/templates/health_dashboard.dart#healthDashboardTemplate | cardDefs + metricsHtml assembly – where the duplicated rows and hardcoded constants live
file   | packages/dartclaw_server/lib/src/templates/audit_table.dart#auditTableFragment | Filter toolbar, empty state, `<table>` without .data-table, `<tr role="button">` disclosure, pagination
file   | packages/dartclaw_server/lib/src/templates/scheduling.html                 | Sibling surface already using `class="data-table"` correctly – the shape TI07 converges on
file   | dev/design-system/components.css#.data-table                               | Read-only: canon's open-header treatment, including S02's `th { white-space: nowrap; }`, which TI07 adopts
file   | dev/design-system/components.css#.chip                                     | `button.chip[aria-pressed="true"]` toggle-filter treatment, fully backed – adopt, do not re-declare
file   | dev/design-system/components.css#.empty-state                              | Canonical icon + `<p>` structure and `--sp-12`/`--sp-4` padding the audit empty state overrides away
file   | packages/dartclaw_server/lib/src/static/controllers/dc_memory_controller.js#initializeView | Reads the persisted view toggle back from localStorage on connect (the matching write lives in the toggle handler) – the persist-and-reapply pattern TI14 extends to the active tab
wire   | docs/wireframes/health-dashboard.html                                      | Intended health information hierarchy
```


## Constraints & Gotchas

- **NOTICED**: FR6's acceptance criterion "`health_dashboard.html` uses `.metric-value` and `.meter`" and the audit's worked example ("uses **neither**… verified by grep") rest on a grep of `health_dashboard.html` alone. The page *does* render four `.card-metric` tiles with `.metric-value`, composed in `health_dashboard.dart:144-149` via `metricCardTemplate` → `components.html#metricCard`. What is actually true: health uses no `.meter` anywhere, and its KPI row sits below the fold. **Disposition, both halves:** the `.metric-value` half needs no work – do not add one that is already there. The `.meter` half is **deferred, not silently dropped**: the surface has no bounded ratio to meter (payload evidence in What We're NOT Doing), so TI03 records the deferral with its reason in Implementation Observations and S14's ledger carries the criterion as amended. Implement the measured defects (ordering, duplication) and leave the criterion's meter half to the ledger.
- **Constraint**: `app.css` loads *after* `design-system.css` (`layout.html:16-17`), so an app rule of equal specificity wins. Deleting an app override (TI07's `#audit-table-container` cell borders, TI02's colour declarations) hands the property back to canon – re-validate the surface visually after each deletion rather than assuming the canon value matches what shipped.
- **Constraint**: this story executes alone in W5 after S08 W4 and receives the accumulating `app.css`; S10 W6, S11 W7, S12 W8 and S15 W9 follow. Every rule this story edits must be located by selector, never by the line numbers the audit records – they are from the audited build and have moved. Keep edits inside the `SESSION INFO`, `AUDIT TABLE`, `SCHEDULING`, `SCHEDULING: JOB MANAGEMENT` and `MEMORY DASHBOARD` blocks, preserving S08's earlier regions – `SESSION INFO` holds TI16's `.token-grid`, and the two scheduling blocks hold TI02's `.cron-*` / `.info-footer` token edits. S16 TI04 has already retired `.table-empty-cell`; it is neither a S09 edit target nor an allowed selector to restore.
- **Critical**: `.card-featured-*` fails because a bare `<color>` is only valid in a `<final-bg-layer>` of the `background` shorthand, so the whole declaration is dropped and only `border: 1px solid transparent` survives. **S01 fixes this in canon** (hoist manifest); this story only consumes it. If the health hero card's ring is still indistinguishable from its fill when this story runs, that is an S01 regression to report – **not** an app-side override to write: `app.css` loads after `design-system.css`, so a local patch would silently win and hide the canon defect from every other featured card in the app.
- **Avoid**: conveying the pruner's confirm/success/failure states through `--warning` / `--success` / `--error` text colour alone – status must never be conveyed by colour alone. Locate by symbol, not line: `dc_memory_controller.js` carries **five** `style.color` assignments across the confirm, result and reset paths (the audit records only three), and TI13's Verify requires all five gone. Instead: swap the button's class so the state inherits real button chrome plus its label change.


## Implementation Plan

### Implementation Tasks

Before TI01, snapshot the canon and served CSS exactly as W5 receives them. These comparisons isolate S09's own delta from the accumulated W1–W4 checkout:

```sh
BASE=.agent_temp/0.22.1-s09-entry
rm -rf "$BASE"
mkdir -p "$BASE/dev" "$BASE/packages/dartclaw_server/lib/src/static"
cp -R dev/design-system "$BASE/dev/"
cp packages/dartclaw_server/lib/src/static/tokens.css packages/dartclaw_server/lib/src/static/design-system.css packages/dartclaw_server/lib/src/static/icons.css "$BASE/packages/dartclaw_server/lib/src/static/"
```

- [x] **TI01** S01's featured-card gradient border is proved on the health hero card – this story authors no canon
  - Consume, do not author: S01 replaces the bare colour layer in all eight `.card-featured-{accent,info,error,warning}` base and `:hover` rules with the `linear-gradient(<card-fill>, <card-fill>) padding-box, linear-gradient(135deg, …) border-box` idiom and re-syncs the served copy (hoist manifest, row 1). This story's job is to confirm the fix reaches `health_dashboard.html:15`, whose `statusCardClass` resolves to `card-featured-accent` when healthy, `--warning` when degraded and `--error` otherwise (`health_dashboard.dart:33-37`) – and to report a miss upstream rather than patching `app.css`.
  - **Verify**: with `BASE=.agent_temp/0.22.1-s09-entry`, `git diff --no-index --quiet "$BASE/dev/design-system" dev/design-system` exits 0 and `for rel in packages/dartclaw_server/lib/src/static/tokens.css packages/dartclaw_server/lib/src/static/design-system.css packages/dartclaw_server/lib/src/static/icons.css; do cmp -s "$BASE/$rel" "$rel" || exit 1; done` exits 0; pixel-sampling the health hero card's border ring against its own fill shows a visible delta in both themes, where the audited build measured Δ6 in light and indistinguishable in dark; `rg -n "card-featured" packages/dartclaw_server/lib/src/static/app.css` returns no matches (exit 1), proving no app-side re-declaration was added to compensate

- [x] **TI02** Load-bearing dashboard labels sit on `--fg-sub0`, leaving `--fg-overlay` to placeholders and disabled controls
  - In `app.css`, move `.card-row-label`, `.cron-expr`, `.cron-human`, `.info-footer`, `.pagination-info`, `.detail-label`, `.metric-sub-inline` and `.meter-label` from `--fg-overlay` to `--fg-sub0`, and drop the `opacity: 0.6` from `.cron-human--sub-id`, differentiating the Schedule column by tier instead. Locate by selector, not by line number. Do not restore or style S16 TI04's retired `.table-empty-cell`; table empties compose S16's shared `emptyStateTemplate` and are verified by TI07.
  - **Verify**: each listed selector computes `--fg-sub0` (light `#62677d`, ≥ 4.5:1 on the card fill) with no `--fg-overlay` and no `opacity` left on `.cron-human--sub-id`; contrast-check every one in light theme on health, health/audit, memory and scheduling. Confirm the audit's empty rendering through TI07's shared-fragment proof, not through a retired-selector assertion.

- [x] **TI03** The health dashboard's KPI row is the first content under the topbar and fills its track
  - Move the metrics grid above the Services grid in `health_dashboard.html`, and give `.metrics-grid` a `repeat(auto-fit, minmax(…, 1fr))` track in `app.css` so four tiles form one row rather than 3+1 under the current `repeat(3, 1fr)` (`app.css:586-589`). Matches DESIGN.md § Composition Patterns → Dashboard layout, whose KPI row leads.
  - **Also record FR6's `.meter` deferral here**, because this is the task that owns the health KPI row. Re-check the live payload first: if every value the row can reach is an unbounded counter, write the deferral into this FIS's **Implementation Observations** naming FR6 acceptance criterion 2 verbatim, the half already satisfied (`.metric-value`, via `metricCardTemplate`), the half not satisfiable (`.meter`), and the reason – no bounded ratio in `healthDashboardTemplate`'s parameters or in `HealthService.getStatus()`, and the only caps that exist (`sessions.maintenance.max_sessions`, `.max_disk_mb`) are outside the payload, unset by default and unset in the `visual` profile, so surfacing one is a service change plus a new fact on the page. If the re-check instead finds a bounded pair the page already carries, the deferral is void: ship `.meter` + `.meter-fill` on it, paired with a visible label per DESIGN.md § Meters, and say so in Implementation Observations.
  - **Verify**: at 1440×900 in both themes the four `.card-metric` tiles render on one row, entirely above y=900, ahead of the Services `.card-grid`; the row still collapses without an orphan at 1024px and at 768px – the `auto-fit` track is what makes 1024px a real check, since it can resolve to 3+1 there while looking correct at both other widths. For the deferral: `rg -n "meter" packages/dartclaw_server/lib/src/templates/health_dashboard.html packages/dartclaw_server/lib/src/templates/health_dashboard.dart` returns no matches (exit 1, no output) **and** `sed -n '/^## Implementation Observations/,$p' ../dartclaw-private/docs/specs/0.22.1/fis/s09-surface-sweep-health-memory-session-dashboards.md` prints a record naming FR6 and `.meter` with its reason – both halves required, since absence alone is exactly the silent omission success metric 5 fails on, and a record written only into the `dev/bundle/` copy is deleted before merge

- [x] **TI04** Health service cards state each fact once and assert nothing the app did not measure
  - In `health_dashboard.dart`, drop the rows that restate their own card badge (Worker→State, Sessions→Total), collapse the Database and Storage cards into one (both report the same byte count), and remove the hardcoded `'claude binary'`, `'active'` and `'file-based'` values rather than wiring probes for them – probes are backend work this release excludes.
  - **Verify**: `rg -n "claude binary|'active'|file-based" packages/dartclaw_server/lib/src/templates/health_dashboard.dart` returns no matches; the rendered page shows uptime, session count and DB size exactly once each

- [x] **TI05** Page-section headings use `.section-title`, while memory and session info adopt S16's `pageHeader`
  - Arrival gate: S16's `components.html#pageHeader` fragment and `components.dart#pageHeaderTemplate` must exist before this task starts. If either is absent, stop and report S16 incomplete; there is no direct subtitle or copied-header fallback.
  - Swap `class="section-label"` → `class="section-title"` on the page-section `<h2>`s in `health_dashboard.html` and `memory_dashboard.html`, keeping `.section-label` for in-card subsections such as memory's "Recent Runs". Compose memory's subtitle-only head through `pageHeaderTemplate` with the optional `<h2>` omitted; compose session info's existing title/session-id head through the same fragment, replacing `.info-title` / `.info-subtitle`. The topbar remains the sole page `<h1>`.
  - **Verify**: `rg -c 'class="section-title"' packages/dartclaw_server/lib/src/templates/*.html` prints a count line for both `health_dashboard.html` and `memory_dashboard.html`; `rg -n 'info-title|info-subtitle' packages/dartclaw_server/lib/src/templates/session_info.html packages/dartclaw_server/lib/src/static/app.css` returns no matches; rendered `/memory` and `/sessions/{id}/info` each contain one shared `<header class="pagehead">` with the expected subtitle/title content and exactly one `<h1>` supplied by the topbar; "MEMORY PRUNING" is typographically distinct from "RECENT RUNS"

- [x] **TI06** Health and memory take the wide container; session info keeps the 900px measure
  - Add `content-inner--wide` to the health dashboard's `.content-inner` and `page-inner--wide` to memory's `.page-inner`, per the plan's fixed assignment. `session_info.html` keeps bare `.content-inner`. Both modifiers ship from S02 – do not redefine them. The container is also what decides whether memory's three existing `.data-table`s have room for their headers, so prove that in the same pass.
  - **Verify**: at 1440px health and memory compute a container wider than 900px while session info still computes `max-width: 900px`; all three still centre and collapse cleanly at 768px; and at **1024px** – the lower bound of FR3's "any viewport ≥ 1024px", which no story checks on this story's tables – every `th` in memory's three `.data-table`s (Recent Runs, Sections, daily logs; locate by the table, not by line) has `scrollWidth <= clientWidth` and no computed `word-break`/`overflow-wrap` that permits a mid-word break. S02's canon `.data-table th { white-space: nowrap; }` supplies the no-wrap treatment; assert clipping and width, not line count, because the failure to close is a clipped label or a label broken inside a word.

- [x] **TI07** The guard audit renders as a canonical data table with chip filters and S16's shared empty state
  - In `audit_table.dart`: add `class="data-table"` to the `<table>`, emit `class="chip"` with `aria-pressed` for the nine filters, replace the raw `<span style="margin-left:auto">` spacer with a layout class, and compose the empty case through S16's `emptyStateTemplate`, passing the audit's title and `No guard events recorded yet` body copy. Do not hand-author `.empty-state` markup, an icon, or an inline-style replacement; S16's fragment supplies the default hidden decorative icon, `.empty-state-title` and body anatomy. In `app.css` delete `.filter-btn` and, from `#audit-table-container .table-scroll th, td` (`:551`), the `border: var(--border)` declaration plus the `th` background/colour fill at `:552`, so the cells fall back to canon's open header rule. S02's canon `.data-table th` supplies `white-space: nowrap`; keep the audit-specific `min-width: 700px` so the four-column table fits inside the wide container at 1024px without reader-facing horizontal overflow. If the app selector also applies nowrap to `td`, narrow it to `td` only so the canonical header rule remains the sole `th` owner.
  - **Verify**: `rg -n "filter-btn|style=\"margin-left:auto\"|style=\"padding:var\(--sp-6\)" packages/dartclaw_server/lib/src/templates/audit_table.dart packages/dartclaw_server/lib/src/static/app.css` returns no matches; `rg -n 'emptyStateTemplate' packages/dartclaw_server/lib/src/templates/audit_table.dart` returns the audit empty-case composition, while `rg -n 'class="empty-state"|icon-shield-alert' packages/dartclaw_server/lib/src/templates/audit_table.dart` returns no matches; `rg -c 'class="chip' packages/dartclaw_server/lib/src/templates/audit_table.dart` returns a non-zero count. With no audit entries, the rendered output contains S16's shared `.empty-state` anatomy – hidden decorative icon, `.empty-state-title` and the `No guard events recorded yet` body paragraph – with no inline style. The audit table renders with canon's open header rule (no boxed cells, no filled header bar), and the active filter's accent tint resolves from canon's `.chip[aria-pressed="true"]` rule rather than any `app.css` rule – today's `.filter-btn` already emits `aria-pressed` and already tints, so an `aria-pressed`-only check passes pre-implementation. At **1024px** each of the four `th`s (`Timestamp`, `Guard`, `Verdict`, `Detail`) has `scrollWidth <= clientWidth` and `.table-scroll` has `scrollWidth <= clientWidth`, proving the canon nowrap header rule and retained `min-width: 700px` fit inside the wide container without reader-facing horizontal overflow.

- [x] **TI08** The audit row disclosure is a real button with `aria-controls` and a visible focus ring
  - Drop `role="button"` and `tabindex="0"` from the `<tr class="audit-row">` in `audit_table.dart`; move the trigger into the first cell as a `<button>` carrying a canonical button class (so it inherits canon's `:where(.btn, …):focus-visible` ring with no canon edit), with `aria-expanded` and `aria-controls` pointing at an `id` given to the sibling `.audit-detail-row`. Repoint `dc_shell_controller.js`'s `toggleAuditRow` at the button.
  - **Verify**: `rg -n 'role="button"|tabindex="0"' packages/dartclaw_server/lib/src/templates/audit_table.dart` returns no matches; the toggle is keyboard-reachable, shows a focus ring, flips `aria-expanded`, and its `aria-controls` resolves to the detail row's `id`

- [x] **TI10** The memory budget meter label renders its percentage as one unit
  - `.meter-label` is `display: flex; justify-content: space-between`, and `memory_dashboard.html` currently feeds it three children – the bare `%` text node becomes an anonymous third flex item and is flung to the card's right edge. Wrap value and unit in one element so the label has exactly two children.
  - **Verify**: at 1440×900 and 768px the label reads `of 32 KB` left and `0%` right as two adjacent glyph runs, with no `%` detached at the far edge; the rendered `.meter-label` has exactly two element children and no loose text node

- [x] **TI11** The memory Overview row has uniform tile anatomy, no orphan tile, and numerals centred under their labels
  - Give every tile in the row the same anatomy (Active/Archived currently come from the plain `metricCardTemplate` and end short of their metered neighbours – the audit measures the same gap twice, at ~55px and ~30px) and replace `.metrics-grid-5`'s fixed `repeat(5,1fr)` / `repeat(3,1fr)` / `repeat(2,1fr)` ladder with an `auto-fit` track so no tile is left alone. Make `.metric-value` centre the numeral independently of its `.metric-sub-inline` suffix, and split the byte unit out of the Memory Size value in `memory_dashboard.dart` so `0 B` and `3 / 50` share one treatment. Record the absent chart/sparkline component as an explicit deferral with its reason in `../dartclaw-private/docs/specs/0.22.1/fis/s09-surface-sweep-health-memory-session-dashboards.md` under **Implementation Observations** – not only in the `dev/bundle/` copy, which is deleted before merge – per the release's glitch-ledger rule.
  - **Verify**: at 1440×900, 900px and 768px no tile in the Overview row sits alone on a final row and every tile ends at the same baseline; each numeral's glyph centre aligns with its label's centre (the audited build measured a ~23px offset on ERRORS and LEARNINGS); `sed -n '/^## Implementation Observations/,$p' ../dartclaw-private/docs/specs/0.22.1/fis/s09-surface-sweep-health-memory-session-dashboards.md` prints the sparkline deferral with its written reason

- [x] **TI12** Memory KPI colour is driven by state, not by category
  - `memory_dashboard.html` hardcodes `card-metric--error` on Errors and `card-metric--accent` on Memory Size, so red labels the file rather than a state and a workspace at 95% of budget still shows a green numeral. Drive the modifier from data in `memory_dashboard.dart` – it already computes `budgetWarn = budgetPercent >= 80` and routes it only to `budgetWarnClass` – passing the card modifier through the context map alongside it. Keep the percentage and add a visible text cue: `Near limit` from 80% through 100%, `Over limit` above 100%, and no warning cue below 80%.
  - **Verify**: at 0 errors the Errors tile carries no `card-metric--error`; with `errorsCount > 0` it does; the Memory Size tile is unmodified below 80% of budget, `card-metric--warning` with visible `Near limit` text at 80–100%, and `card-metric--error` with visible `Over limit` text above 100%; removing colour still leaves each threshold state explicit

- [x] **TI13** "Prune Now" is a real control whose confirm and result states are class-driven
  - `.btn-ghost` gives the pruner's only action – which archives and de-duplicates the agent's memory – no chrome at rest. Use `.btn-danger` given it is destructive, and drive the confirm/success/failure states in `dc_memory_controller.js` by swapping the button class instead of assigning `element.style.color`. Introduce no native `confirm()`; the existing two-step in-place confirm stays.
  - **Verify**: `rg -n "style.color" packages/dartclaw_server/lib/src/static/controllers/dc_memory_controller.js` returns no matches; "Prune Now" renders with a visible border and fill at rest in both themes, and each state change is legible with colour removed; the story's diff introduces no `window.alert` / `window.confirm` / `window.prompt` / bare `alert(` / `confirm(` / `prompt(` under `lib/src/static/controllers/` and no new `var(--text-sm)` reference anywhere (proves Structural Criteria 3 and 4)

- [x] **TI14** Every 30s poll continues while preserving reader state and audit identity
  - Memory's whole-body swap (`hx-get="/memory/content" hx-trigger="every 30s" hx-swap="innerHTML" hx-select="#memory-inner"`) discards the active file tab, `preview.dataset.rawContent` and preview scroll every cycle. Scope the poll to volatile regions and leave the files card out of the swap, or capture/reapply active tab, preview content and scroll after every swap.
  - The audit poll remains `every 30s` unconditionally – no `htmx:beforeRequest` cancellation, pause attribute, conditional trigger or "poll only when collapsed" escape. Include current `page`, `verdict` and `guard` in the poll URL. Give each disclosure a collision-safe presentation key by encoding a structured tuple of the eight fields the row renders – normalized timestamp, guard, verdict, hook, session id, channel, peer id and reason (`AuditEntry` also persists `rawProviderToolName`, `server` and `tool`, which the row does not render and the key does not need) – with JSON plus URL-safe base64 (or an equivalently injective encoding); never concatenate with a delimiter and never use row position. Capture the expanded key before `outerHTML`, and re-expand only the matching row after swap when it is still present. Preserve the page and filter controls exactly; a refresh must not jump to page 1, clear a filter or open a different row. Consumes TI08's disclosure button/id markup.
  - **Verify**: use a deterministic synthetic polling test – fake clock plus manufactured `htmx:beforeSwap` / `htmx:afterSwap` payloads, never a 60s sleep – with `errors.md` selected, loaded and scrolled and audit page 2 filtered by `verdict=block&guard=file`. Two 30s ticks issue two audit requests carrying all three query values; memory state survives with no second `/api/memory/files/*` fetch per poll. Audit identity fixtures include values that collide under naive concatenation (`["ab", "c"]` versus `["a", "bc"]`), a delimiter inside a field, null versus empty string, and the same entries returned in a different order; each key is distinct where the structured tuples differ, and reordering restores only the originally expanded entry. A final response without that tuple leaves every row collapsed rather than transferring expansion

- [x] **TI15** `/memory` regression-checks S16's `100dvh` shell repair
  - Consume S16 TI01's shared shell contract – the canon `.shell` / `.content-area` shrinkable row plus app-owned `.page-content { min-height: 0; }`. Do not diagnose the overflow again, edit `.page-content`, or add a memory-specific containment workaround; this task verifies that S09's memory layout and polling changes preserve the shared repair.
  - **Verify**: `rg -n 'grid-template-rows:\s*var\(--topbar-h\) minmax\(0, 1fr\)' packages/dartclaw_server/lib/src/static/design-system.css` matches the canon half of S16's consumed repair, and `rg -nU --multiline-dotall '^\.page-content[^{]*\{[^}]*\}' packages/dartclaw_server/lib/src/static/app.css | rg 'min-height:\s*0'` matches S16's app-owned half; full-page captures of `/memory` measure 1440×900 desktop and 768×1024 mobile in both themes, matching all 22 other surfaces, where the audited build measured 1440×1333 and 768×1705

- [x] **TI16** Session info fits three token cards on one row and consumes the shared Created-date rendering
  - `.token-grid`'s unconditional `grid-template-columns: 1fr 1fr` orphans the third of `sessionInfoTemplate`'s three metric cards inside a bordered `.well`; give it an `auto-fit` track. **S16 TI08 owns** formatting the session's Created value through `helpers.dart#formatRelativeTime` and exposing its source ISO string as a `title`; this task consumes that rendered relative text and title without adding a formatter or editing `web_routes.dart`.
  - **Verify**: the three cards render on one row at 1440px with no empty column and collapse cleanly at 768px; `dart test packages/dartclaw_server/test/templates/task_detail_template_test.dart --plain-name 'session info consumes shared relative Created rendering'` passes a `createdAt: '2026-04-15T10:00:00.000'` fixture, computes the expected text through S16's `formatRelativeTime(DateTime.parse(createdAt))`, asserts the rendered Created value carries `title="2026-04-15T10:00:00.000"`, and rejects `>2026-04-15T10:00:00.000<`

- [x] **TI17** Empty meters are S09-owned; S16's absent values remain rendered correctly
  - Apply `.meter--empty` to memory's meters at 0% so a zero budget reads as an empty track rather than a solid `--bg-crust` rule. Do not replace session-info or audit-table absent values and do not repeat S16's tree grep; those call sites and the shared helper are S16 TI09's ownership.
  - **Verify**: a 0% memory meter carries `.meter--empty` and is visibly distinct from the same meter without the modifier; rendered regression fixtures still show S16's `.value-absent` treatment for an absent token count and absent audit Session, while legitimate `0` values remain visible as `0`

### Testing Strategy
> Default test approach: per-task Verify lines + scenario tests scaffolded from Acceptance Scenarios.

- Automated coverage pins `[TI10]` `.meter-label` anatomy, `[TI14]` memory state plus always-on audit polling through a fake clock and synthetic HTMX swaps – including near-collision, null/empty, reordered and disappeared-entry fixtures for the collision-safe key – `[TI16]` S16's relative Created rendering, `[TI17]` empty-meter plus rendered absent-value regression, and `[TI05]` shared `pageHeader` adoption. No polling test waits for real time. (The audit route's full-page request/response behaviour remains S10's test.) After these targeted checks and generated parity, run the full `dart test packages/dartclaw_server/test` suite because this story rewrites shared templates/controllers.

### Validation

- Every scenario gates on both themes at 1440×900 and 768px against **this story's own story-start captures**, not the audit's 92-screenshot set – S01's re-tone and S02's re-scale have already moved every surface, so the audit set cannot isolate this story's deltas and stays the release-level baseline S14 re-proves once. Capture health, memory and session-info in both themes at both viewports before the first edit, then diff the post-sweep captures against those. The guard audit's baseline is the table **as rendered inside `/health-dashboard`**, captured empty, populated and with a filter applied – not the `/health-dashboard/audit` URL, which serves a naked fragment until S10 lands and is therefore no baseline for this story's table work. A regression outside this story's scope is reported, not absorbed. Use the `visual` testing profile on port 3338 – the only profile that renders all 23 surfaces.
- Three assertions need a **1024px** pass beyond the standard two viewports – TI06's memory tables, TI07's audit table and TI03's KPI row track – because FR3's criterion binds at "any viewport ≥ 1024px" and the release capture matrix is 1440×900 and 768×1024 only.
- Contrast-check every label TI02 re-tokens in light theme specifically; light is where the audited build failed (3.22:1 against 4.5:1 required).


## Final Validation Checklist

- [x] With `BASE=.agent_temp/0.22.1-s09-entry`, `git diff --no-index --quiet "$BASE/dev/design-system" dev/design-system` exits 0 and the three served-CSS `cmp -s` checks exit 0 – this story authored no canon and re-synced nothing.
- [x] Both deferrals – the chart/sparkline component and FR6's `.meter` half – are written into `../dartclaw-private/docs/specs/0.22.1/fis/s09-surface-sweep-health-memory-session-dashboards.md` with their reasons, ready for S14's glitch ledger.
- [x] The three swept surfaces plus the in-page guard audit are re-captured in both themes at both viewports and diffed against this story's story-start captures, with the extra 1024px pass for the two `.data-table` families and the health KPI row.
- [x] Memory and session info render S16's shared `pageHeader` with no fallback; S16's absent-value and shell / `.page-content` repairs are consumed without overlap; deterministic synthetic polling proves always-on refresh, page/filter preservation and collision-safe expanded-row identity across near-collisions and reorder; S10 alone owns the `/health-dashboard/audit` full-page handler.
- [x] Targeted tests pass, generated assets are refreshed and parity is green, then `dart test packages/dartclaw_server/test` passes in full.


## Implementation Observations

> _Managed by exec-spec post-implementation – append-only. Spec authors: leave this section empty._

### Run: 2026-07-30 03:30 UTC – observations

#### DEFERRALS (for the release glitch ledger)

- **FR6 acceptance criterion 2 — "`health_dashboard.html` uses `.metric-value` and `.meter`" — half satisfied, half deferred (TI03).** The `.metric-value` half was **already true** at story entry and needed no work: the page composes four `.card-metric` tiles through `metricCardTemplate` → `components.html#metricCard`, each emitting `.metric-value`. The `.meter` half is **deferred, not dropped**. Re-checked against the live payload as TI03 requires: `healthDashboardTemplate` receives `uptimeSeconds`, `sessionCount`, `dbSizeBytes`, `totalArtifactDiskBytes`, `version`, `workerState` and an optional `pubsubHealth` map (`consecutive_errors`, `active_subscriptions`) — every one an unbounded counter, none paired with a cap. `HealthService.getStatus()` emits no cap either. The only caps that exist (`sessions.maintenance.max_sessions`, `.max_disk_mb`) are absent from the payload, unset by default and unset in the `visual` profile, so metering one would need a health-service change (barred by *No backend work*) plus a fact the page does not show today (barred by *New UX capabilities of any kind*). A determinate meter with no denominator would report a ratio the system never measured. **S14's ledger should carry the criterion as amended, not as failed.**

- **No chart, sparkline or `--chart-*` backing component (TI11).** Canon defines a `--chart-*` colour ramp with no component behind it. The memory Overview row's history-shaped findings would need one; building it is a new UX capability this release explicitly excludes. Deferred with no target milestone.

#### HOIST REQUEST TO S02 — canon is closed, reported not written

- **Every `.empty-state` renders a solid accent square where its decorative icon belongs.** `components.html#emptyState` emits `<div class="icon" aria-hidden="true">❯_</div>`. Canon's base `.icon` (`icons.css:208`) is mask machinery — `background-color: currentColor` plus `mask-size/repeat/position` — and paints a filled 1em box unless a companion `.icon-<name>` supplies `mask-image`. Canon's `.empty-state .icon` (`design-system.css:1767`) is a *text* treatment (`font-size`, `color`, `text-shadow`) written for the `❯_` glyph, and it never neutralises the base's `background-color`, so the glyph is covered by an opaque block. Measured live on the guard audit empty state: `background-color: rgb(166, 227, 161)` (`--accent`), `mask-image: none`, 24×24. **Not fixed here on purpose**: the resolution is a canon rule (either `.empty-state .icon { background: none }` or a distinct class name for the text glyph), canon closed after P1, and an `app.css` override would silently win and hide the defect from every other empty state in the app. Owner: **S02** (type and icons). Blast radius is every consumer of S16's shared fragment, not just this story's audit empty state.

#### DEFECTS FOUND AND CLOSED ON THESE SURFACES (not named by a task)

- **The guard audit's 30s poll blanked the entire health dashboard, every cycle.** `hx-target` and `hx-select` are inheritable. `#audit-table-container` declared only `hx-get`/`hx-trigger`/`hx-swap`, so it inherited `hx-target="this"` and `hx-select=".content-inner"` from the health page's refresh wrapper: the poll replaced the whole `.content-inner` with the audit fragment and then selected a `.content-inner` that fragment does not contain, leaving `<main>` empty. Reproduced on the story-entry build (port 3338) as well as this one, so it is pre-existing, not a regression this story introduced — but it is the direct negation of TI14 and OC04, and it made the expanded-row identity work unobservable. The same inheritance broke every filter chip and pagination button: each replaced `#audit-table-container` with nothing. Fixed by having the fragment state its own `hx-target="this" hx-select="#audit-table-container"`, which the controls inside then inherit. Pinned by `audit_table_test.dart` and verified live across two poll cycles.

- **The health page's own 30s refresh reset the audit's filter, page and open row.** `dc-health` triggers a refresh of `.content-inner`, which contained the self-polling guard audit; the refresh requests `/health-dashboard` with no audit parameters, so every cycle returned the unfiltered first page and collapsed the reader's expanded row. The status refresh is now scoped to a `#health-live` region holding the KPI row, hero and service cards, with the audit section outside it — the same containment `/memory` uses for its files card. Verified live: with the Block verdict filter applied and row 3 expanded, both survive two poll cycles.

- **The audit table's body cells were all `white-space: nowrap`, so the Detail column could not wrap.** A single long guard reason pushed `.table-scroll` past its container (measured 90px of reader-facing horizontal overflow at both 1024px and 768px). Narrowed to `td:not(:last-child)`: the three fixed-vocabulary columns stay on one line and the free-text Detail wraps. Re-measured 0px overflow at 1440/1024/768 with no `th` clipped and no mid-word break.

#### MECHANISM NOTES (Verify met, recipe adapted)

- **The three metric rows use explicit column ladders, not `repeat(auto-fit, minmax(…, 1fr))`.** TI03, TI11 and TI16 each name an `auto-fit` track, but `auto-fit` cannot satisfy their shared Verify ("no tile orphaned on a final row"). For a fixed item count the column count sweeps continuously as the viewport narrows, so a 4-tile row necessarily passes through 3 columns (3+1) and a 5-tile row through 4 and 2 (4+1, 2+2+1); no `minmax` minimum removes that band, and a percentage-based minimum pins the count instead. Each row now steps through counts that divide its tile count: `.metrics-grid-4` 4 → 2 → 1, `.metrics-grid-5` 5 → 3 → 1 (skipping the two-column rung), `.token-grid` 3 → 1. Measured orphan-free at 1440, 1280, 1024, 900, 768 and 600 on all three.

- **The memory Overview row aligns through row `subgrid`, which is what makes "every tile ends at the same baseline" true.** Two of the five tiles have no bounded ratio to meter, so giving them the literal three-part anatomy would have meant inventing a denominator. Instead `.metrics-grid-5` declares three row tracks (numeral, label, meter) and each `.card-metric` takes them with `grid-template-rows: subgrid`, so an unmetered tile simply leaves the third track empty while its numeral and label stay on the same lines as its neighbours'. Measured: one distinct value top, one label top and one meter top per tile row at every width. Same idiom S08 used for `.task-meta-grid`.

- **Numeral centring uses a three-track value box, not a nudge.** `.metric-value--suffixed` is `minmax(0, 1fr) auto minmax(0, 1fr)` with the numeral in the centre track and the suffix hanging into the third; `minmax(0, …)` rather than `1fr` is load-bearing, since a plain `1fr` grows with the suffix's min-content and pushes the numeral back off centre. Measured offset between each numeral's glyph centre and its label's centre: **0.0px** on all five tiles at all widths (audited build measured ~23px on ERRORS and LEARNINGS).

- **The health Worker service card was removed rather than left empty.** TI04 deletes its State row (restates its own badge) and its `'claude binary'` Runtime row, which leaves an info card with a header, a footer badge and no body. The fact it carried is measured, so it moved to the hero card's Worker row, which now takes the state's variant through `workerValueClass`. `app.css` gained `.card-row-value.text-{warning,error,muted}` beside the existing `.text-success`: `.card-row-value` and canon's `.text-*` utilities have equal specificity and `app.css` loads last, so without the paired selector the utility silently loses — which is also why the Pub/Sub card's warning and muted status rows were rendering in body colour.

- **Database, Storage and Sessions collapsed into one Storage card.** TI04 names the Database/Storage collapse (both printed the same byte count). Once the KPI row owns uptime, session count and DB size, Sessions' remaining content was a badge that reprinted the session count and one architecture fact, so keeping it as its own card would have required inventing a badge. Its `NDJSON files` row moved into the collapsed card, which now reads Database: SQLite / Sessions: NDJSON files. Each of the three measured facts appears exactly once on the page, pinned by a test.

- **The poll indicator is overlaid rather than reserved.** S16 routed the periodic layout shift here and left the treatment open. `.poll-skeleton` is now `position: absolute; inset: 0 0 auto 0` carrying canon's `.scan-bar`, so a refresh costs zero layout. `.task-timeline` gained `position: relative` so the timeline's own indicator still anchors to its card instead of escaping to the page scroller.

- **`audit_table.dart`'s fifth timestamp format was folded onto the shared helper (S16 TI08's routed decision).** S16 left the call: an audit log might legitimately want dense absolute times. Taken: the row now renders `formatRelativeTime` with the exact instant preserved in `<time datetime>` and `title`, matching every other surface. The disclosure is what serves the reader who needs the precise moment, and OC03's "no raw machine timestamp left on the surface" plus OC04's one-format rule both bind. Zero private formatters remain in the file.

#### NOTICED BUT NOT TOUCHING

- **`--fg-overlay` is *darker* than `--fg-sub0` in the light theme as S01 left it** — `#585d6f` vs `#62677d`, measuring 6.54:1 and 5.59:1 against the card fill. The tier ladder is inverted in light only (dark is correctly ordered: `#a6adc8` sub0 over `#9ea3bb` overlay). TI02's Verify still passes on its own terms — every listed selector computes `--fg-sub0` at `#62677d`, ≥ 4.5:1 on the card fill (5.59) and on the page ground (4.52) — but the audit's stated rationale for the move ("the audited build failed at 3.22:1") no longer describes the current tokens: the change is now a role separation, not a contrast repair. Token-level, S01/S14's to reconcile.
- **`.cron-human--sub-id` keeps an off-scale `font-size: 0.85em`.** TI02 removed its `opacity: 0.6`, leaving size as the only differentiator from its sibling. Off-scale font sizes are S07's exclusive surface per the plan's shared decision, and this one survived that sweep.
- **The Storage and Pub/Sub info cards still carry a hardcoded `ok` / `off` badge.** Not one of the three constants TI04 names, and not covered by any Verify, but they are per-service status claims the app never probes — the same class of assertion OC01 objects to. Left for the story that owns wiring real service probes.
- **`infoCardTemplate` renders its badge in a `.card-footer` below the rows**, which leaves a lone pill floating under two lines of content on the health service cards. Canon anatomy (S16/S08's), not this story's to re-shape.

### Run: 2026-07-30 04:07 UTC – observations

#### QUICK-REVIEW REMEDIATION (8 findings fixed, 4 recorded as Note)

Fixed:

- **HIGH — the audit poll URL interpolated raw query parameters into `hx-get`, allowing htmx attribute injection.** `verdict` and `guard` reach `auditTableFragment` straight off the query string (`web_routes.dart` and `health_page.dart` both pass `params[...]` through unvalidated), and `_auditUrl` concatenated them into an HTML attribute with no encoding. A crafted `/health-dashboard?guard=" hx-delete="/api/sessions/…" hx-trigger="load" x="` link rendered a working `hx-delete` into the operator's authenticated page, and because the injected `hx-trigger` lands earlier in the tag than the fragment's own, the parser keeps the attacker's. CSP blocks script execution, but htmx attribute injection needs none — the request fires same-origin with the operator's session on load. Both values are now `Uri.encodeQueryComponent`-encoded and the assembled URL `_esc`-aped. Pre-existing in substance, but inside the function this story rewrote and re-emitted at five more call sites. Pinned by a test that asserts no attribute syntax survives, that the container keeps exactly one `hx-trigger`, and that the `hx-get` value contains no raw quote or space.
- **A collapsed audit row re-opened itself within 30 seconds.** `restoreAuditExpansion` runs on every `htmx:afterSwap`, but `expandedAuditKey` was only ever written by the audit's own `beforeSwap` — never cleared when the reader collapsed a row. The `#health-live` status refresh this story introduced fires `afterSwap` on the same page every 30s, so a deliberately-closed row popped back open on the next tick, repeatedly. `toggleAuditRow` now clears the key on collapse. This directly contradicted OC04 and was introduced by this story.
- **Two audit entries identical in all eight rendered fields emitted duplicate element ids.** The presentation key is injective over the *tuple*, which is what TI14 and its tests require, but the id and `aria-controls` need *row* uniqueness — a strictly stronger property. `AuditLogReader` does not de-duplicate and `AuditEntry` carries no id, so a page can legitimately hold twins; `getElementById` returns the first, so the second row's chevron opened the first row's detail. The element id now carries the row's position (`audit-detail-<key>-<index>`) while `data-audit-key` stays the restore identity. New test renders the same entry twice and asserts distinct ids with each toggle pointing at its own row.
- **The "an unrelated swap must not disturb the audit" test could not fail.** It only exercised the already-expanded case, which `restoreAuditExpansion`'s `!== 'true'` guard makes a no-op whatever the key holds — so it certified the collapse defect above as green. It now collapses first, then dispatches the unrelated swap and a poll. Mutation-checked: reverting the one-line controller fix makes it fail.
- **The "each measured fact appears exactly once" assertion keyed on the bare substring `>5<`.** It was unique only by fixture coincidence — a `5` anywhere else (a version string, a `5 KB` size) would have flipped it either way. Now uses distinct fixture values and counts each fact *inside its own tile* by matching the value/label pair, so it cannot pass by matching another fact's digits.
- **Two orphans inside regions this story rewrote.** `toggleAuditRow` wrote an `expanded` class to the `<tr>` that no stylesheet consumes (`rg '\.expanded'` matches only `.sidebar-archive-section.expanded`) — removed, since it reads as a load-bearing styling hook to the next reader. `.hook-type` in the AUDIT TABLE block was emitted by no template before or after the rewrite — deleted.
- **Em dashes in this story's new comments**, against the project's en-dash rule. 18 replaced across the change set; pre-existing em dashes in other stories' comments left alone, and the rendered `Showing 1–25` en dash was already correct.
- **The `.empty-state .icon` hoist named S02, a story that has already completed.** Canon closed after P1, so a hoist to S02 has no owner left in the sequence. Re-routed below.

#### HOIST REQUEST — RE-ROUTED (supersedes the S02 routing recorded above in this same run)

- **`.empty-state .icon` renders a solid accent square; the owner is the release-boundary reconciliation (S14), not S02.** The defect and its measurement stand exactly as recorded above — canon's base `.icon` is mask machinery whose `background-color: currentColor` is never neutralised by canon's text-styled `.empty-state .icon`. What was wrong is the routing: S02 is a completed P1 story, so naming it leaves the fix ownerless. **Additional fact the first record missed:** before this story the audit's empty case was a bare inline-styled `<div class="empty-state" style="padding:…">No guard events recorded yet</div>` with **no icon at all**, so adopting S16's shared fragment (correct per TI07) is what puts the visible green block on this surface. Adoption is still right and the app-side workaround is still barred, but this is a *visible regression on a swept surface*, not a latent canon defect — it needs a canon write before release, from whichever story still holds one. Flagged to the orchestrator, not just recorded here.

#### NOTICED BUT NOT TOUCHING (from the review; each needs a decision this story cannot make alone)

- **The memory poll boundary now splits five facts across it.** Moving Memory Files outside `#memory-inner` left the errors.md / learnings.md / MEMORY.md / Archive tab-meta strips rendering `errorsCount`, `learningsCount`, `entryCount`, `memorySizeStr` and `archivedCount` from the same context as the Overview tiles — but only the Overview copies refresh. After any poll tick, and immediately after a prune (whose own `htmx.ajax` refresh is also scoped to `#memory-inner`), the two report different numbers for the same fact. Fixing it means either refreshing the tab-meta strips while keeping the preview panes static, or dropping the duplicated counts from the tab metas — a content decision about which numbers live where. Introduced by this story's TI14 scoping; the alternative TI14 sanctions (capture and reapply tab, preview and scroll after every swap) would avoid it at the cost of controller state this story chose not to add.
- **A 30s tick landing inside the pruner's 4-second confirm window destroys the armed button.** The Pruner card stayed inside `#memory-inner`, so the swap replaces the armed button with a fresh `Prune Now` carrying no `data-confirming`; the reader's confirm click re-arms instead of executing. The failure direction is safe — a swapped-in button can never carry a confirm state, so a poll can never cause an unintended prune — but roughly one arm in eight needs an extra click, and the `Done!` state is written to a node the following `htmx.ajax` immediately detaches, so it is never seen. TI14 explicitly bars the poll-suppression fix ("no `htmx:beforeRequest` cancellation, pause attribute, conditional trigger"), which leaves moving the Pruner card outside the poll and accepting a stale "Next run" — a trade this story should not make unilaterally.
- **Every audit row now gets a disclosure, including rows that disclose nothing.** The rewrite dropped the old `hasDetail` gate, so a `pass`-verdict row with no reason, session, channel or peer opens a panel showing only Hook — which the Detail column already prints for exactly those rows — plus three `.value-absent` dashes. Restoring the gate is easy; keeping the first column aligned when only some rows carry a button is the part that needs a design call (a spacer, or accepting a ragged column).
- **The empty state says "No guard events recorded yet" even when a filter excluded every row.** `verdictFilter` and `guardFilter` are in scope at the call and unused, so an operator filtering by Block on a healthy system is told no guard events exist at all. Equally wrong before this story, but S09 owns this empty state now; the fix is new user-facing copy.

### Run: 2026-07-30 04:28 UTC – observations

#### ORCHESTRATOR RULINGS APPLIED (supersedes the four Note items and the hoist routing recorded earlier in this FIS)

- **HOIST ROUTING CORRECTED AND CLOSED — final owner was S03; the fix has landed and is verified on this story's surface.** Both earlier records in this FIS are wrong on ownership: the 03:30 block routed the `.empty-state .icon` accent-square defect to S02, and the 04:07 block re-routed it to S14 on the premise that a completed P1 story cannot take a hoist. That premise is false — completed P1 workers are resumable for hoists — and the orchestrator dispatched it to **S03** as the empty-state family owner. The defect description and the live measurement that produced it (`background-color: rgb(166, 227, 161)`, `mask-image: none`, 24×24) stand as recorded, as does the finding that this story's adoption of S16's shared fragment is what put the square on the audit surface.

  **S03's fix, re-verified on the guard audit's empty state** at `/health-dashboard?guard=zzz-no-such-guard` on a fresh instance (port 3339; 3338's VM predates this story's fragment adoption, so it cannot show this): canon now carries `.empty-state .icon:not([class*="icon-"])`, which drops the fill and the 1em box for a bare `.icon` while leaving genuine masked icons untouched. Measured after: `background-color: rgba(0, 0, 0, 0)` (was a solid accent fill), `mask-image: none`, glyph box 29×38 at its natural size rather than clamped to 24×24, and `getClientRects().length === 1` — so the two-character `❯_` mark renders on one line instead of wrapping its second character underneath. The `❯_` prompt now reads as accent-coloured text above the title and body. Confirmed the served copy carries the rule over HTTP, not just the source tree.

  Canon accounting for this story is unaffected: the delta between the S09 story-entry snapshot and the tree is now exactly S03's one rule plus the two re-synced provenance headers. `tokens.css` is byte-identical; nothing in the delta originates here.

- **Memory poll boundary — resolved by consistency (ruling 2, first option rejected as not mechanically simple).** Refreshing the tab-meta strips while holding the previews static would need either four separately-polled regions (one per tab panel) or `hx-swap-oob` markers that make the same template render differently for the poll than for a full page load. Neither is mechanically simple and the second reintroduces exactly the controller-state complexity TI14 avoided, so the second option was taken: **every duplicated count is deleted from the tab metas.** The `Entries` item is gone from all four tabs (each restated an Overview tile — Active Entries, Archived Entries, Errors, Learnings) and `Size` is gone from the MEMORY.md tab (it restated the Memory Size tile's bytes). What remains in the card is unique to it: per-file sizes for errors.md / learnings.md / Archive, and MEMORY.md's Oldest / Newest range. Dead context keys `memoryMdEntries`, `memoryMdSize` and `archiveMdEntries` removed with them. Verified live: tab metas now read `[Oldest, Newest]`, `[Size]`, `[Size]`, `[Size]` against Overview tiles `[Memory Size, Active Entries, Archived Entries, Errors, Learnings]` — no fact on both sides of the boundary. Pinned by `memory_dashboard_test.dart#no fact is rendered on both sides of the poll boundary`, which splits the rendered page at the boundary comment and asserts no entry count survives outside it.

- **KNOWN WART for the S14 ledger — the pruner's confirm window can be cut by a poll (ruling 3: accepted, not fixed).** A 30s tick landing inside the 4-second arm window replaces the armed button with a fresh `Prune Now` carrying no `data-confirming`, so the reader's confirm click re-arms instead of executing (~1 arm in 8). Accepted deliberately: the failure direction is safe — a swapped-in button can never carry a confirm state, so a poll can never cause an unintended prune — and both alternatives are worse. TI14 bars the poll-suppression fix outright ("no `htmx:beforeRequest` cancellation, pause attribute, conditional trigger"), and moving the Pruner card outside the poll would freeze its "Next run" and its run history, trading a safe extra click for stale scheduling data. A second face of the same wart: `setPruneState(button, 'Done!', …)` writes to a node the following `htmx.ajax` immediately detaches, so the success state is never seen. **Do not move the card** (standing instruction from this ruling).

- **The audit disclosure is gated again, with the column kept aligned (ruling 4).** `hasDetail` is restored and widened to `reason || sessionId || channel || peerId` — the four fields the panel actually adds, since the Detail column already prints the hook for exactly the rows that have no reason. A gate-less row emits `<span class="audit-row-toggle-spacer" aria-hidden="true">` instead of the chevron, matching canon `.btn-icon-sm`'s 28px so the timestamp column stays one column. Measured live on the 25-row seeded page: 24 rows with a toggle, 1 with a spacer, toggle and spacer both exactly 28px, and **one distinct `<time>` left offset (333px) across all 25 rows** — no ragged edge. 24 detail rows for the 24 disclosable rows, so no empty panel is emitted at all.

- **The empty state distinguishes "nothing matched" from "nothing recorded" (ruling 5).** With a verdict or guard filter active the body reads `No guard events match the current filters`; unfiltered it keeps the copy TI07's Verify pins, `No guard events recorded yet`. Verified live at `/health-dashboard?guard=zzz-no-such-guard`, which also re-exercises the escaping path with a real query parameter. Both branches pinned in `audit_table_test.dart`.

Gates re-run after these changes: 3091 server tests pass (3 pre-existing skips), `dart analyze` clean, format clean, embedded assets regenerated and parity green, canon and the three drift-checked served CSS files still byte-identical to the story-entry snapshot, and `check_design_system_sync.sh` exits 0.
