# Scheduling, Projects & Session-Info Adoption

**Plan**: dev/bundle/docs/specs/0.22/plan.json
**Story-ID**: S10

## Feature Overview and Goal

**Intent**: Bring the scheduling, projects, and session-info pages to canonical Afterglow compliance so operators see one coherent visual language instead of bespoke heartbeat/token one-offs and template hygiene violations.

**Expected Outcomes**:

- [OC01] Scheduling, projects, and session-info pages carry no S10-scope violations: no inline `display:none` toggles, no inline `style` margins/typography, no bespoke `heartbeat-stat` readouts (the two `.heartbeat-stat` blocks convert to `card-metric`; the heartbeat header/badge/toggle wrapper is retained, not replaced), no parallel `.info-*` container family.
- [OC02] Heartbeat readouts and session token usage render as canonical primitives — `card-metric` (`metric-value`/`metric-label`) and `status-badge` — instead of the bespoke `heartbeat-*` / `token-stat-*` one-offs.
- [OC03] `session_info.html` renders inside the canonical `.content-area`/`.content-inner` container, and the now-orphaned `.info-content`/`.info-inner` app.css rules are deleted (session-info was their last consumer).
- [OC04] Existing behavior is preserved: form show/hide, job/task CRUD, and the sanctioned `window.confirm` destructive-delete flow all work; every page passes visual validation in both themes at desktop + 768px.


## Required Context

### From `plan.json` – sharedDecisions "CSS layering & sync contract"
<!-- source: dev/bundle/docs/specs/0.22/plan.json#sharedDecisions -->
<!-- extracted: 7d948b65 -->
> S01 establishes static/design-system.css (verbatim canonical components.css, provenance header), static/app.css (app-only rules, loaded after), static/app-tokens.css (surviving app tokens), and the drift check. All later stories add/edit app CSS only in app.css and never touch synced files; new generic classes go upstream-first to dev/design-system/ then sync down.

### From `plan.json` – sharedDecisions "Layout-container family collapse"
<!-- source: dev/bundle/docs/specs/0.22/plan.json#sharedDecisions -->
<!-- extracted: 7d948b65 -->
> Canonical .content-area/.content-inner arrives with the S01 sync. Each per-page story migrates its own page off the parallel families (.page-content/.page-inner, .dashboard/.dashboard-inner, .info-content/.info-inner); the app.css rules for a family are deleted by the story that removes its last consumer.

### From `prd.md` – "FR5: Per-page component adoption"
<!-- source: dev/bundle/docs/specs/0.22/prd.md#fr5-per-page-component-adoption -->
<!-- extracted: 7d948b65 -->
> Bring every page to "good" compliance by composing canonical primitives: … `metric-value`/`display` type for KPIs/headers. Clear the violations inventory: purge inline styles into classes/utilities, … collapse the three parallel layout-container families into the canonical one, … and convert `display:none` toggles to the `hidden` attribute.

### From `plan.json` – bindingConstraints NFR-constraints (`window.confirm` stays)
<!-- source: dev/bundle/docs/specs/0.22/prd.md#constraints -->
<!-- extracted: 7d948b65 -->
> **`window.confirm` stays**: currently sanctioned by DESIGN.md; replacing it is out of scope (needs an upstream DESIGN.md decision-table change first).

### From `plan.json` – bindingConstraints NFR-constraints (zero-npm / server-first)
<!-- source: dev/bundle/docs/specs/0.22/prd.md#constraints -->
<!-- extracted: 7d948b65 -->
> **Zero-npm / server-first**: plain CSS + Trellis + HTMX + Stimulus + SSE; no build step; no new runtime JS dependencies.

### From `plan.json` – bindingConstraints NFR-constraints (mobile parity)
<!-- source: dev/bundle/docs/specs/0.22/prd.md#constraints -->
<!-- extracted: 7d948b65 -->
> **Mobile parity**: 768px breakpoint, 48px touch targets, 16px minimum input font.

### From `plan.json` – bindingConstraints NFR-constraints (scarcity doctrine)
<!-- source: dev/bundle/docs/specs/0.22/prd.md#constraints -->
<!-- extracted: 7d948b65 -->
> **Design-system compliance + scarcity doctrine**: one claw moment per view; CRT on the login hero only; glass only over live content; one entry motion.


