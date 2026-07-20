# Health & memory dashboards adoption

**Plan**: dev/bundle/docs/specs/0.22/plan.json
**Story-ID**: S07

## Feature Overview and Goal

**Intent**: Bring the two number-heavy operator surfaces — the health and memory dashboards — to canonical Afterglow "good" compliance so they read as first-class parts of one coherent design system instead of bespoke card-like one-offs.

**Expected Outcomes**:

- [OC01] The health status hero renders through the canonical featured-card + status-badge primitives (colored by health state), with no bespoke `.status-hero`/`.status-label` treatment left on the page.
- [OC02] Every KPI on both dashboards composes `.card card-metric`, so it renders at the canonical 32px metric scale with tracking tokens; no bespoke metric re-implementation remains on either page.
- [OC03] The health page uses the canonical `.content-area`/`.content-inner` layout container, and the `.dashboard`/`.dashboard-inner` family (health's only consumer) and its now-orphaned health-only rules are gone from `static/app.css`.
- [OC04] The `--chart-1..6` ramp is the sole sanctioned hue source for future dashboard viz — no charts, sparklines, or hand-picked data hues are introduced by this story.


## Required Context

### From `prd.md` – "FR5: Per-page component adoption"
<!-- source: prd.md#fr5-per-page-component-adoption -->
<!-- extracted: 7d948b65 -->
> **Description**: Bring every page to "good" compliance by composing canonical primitives: glass (`.card-glass`) for overlays above live content (toasts, dialogs, composer palettes), `kbd` for shortcut hints, identicons for entity identity (sessions, channels, task agent badges — never state), terminal frames for diff/raw/step-output views, and `metric-value`/`display` type for KPIs/headers. Clear the violations inventory: purge inline styles into classes/utilities, delete the `settings.html` `<style>` block, collapse the three parallel layout-container families into the canonical one, fix non-token hovers, and convert `display:none` toggles to the `hidden` attribute.
>
> - Page-by-page compliance table (audit §5) reads "good" for all pages.
> - Glass is used only over live content (never in-flow); identicons encode entity identity only, never state.
> - Each page passes visual validation in both themes (desktop + 768px) before its work is considered done.

### From `prd.md` – "Out of Scope" (charts)
<!-- source: prd.md#out-of-scope -->
<!-- extracted: 7d948b65 -->
> Net-new **charts/sparklines** — only the `--chart-1..6` token wiring lands here so future viz can't hand-pick hues.

### From `prd.md` – "Constraints" (binding)
<!-- source: prd.md#constraints -->
<!-- extracted: 7d948b65 -->
> **Zero-npm / server-first**: plain CSS + Trellis + HTMX + Stimulus + SSE; no build step; no new runtime JS dependencies.
>
> **Design-system compliance + scarcity doctrine**: one claw moment per view; CRT on the login hero only; glass only over live content; one entry motion.
>
> **Mobile parity**: 768px breakpoint, 48px touch targets, 16px minimum input font.
>
> **`window.confirm` stays**: currently sanctioned by DESIGN.md; replacing it is out of scope (needs an upstream DESIGN.md decision-table change first).

### From `plan.json` – "sharedDecisions: CSS layering & sync contract"
<!-- source: plan.json#sharedDecisions -->
<!-- extracted: 7d948b65 -->
> All later stories add/edit app CSS only in `app.css` and never touch synced files; new generic classes go upstream-first to `dev/design-system/` then sync down.

### From `plan.json` – "sharedDecisions: Layout-container family collapse"
<!-- source: plan.json#sharedDecisions -->
<!-- extracted: 7d948b65 -->
> Canonical `.content-area`/`.content-inner` arrives with the S01 sync. Each per-page story migrates its own page off the parallel families (`.page-content`/`.page-inner`, `.dashboard`/`.dashboard-inner`, `.info-content`/`.info-inner`); the app.css rules for a family are deleted by the story that removes its last consumer.

### From `plan.json` – "sharedDecisions: Feedback-primitive ownership"
<!-- source: plan.json#sharedDecisions -->
<!-- extracted: 7d948b65 -->
> S03 owns every meter/claw-loader/skeleton/scan-bar swap app-wide. Per-page stories S04–S07 and S09 compose the primitives S03 landed and must not re-implement or re-swap loading/progress UI.


## Deeper Context

- `audit-design-system-compliance.md#2-new-component-adoption-map` – the `display`/`metric-value` type row (health metric cards + memory KPIs → 32px `metric-value`) and the `--chart-1..6` ramp row (health `metrics-grid` + memory overview are the first future consumers). **Line numbers are stale; locate by selector/content.**
- `audit-design-system-compliance.md#3-violations-inventory` – "Structure/containers": the `.status-hero`/heartbeat one-offs that re-implement `card-featured-*`/badges, and the three parallel layout-container families.
- `audit-design-system-compliance.md#5-quick-reference--page-by-page-compliance` – Health row (status-hero → card-featured, metric scale, chart-ramp) and Memory row (metric-value scale; meters/skeleton are S03).
- `dev/design-system/components.css` – canonical `.card-featured-{accent,warning,error}`, `.card-metric .metric-value` (32px `--text-3xl` + `--tracking-tight`), `.status-badge`/`.status-badge-{success,warning,error}`, `.content-area`/`.content-inner` (all delivered by the S01 sync into `static/design-system.css`).
- `dev/bundle/docs/specs/0.22/s03-feedback-primitives.md` – the meter/skeleton swaps on `memory_dashboard.html` that this story must NOT touch (overlap guard).
- `packages/dartclaw_server/AGENTS.md` – paired `.html`/`.dart` template contract and the `embedded_assets.g.dart` regeneration rule.


## Acceptance Scenarios

- [ ] **S01 [OC01] [TI01] Health status hero renders as a canonical featured card with a canonical status badge**
  - **Given** the health dashboard for a `healthy` server
  - **When** the page renders
  - **Then** the hero is a `.card` carrying `card-featured-accent`, its status label is a `.status-badge` carrying `status-badge-success`, and the rendered markup contains no `status-hero`, `status-hero-healthy`, or `status-label` class

- [ ] **S02 [OC01] [TI01] Degraded and error health states drive the matching featured/badge variants**
  - **Given** the health dashboard for a `degraded` server, then for an unavailable/error server
  - **When** each page renders
  - **Then** `degraded` yields `card-featured-warning` + `status-badge-warning` and the error state yields `card-featured-error` + `status-badge-error` (variant tracks state — a fixed accent/success render fails this)

- [ ] **S03 [OC02] [TI03] KPIs on both dashboards render at the canonical 32px metric scale**
  - **Given** the health dashboard (4 metric cards) and the memory dashboard overview (5 KPI cards)
  - **When** each page renders
  - **Then** every KPI is a `class="card card-metric"` element with `.metric-value`/`.metric-label` children (so the canonical `.card-metric .metric-value` 32px `--text-3xl` scale governs), and neither page carries a bespoke metric class such as `summary-stat`

- [ ] **S04 [OC03] [TI02] The health page uses the canonical layout container and the dashboard family is gone**
  - **Given** the health dashboard
  - **When** the page renders and `static/app.css` is inspected
  - **Then** the `<main>`/inner wrappers use `content-area`/`content-inner`, no `dashboard` or `dashboard-inner` class appears in the rendered markup, and `static/app.css` contains no `.dashboard`, `.dashboard-inner`, `.dashboard .card-header`, `.dashboard .card-title`, `.status-hero`, or `.status-*` (health-hero) rule

- [ ] **S05 [OC04] [TI04] The dashboards introduce no charts and no hand-picked data hues**
  - **Given** the health and memory dashboards after adoption
  - **When** their templates and their `static/app.css` sections are inspected
  - **Then** no chart/sparkline markup and no raw color literal for data display are added, while the canonical `--chart-1..6` ramp remains available (defined once in the synced `static/tokens.css` from S01) as the sanctioned hue source for future viz

- [ ] **S06 [OC02] [TI05] Memory meters and preview loaders are untouched by this story**
  - **Given** the memory dashboard rendered after this story
  - **When** its budget/errors/learnings progress markup and its file-preview loader are compared to the S03 output
  - **Then** they are exactly the S03-owned `.meter`/skeleton markup (this story adds, changes, or deletes no meter, skeleton, spinner, or claw-loader)


## Structural Criteria

- [ ] No `.dashboard`, `.dashboard-inner`, `.dashboard .card-header`, `.dashboard .card-title`, `.status-hero`, `.status-hero-healthy`, `.status-hero-degraded`, `.status-hero-error`, `.status-indicator`, `.status-details`, `.status-label`, or `.status-meta` rule remains in `static/app.css` (proved by TI02).
- [ ] The shared `.page-content`/`.page-inner`, `.metric-card`, and bare `.metric-value`/`.metric-label` rules stay in `static/app.css` — they still have non-dashboard consumers: the bare `.metric-card` wrapper's only consumer is `workflow_detail.html`, while `memory_dashboard.html` renders bare `.metric-value`/`.metric-label` under `.card card-metric`, and `.page-content`/`.page-inner` is shared app-wide (proved by TI02/TI03).
- [ ] Synced `static/design-system.css` and `static/tokens.css` are untouched and the S01 drift check exits zero (proved by TI05).
- [ ] `lib/src/generated/embedded_assets.g.dart` is regenerated and `git diff --exit-code` on it is clean after the template/static edits (proved by TI05).
- [ ] The existing health/memory template-render tests are updated to the canonical markup and pass (proved by TI05).


## Scope & Boundaries

### Work Areas

- `templates/health_dashboard.html` + `health_dashboard.dart` — status hero → `.card card-featured-{accent,warning,error}` + `.status-badge status-badge-{success,warning,error}`; outer/inner wrappers → `content-area`/`content-inner`. [TI01,TI02]
- `static/app.css` — delete the health-only `.dashboard*`/`.status-hero*`/`.status-*` rule groups (health is their last/only consumer); add no page-local CSS – compose the canonical primitives the S01 sync landed in `design-system.css`, and if implementation uncovers a genuine canon gap the hero needs, close it upstream in `dev/design-system/` first (never a page-local rule) per DECISIONS.md Still Current "Design-system gap resolution"; leave shared `.page-content`/`.metric-card`/bare `.metric-value` intact. [TI02]
- `templates/memory_dashboard.html` — KPI cards already compose `.card card-metric`; confirm the canonical 32px scale governs and no bespoke metric class remains; meters/skeletons untouched (S03). [TI03,TI05]
- `templates/health_dashboard.html` KPI cards + `components.html` `metricCard` fragment — every KPI composes `.card card-metric` for the canonical metric scale. [TI03]
- `--chart-1..6` forward-compat guard — no chart markup or hand-picked data hue added to either dashboard. [TI04]
- Verification finalization — regenerate `embedded_assets.g.dart`; update the health/memory template-render tests. [TI05]

### What We're NOT Doing

- Memory budget/errors/learnings meters, and the memory file-preview skeleton — owned by S03; this story never touches loading/progress UI.
- Migrating `memory_dashboard.html` off `.page-content`/`.page-inner` — the plan scope and orchestrator name only the `.dashboard`/`.dashboard-inner` family for S07; `.page-content` is shared by ~11 templates (incl. out-of-scope knowledge UI) and survives 0.22 regardless, and its `.page-inner` flex-gap spacing would need re-homing. Deferred; flagged for the plan cross-cutting review.
- Adding a 24px `.display`-type element to the dashboards — `display` type lands on empty-state titles / the login wordmark (S11/S12); the dashboards' adoption is the 32px metric scale only.
- Building any chart/sparkline — PRD out-of-scope; only the `--chart-1..6` token availability (from S01) is confirmed here.
- Realigning the shared `.card-badge`/`badge-*` card-header badge primitive to `.status-badge` — it is used app-wide (task/workflow/service cards) and is not a health/memory one-off; only the health status-hero's bespoke status treatment is realigned here.


## Architecture Decision

**Approach**: Compose the canonical primitives S01 synced into `static/design-system.css` (`card-featured-*`, `card-metric`/`metric-value`, `status-badge-*`, `content-area`/`content-inner`) directly in the health/memory templates and their Dart builders, then delete the now-orphaned health-only `.dashboard*`/`.status-hero*` rules from `static/app.css`. Markup + builder-class retargeting only — no new CSS or JS.
**Why this over alternatives**: Health and memory are already high-compliance (audit §5: Health "Good", Memory "Partial" mostly for S03-owned meters); the remaining gap is bespoke container/hero/badge treatments that canonical primitives already cover, so re-homing markup to those primitives (not re-implementing them app-side) keeps canon the single source of truth.


## Code Patterns & External References

```
# type | path#anchor or url                                              | why needed (intent)
file   | dev/design-system/components.css#.card-featured-accent          | card-featured-{accent,warning,error} left-accent featured card — the status-hero replacement container
file   | dev/design-system/components.css#.status-badge                  | .status-badge + status-badge-{success,warning,error} pill — the canonical status label
file   | dev/design-system/components.css#.content-area                  | .content-area/.content-inner canonical layout container replacing .dashboard/.dashboard-inner
file   | packages/dartclaw_server/lib/src/templates/components.html#metricCard | metricCard fragment (.card card-metric) — KPI card shape; canonical .card-metric .metric-value is 32px --text-3xl
file   | packages/dartclaw_server/lib/src/templates/health_dashboard.dart#L33 | statusColorClass switch (healthy/degraded/error) — retarget to featured-card + status-badge variants
```


## Constraints & Gotchas

- **Edit `static/app.css` only; never the synced files.** The canonical primitives arrive via the S01 `design-system.css`/`tokens.css` sync; adding CSS to a synced file breaks the drift check. New generic classes would go upstream-first — but this story needs none.
- **Regenerate embedded assets.** Any template or `static/` edit requires `dart run dev/tools/embed_assets.dart`; `embedded_assets.g.dart` is checked-in generated output and CI fails on a stale diff.
- **`.metric-card` and bare `.metric-value`/`.metric-label` are shared.** `workflow_detail.html` (S06) consumes bare `.metric-card`/`.metric-value`; deleting them here breaks that page. Only the `.dashboard`-scoped and `.status-*` health-only rules are removed.
- **Canonical has no `card-featured-success`.** Map `healthy` → `card-featured-accent` for the container while the status badge carries the green via `status-badge-success`; `degraded` → `warning`, error → `error` map directly.


## Implementation Plan

### Implementation Tasks

- [ ] **TI01** Health status hero is a canonical featured card whose status label is a canonical status badge
  - In `health_dashboard.html` + `health_dashboard.dart`, the hero block is `.card` + `card-featured-{accent|warning|error}` (from status); the status label is a `.status-badge` + `status-badge-{success|warning|error}` that carries the matching `.status-dot` variant (`.status-dot--live` for healthy, `.status-dot--warning` for degraded, `.status-dot--error` for error). The bespoke 28px state-icon is removed entirely: drop the `.status-indicator` wrapper and the `statusIcon` span from the markup/builder, add no replacement icon treatment, and let state read through the tinted `card-featured-{color}` surface plus the badge and its dot. Keep the uptime/version/worker meta list. Map `healthy`→`card-featured-accent`/`status-badge-success`/`status-dot--live`, `degraded`→`card-featured-warning`/`status-badge-warning`/`status-dot--warning`, else→`card-featured-error`/`status-badge-error`/`status-dot--error`.
  - **Verify**: `Test: rendered health_dashboard for healthy shows card-featured-accent + a status-badge/status-badge-success carrying status-dot--live; degraded shows card-featured-warning + status-badge-warning + status-dot--warning; error shows card-featured-error + status-badge-error + status-dot--error; the uptime/version/worker meta list still renders; and no status-hero, status-indicator, status-label, or 28px state-icon markup remains`
  - **Visual gate**: evaluate the reworked hero for UI/UX regression in both themes at desktop + 768px across all three states – it must read as first-class, not degraded; if it reads as degraded, the sanctioned fallback is an upstream canon fix in `dev/design-system/` (never a page-local rule), per the `status-hero-treatment` decision note and DECISIONS.md Still Current "Design-system gap resolution".

- [ ] **TI02** The health page uses the canonical layout container and the dashboard-family CSS is gone
  - Retarget the health `<main>`/inner wrappers (incl. the `hx-select` target) from `dashboard`/`dashboard-inner` to `content-area`/`content-inner`; delete `.dashboard`, `.dashboard-inner`, `.dashboard .card-header`, `.dashboard .card-title`, `.status-hero`, `.status-hero-*`, `.status-indicator`, `.status-details`, `.status-label`, `.status-meta` from `static/app.css` (health is their only consumer). Deleting `.dashboard .card-title` intentionally drops health's bespoke uppercase-eyebrow card titles: there is no base `.card-title` rule (only `.dashboard`- and `.settings-card`-scoped ones), and canon defines none, so health card titles become plain spans — matching `memory_dashboard.html`'s already-unstyled `.card-title` and aligning with the design system. Validate this visually; do not re-home the eyebrow style. Likewise, deleting `.dashboard .card-header` drops its `justify-content: space-between`, so the Services cards' status badges sit inline right after the card title rather than pushed to the row's end (base `.card-header` carries no `space-between`) – accepted: this matches how `memory_dashboard.html`'s canonical `.card-header` cards already render today; validate visually. Leave `.page-content`/`.metric-card`/bare `.metric-value` (other consumers).
  - **Verify**: `Test: rendered health_dashboard uses content-area/content-inner and no dashboard/dashboard-inner class; grep -cE '\.(dashboard|status-hero|status-indicator|status-details|status-label|status-meta)' static/app.css is 0; each of .page-content, .page-inner, .metric-card, .metric-value, .metric-label still returns a match via grep -q static/app.css`

- [ ] **TI03** Every KPI on both dashboards composes `.card card-metric` at the canonical metric scale
  - Confirm all 4 health metric cards (via the `metricCard` fragment) and all 5 memory overview KPI cards render `class="card card-metric"` (so canonical `.card-metric .metric-value` at `--text-3xl`/32px + `--tracking-tight` governs); convert any KPI not already on `card-metric`. No bespoke metric class (`summary-stat`, `.metric-card`) is used for a dashboard KPI.
  - **Verify**: `Test: rendered health_dashboard + memory_dashboard KPI cards each carry class="card card-metric" with metric-value/metric-label children; neither page contains summary-stat; visual profile confirms metric-value renders at 32px with tight tracking in both themes, backed by dev/design-system/components.css's .card-metric .metric-value { font-size: var(--text-3xl); letter-spacing: var(--tracking-tight) }`

- [ ] **TI04** The `--chart-1..6` ramp is the dashboards' only sanctioned viz hue source, with no charts added
  - Add no chart/sparkline markup and no raw data-color literal to either dashboard or their `static/app.css` sections; the canonical `--chart-1`…`--chart-6` tokens remain available from the synced `static/tokens.css` (S01) for future viz.
  - **Verify**: `Test: git diff of health_dashboard/memory_dashboard templates + static/app.css adds no <svg>/<canvas>/chart markup and no raw hex/rgb() data hue; grep static/tokens.css finds --chart-1 through --chart-6`

- [ ] **TI05** Embedded assets and template tests reflect the canonical markup
  - Run `dart run dev/tools/embed_assets.dart` after the template/static edits; update the health/memory template-render tests to assert the canonical `card-featured-*`/`status-badge-*`/`content-area` markup (and keep the S03-owned meter/skeleton assertions unchanged).
  - **Verify**: `Test: git diff --exit-code on lib/src/generated/embedded_assets.g.dart is clean after regen; the health + memory template-render tests pass; the S01 drift check invoked via dev/tools/fitness/run_all.sh exits 0 and git diff --exit-code -- static/design-system.css static/tokens.css is clean (this story's changeset touches neither synced file)`

### Testing Strategy
> Level allocation is standard except the 32px metric scale, which is CSS-computed.

- Template-render (Layer 2/3) assertions cover the status-hero variants, the container-family swap, and KPI `card-metric` markup — extend the existing `test/templates/` health/memory suites.
- The 32px `metric-value` computed size and both-theme rendering are visual-profile checks (no Dart render surface for computed CSS), per the US04 visual gate.

### Validation

- Visual validation in both themes at desktop + 768px for the health status-hero states (healthy/degraded/error) and the KPI rows on both dashboards (US04 gate).


## Final Validation Checklist

- [ ] App-wide grep is clean of the retired health-only selectors in `static/app.css`: `.dashboard`, `.dashboard-inner`, `.status-hero`, `.status-label`, `.status-indicator`, `.status-details`, `.status-meta`.


## Implementation Observations

#### DECISION NOTE: status-hero-treatment

**Decision-Key:** status-hero-treatment
**Altitude:** story
**Affected surface:** Health status hero – `templates/health_dashboard.html` + `health_dashboard.dart`, and the `.status-hero`/`.status-indicator` rules plus the 28px SVG state icon in `static/app.css` (OC01; scenarios S01/S02; tasks TI01/TI02).
**Decision:** The health status hero converts to fully canonical composition: `.card card-featured-{accent|warning|error}` surface + a `.status-badge` carrying the matching `.status-dot` variant; the bespoke 28px SVG state icon and the `.status-hero`/`.status-indicator` rules are dropped with no replacement icon treatment.
**Rationale:** The story's visual gate explicitly evaluates the reworked hero for UI/UX regression in both themes – if it reads as degraded, the sanctioned fallback is an upstream canon fix (per DECISIONS.md Still Current "Design-system gap resolution"), never a page-local rule.
**Evidence:** Ratified by owner during 0.22 preflight, 2026-07-20.