## Deeper Context

- `dev/bundle/docs/specs/0.22/audit-design-system-compliance.md#5-quick-reference--page-by-page-compliance` – per-page "top 3 fixes" for Scheduling (Poor), Sessions (Partial), Projects (Good).
- `dev/bundle/docs/specs/0.22/audit-design-system-compliance.md#3-violations-inventory` – template-hygiene + structure/container findings (heartbeat one-off, inline styles, three layout-container families).
- `dev/bundle/docs/specs/0.22/prd.md#fr1-synced-drift-checked-design-system-css` – drift-check contract S10 must keep green by editing `app.css` only.


## Acceptance Scenarios

- [ ] **SC01 [OC01,OC04] [TI01] Scheduling forms toggle without inline display styles**
  - **Given** the scheduling page rendered with the job form initially hidden
  - **When** the operator clicks "+ Add Job", then "Cancel"
  - **Then** `#job-form` becomes visible then hidden via the `hidden` attribute (no `style="display:none"` in the template and the form show/hide functions no longer mutate `style.display`), and the same holds for `#task-form`

- [ ] **SC02 [OC02] [TI03] Heartbeat renders as canonical primitives**
  - **Given** heartbeat enabled on the scheduling page
  - **When** the page renders
  - **Then** the Interval and Status readouts use `card-metric` with `metric-value`/`metric-label`, the status pill is a canonical `.status-badge` (`.status-badge-success` when active), and no `.heartbeat-status-badge` class appears in markup or app.css

- [ ] **SC03 [OC02,OC03] [TI05,TI06] Session info uses canonical container and metric type**
  - **Given** a session with recorded token usage
  - **When** the session-info page renders
  - **Then** the page root uses `.content-area`/`.content-inner` (no `.info-content`/`.info-inner`), the Input/Output/Total token values render with canonical `metric-value` type, and `.info-content`/`.info-inner` rules no longer exist in app.css

- [ ] **SC04 [OC04] [TI01] Sanctioned destructive confirm preserved**
  - **Given** a user-defined scheduled task
  - **When** the operator clicks Delete
  - **Then** a `window.confirm` prompt (sanctioned by DESIGN.md) fires before the delete request is issued (the scheduling page's only `window.confirm` delete is `dc_scheduling_controller.js#deleteScheduledTask`; scheduled jobs use the inline `.delete-confirm-row` flow)

- [ ] **SC05 [OC01,OC04] [TI02,TI04,TI07] Pages are hygiene-clean and pass the visual gate**
  - **Given** `scheduling.html`, `projects.html`, and `session_info.html` after adoption
  - **When** each page is rendered and screenshotted in dark + light at desktop and 768px
  - **Then** no inline `style` attribute remains in any of the three templates, form/stat clusters read as canonical wells, and every page passes visual validation in both themes at both widths


## Structural Criteria

- [ ] No `style="display:none"` (or other inline `style`) attribute remains in `scheduling.html`, `projects.html`, or `session_info.html`; toggled elements use the `hidden` attribute.
- [ ] `.info-content` and `.info-inner` rules are removed from app.css and no template references them (session-info was the last consumer).
- [ ] The orphaned `.heartbeat-status-badge` rules are removed from app.css (dead after the badge moved to `statusBadgeTemplate`).
- [ ] Synced `design-system.css` / `tokens.css` are untouched; the drift check stays green.
- [ ] No new npm/CDN or runtime-JS dependency is introduced; `embedded_assets.g.dart` is regenerated after template/static edits.


## Scope & Boundaries

### Work Areas
- `packages/dartclaw_server/lib/src/templates/scheduling.html` – form `hidden` toggles, inline-style removal, heartbeat-card → canonical primitives, form clusters → wells.
- `packages/dartclaw_server/lib/src/templates/session_info.html` – token stats → metric type, stat groupings → wells, `.info-*` → `.content-*` container.
- `packages/dartclaw_server/lib/src/templates/projects.html` – hygiene verification + visual gate only (its concrete fixes are owned by S02/S05/S12).
- `packages/dartclaw_server/lib/src/static/controllers/dc_scheduling_controller.js` – form show/hide toggles the `hidden` property instead of `style.display`.
- `packages/dartclaw_server/lib/src/static/app.css` – new classes for former inline styles; delete orphaned `.info-content`/`.info-inner` and `.heartbeat-status-badge` rules.
- `packages/dartclaw_server/lib/src/generated/embedded_assets.g.dart` – regenerated after edits (`dart run dev/tools/embed_assets.dart`).

### What We're NOT Doing
- Projects empty-state claw-mark (📂 `projects.html:53`) — owned by **S12** (brand moments).
- Project/task dialog glass treatment + `::backdrop` token mix — owned by **S05** (task/project dialogs live in Dart page builders).
- Migrating `scheduling.html`/`projects.html` off `.page-content`/`.page-inner` — that family stays: it has many out-of-S10 consumers (tasks, workflows, settings, memory) plus the out-of-scope knowledge UI, so its collapse cannot complete this milestone; only session-info's exclusive `.info-*` family fully collapses here. *(Flagged for the plan orchestrator's cross-cutting review against the "Layout-container family collapse" shared decision.)*
- Meters / claw-loader / skeletons on these pages — owned by **S03** (feedback primitives).
- Replacing `window.confirm` on these pages — sanctioned by DESIGN.md; out of scope per the binding constraint.


## Architecture Decision

**Approach**: Pure adoption story — swap bespoke `heartbeat-*`/`token-stat-*` markup for the existing `statusBadgeTemplate`/`metricCardTemplate` canonical primitives, convert inline toggles/styles to `hidden` + utility classes, and migrate session-info's exclusive container family to canonical `.content-area`/`.content-inner`; all CSS edits land in `static/app.css` per the CSS-layering shared decision.


## Code Patterns & External References

```
# type | path#anchor                                                            | why needed (intent)
file   | packages/dartclaw_server/lib/src/templates/components.html#statusBadge  | Canonical status-badge fragment — the heartbeat header badge (scheduling.html:12, via heartbeatBadgeHtml) already renders through it
file   | packages/dartclaw_server/lib/src/templates/components.html#metricCard   | Canonical card-metric fragment — reuse for heartbeat stats + token usage
file   | packages/dartclaw_server/lib/src/templates/components.dart#metricCardTemplate | Dart helper emitting the metricCard fragment
dsref  | dev/design-system/components.css#.content-area                          | Canonical container (arrives in design-system.css via S01) — migration target for .info-*
dsref  | dev/design-system/components.css#.well-content                          | Canonical well for form-section clusters (job/task forms); stat groupings take the default .well per the DESIGN.md container flowchart
file   | packages/dartclaw_server/lib/src/static/controllers/dc_scheduling_controller.js#toggleJobForm | Show/hide seam to switch from style.display to the hidden property
```


## Constraints & Gotchas

- **Constraint**: `static/app.css` is the only editable CSS surface; `design-system.css` and `tokens.css` are verbatim-synced from canon — editing them breaks the drift check. Add new classes to `app.css` (or upstream-first to `dev/design-system/` then re-sync) — Workaround: keep every S10 CSS change in `app.css`.
- **Critical**: converting `display:none` → `hidden` requires the Stimulus controller to toggle the element's `hidden` property (`el.hidden = !el.hidden`) and read it back, not `el.style.display` — Must handle by: updating `dc_scheduling_controller.js` show/hide functions in the same change as the template, or the forms never open.
- **Avoid**: leaving `embedded_assets.g.dart` stale after editing templates/static files — Instead: run `dart run dev/tools/embed_assets.dart` so embedded builds serve the updated assets.


## Implementation Plan

### Implementation Tasks

- [ ] **TI01** Scheduling job/task forms open and close via the `hidden` attribute
  - Remove `style="display: none;"` from `#job-form` (`scheduling.html:42`) and `#task-form` (`:128`); update the four form show/hide/edit functions (`toggleJobForm`, `toggleTaskForm`, `editJob`, `editScheduledTask`) in `dc_scheduling_controller.js` to toggle the `hidden` property, not `style.display`. Leave the job delete-confirm-row flow (`confirmDeleteJob`/`cancelDeleteJob`) unchanged — it toggles a table-row reveal with no template `style="display:none"`, and is out of this story's scope.
  - **Verify**: `Test: clicking "+ Add Job"/"+ Add Task" then Cancel shows then hides the form; rendered scheduling.html contains no style="display"; the four form functions in dc_scheduling_controller.js contain no style.display`

- [ ] **TI02** Scheduling inline margins/typography live in classes
  - Move the `section-toolbar` inline `margin-top: var(--sp-6)` (`scheduling.html:123`) and the sub-id `opacity/font-size/display:block` inline style (`:189`) into app.css classes/utilities
  - **Verify**: `Test: rendered scheduling.html has no inline style= attribute`

- [ ] **TI03** Heartbeat section composes canonical card-metric + status-badge
  - The Interval/Status `heartbeat-stat` grid blocks (`scheduling.html:26-33`) render as `.card.card-metric` (`metric-value`/`metric-label`, via `metricCardTemplate`), coloured per the `metric-color-convention` decision note: Interval → `card-metric--info`; Status → `card-metric--accent` when Active, `card-metric--warning` when Disabled. The header badge (`:12`, `heartbeatBadgeHtml`) already renders through `statusBadgeTemplate` – leave it; delete the dead `.heartbeat-status-badge` rules from app.css (no template references them)
  - **Wire the Status value**: the Status stat currently binds `${badgeText}` (`scheduling.html:32`) – a context key `schedulingTemplate()` never sets, so it renders empty today. As part of the conversion, feed the Status metric card its value from `heartbeatOn` ('Active' when enabled, 'Disabled' otherwise), matching the header badge's existing text logic in `schedulingTemplate()`.
  - **Verify**: `Test: rendered scheduling.html heartbeat section uses class "metric-value"/"metric-label"; the Interval card carries "card-metric--info" and the Status card "card-metric--accent"/"card-metric--warning" per state; the Status metric value renders the correct non-empty text ("Active" when enabled, "Disabled" otherwise); the header badge stays "status-badge"/"status-badge-success" when active; grep for heartbeat-status-badge in templates+app.css returns no match`

- [ ] **TI04** Scheduling form clusters read as canonical wells
  - `.well-content` (canonical, from S01 sync) replaces the OUTER box treatment of `.job-form-card` on the job/task form clusters. That swap orphans the descendant form styling currently scoped under `.job-form-card` (`.form-title`, `.form-grid`, `.form-row`, `.form-row label`, and the text-input/textarea + `:focus` rules) – rescope it in app.css so the form internals keep their typography/layout (e.g. re-parent the rules under `.well-content` or a retained wrapper class; implementer's naming latitude), and remove the now-dead `.job-form-card` rule
  - **Verify**: `Test: rendered scheduling.html form clusters carry class "well-content" (no "job-form-card"); the form internals stay styled – .form-title/.form-grid/.form-row and input :focus rules resolve under the new scope; grep for job-form-card in templates+app.css returns no match; visual validation shows well framing with form typography/spacing intact`

- [ ] **TI05** Session token usage renders with canonical metric type
  - The Input/Output/Total `token-stat` blocks are rebuilt as full canonical metric cards per the `token-stat-metric-shape` decision note: each becomes `.card.card-metric` (via `metricCardTemplate`, 32px `metric-value` + `metric-label`) in a small metric grid, coloured per the `metric-color-convention` decision note – Total → `card-metric--accent` (headline), Input/Output → `card-metric--info`. The Total row's bespoke label-left/value-right flex layout goes away with the family. Delete the whole `.token-stat*` family from app.css, including the `.token-stat.total` space-between variant.
  - The metric grid groups inside a `.well`: per the DESIGN.md container flowchart, stat groupings take the default `.well`, and `.well-content` is reserved for form sections (the job/task forms in TI04).
  - **Verify**: `Test: rendered session_info.html token grid emits "card card-metric" markup (metricCardTemplate) with metric-value/metric-label – Total "card-metric--accent", Input/Output "card-metric--info"; token values render at the 32px metric-value scale in both themes; grep for token-stat in templates+app.css returns no match`

- [ ] **TI06** Session-info uses the canonical container and the parallel family is retired
  - `session_info.html` root migrates from `.info-content`/`.info-inner` to `.content-area`/`.content-inner`; delete the `.info-content` and `.info-inner` rules from app.css (session-info was the last consumer)
  - Vertical spacing between the stacked sections is preserved by the canonical `.content-inner`'s flex-column + `gap: var(--sp-6)` (added upstream via S01's canon work, per the `content-inner-stack-gap` decision note) – add no page-local spacing rule to replace `.info-inner`'s flex/gap; the visual gate confirms rhythm parity
  - Depends on S01 having synced `.content-area`/`.content-inner` (with the flex/gap rule) into `design-system.css`
  - **Verify**: `Test: rendered session_info.html contains content-area/content-inner and no info-content/info-inner; grep for .info-content/.info-inner in app.css returns no match; stacked-section vertical rhythm reads coherent in the visual gate (spacing inherited from the canonical container, not collapsed)`

- [ ] **TI07** All three pages are hygiene-clean and pass the visual gate
  - Confirm `projects.html` carries no S10-scope violation (its 📂 empty-state is S12, dialog glass is S05, print-in is S02); run visual validation for scheduling, projects, session-info in dark + light at desktop + 768px
  - **Verify**: `Test: grep for inline style= across the three templates returns no match; each page passes visual validation in both themes at desktop and 768px`

### Testing Strategy
> Template-rendering assertions (class presence, absence of inline `style`) are Layer 2/3 string checks against rendered output per the package testing conventions; visual layout is covered by the manual visual gate, not Dart tests.


## Final Validation Checklist
- [ ] `grep -rn 'style=' scheduling.html projects.html session_info.html` returns no match (all inline styles removed).


## Implementation Observations

#### DECISION NOTE: token-stat-metric-shape

Decision-Key: token-stat-metric-shape
Altitude: Component composition – session-info token stats adopting canonical metric primitives.
Affected surface: Session-info token stats (Input / Output / Total, TI05); orphaned `.token-stat*` rules in `static/app.css`.
Decision: Session-info token stats adopt metric type via the full canonical composition – Input / Output / Total each become `.card.card-metric` (via `metricCardTemplate`) in a small metric grid like the health/memory dashboards. The Total row's bespoke label-left / value-right flex layout is retired with the `.token-stat` family.
Rationale: Canon defines metric typography only under `.card-metric`, and DESIGN.md's KPI rule mandates the card composition – so metric type cannot be adopted piecemeal without the card wrapper.
Evidence: Canon `.card-metric .metric-value` typography scope; DESIGN.md KPI-card rule (`.card .card-metric--{color}`); health/memory dashboard metric-grid precedent. Ratified by owner during 0.22 preflight (2026-07-20).

#### DECISION NOTE: metric-color-convention

Decision-Key: metric-color-convention
Altitude: App-wide UI convention – metric-card color modifiers across all pages.
Affected surface: Metric cards (`.card-metric--*` modifiers) app-wide; applied in S10 to the scheduling heartbeat stats (Interval / Status, TI03) and the session-info token stats (Input / Output / Total, TI05).
Decision: One app-wide rule – stats that encode a state use the matching semantic modifier; pure-quantity stats follow the health-dashboard precedent (accent for the headline stat, info for the rest). S10 application: scheduling Interval → `card-metric--info`; scheduling Status → `card-metric--accent` when Active, `card-metric--warning` when Disabled; session-info token stats → `card-metric--accent` for Total (headline), `card-metric--info` for Input / Output.
Rationale: Keeps semantic color meaningful (reserved for state-encoding stats) while pure-quantity stats stay visually consistent with the established health-dashboard pattern.
Evidence: Ratified by owner during 0.22 preflight (2026-07-20); the same convention persisted in S08.

#### DECISION NOTE: content-inner-stack-gap

Decision-Key: content-inner-stack-gap
Altitude: App-wide layout-container convention – vertical spacing between stacked children of the canonical `.content-inner`.
Affected surface: Canonical `.content-inner` layout container (synced `design-system.css`); applied in S10 to the session-info page's stacked sections after migrating off `.info-inner` (TI06).
Decision: The canonical `.content-inner` rule gains `display: flex` / `flex-direction: column` + `gap: var(--sp-6)` upstream via S01's canon work; session-info's stacked sections inherit vertical rhythm from the synced rule. No page-local spacing rule replaces `.info-inner`'s flex/gap.
Rationale: Vertical rhythm belongs to the shared container in the synced layer, so per-page stories add no local spacing rules – honouring the S01 CSS layering & sync contract (S10 edits only its templates + `static/app.css`).
Evidence: Ratified by owner during 0.22 preflight (2026-07-20); the gap lands upstream via S01's `.content-inner` canon work.
