# Documentation sync, glitch ledger and release validation

**Plan**: docs/specs/0.22.1/plan.json
**Story-ID**: S14

## Feature Overview and Goal

**Intent**: Every upstream story proved its own slice against a build that no longer exists by the time the next story lands – without one gate that re-proves the five success metrics against what actually ships, and one written record of what was fixed versus knowingly left, 0.22.1 can pass every local check and still release regressed, mis-documented, or with defects that quietly fell off the list.

**Expected Outcomes**:

- [OC01] The design system's documentation describes exactly what ships – every class DESIGN.md names has a rule behind it, every component category the CSS defines has a section describing it, every new primitive and type tier is demonstrable in `showcase.html`, and the § Source-of-truth paragraph no longer sanctions the very drift the check rejects.
- [OC02] Every glitch the audit catalogued leaves the release with a written disposition – closed with evidence, or deferred with a reason – in one durable ledger that lives in the **canonical private repo** and is assembled from the **canonical private FIS**, so a defect can be dropped deliberately but never silently, and no deferral dies with the transient `dev/bundle/` export. The ledger is milestone-scoped: it proves coverage of the audit at release time, and it hands its **survivors** – the `deferred` rows – to the durable backlog, so a deferral outlives 0.22.1's spec directory instead of resting in a closed milestone nobody re-reads.
- [OC03] All five success metrics hold **simultaneously on one build**: 23 surfaces in both themes at two viewports plus the 1024px width FR3 names and the settings tabs six findings need, the UI smoke test, the drift check, and the embedded-asset bundles that every canon re-sync silently invalidated and only this story regenerates.
- [OC04] Operator-facing documentation outside the design system – the wireframe deviations register, `VENDORS.md`, and the user guide – no longer describes behaviour this release replaced.


## Required Context

### From `docs/specs/0.22.1/prd.md` – "FR9: Documentation sync"
<!-- source: docs/specs/0.22.1/prd.md#fr9-documentation-sync -->
<!-- extracted: e18cf85 -->
> **Description**: Update DESIGN.md (typography table, surface ladder, layout tiers, three new component families, rewritten feedback table), `showcase.html` (type tiers, forms, tabs, dialog), `VENDORS.md`, the wireframe `deviations.md`, and any user guide whose screenshots or documented behaviour the change invalidates.
>
> **Acceptance Criteria**:
> - [ ] No documented behaviour in DESIGN.md lacks backing CSS (closes the § Native selects gap).
> - [ ] `deviations.md` records any intentional divergence.

### From `docs/specs/0.22.1/prd.md` – "FR7: Glitch sweep" (acceptance criteria)
<!-- source: docs/specs/0.22.1/prd.md#fr7-glitch-sweep -->
<!-- extracted: e18cf85; FR7 gained the durable-backlog criterion after this extraction (uncommitted) -->
> - [ ] All 23 high-severity glitches closed.
> - [ ] Remaining glitches closed or explicitly deferred with a recorded reason.
> - [ ] Every deferral is carried into a durable backlog – with its reason, and without a target milestone – so a later milestone finds it without reading this release's own closing records. Recording a reason inside a milestone-scoped artifact does not satisfy this: that artifact is closed along with the milestone.
> - [ ] UI smoke test (TC-01…TC-31) green.

### From `docs/specs/0.22.1/prd.md` – "Executive Summary" (Success Metrics)
<!-- source: docs/specs/0.22.1/prd.md#executive-summary -->
<!-- extracted: e18cf85; metric 5 gained the durable-backlog clause after this extraction (uncommitted) -->
> 1. Card-vs-ground contrast ≥ 1.15:1 in **both** themes, with chrome, page ground and cards on three distinct planes; no page band equals the card fill.
> 2. Zero `--text-sm` usages remain; every named DESIGN.md type tier has a backing composite class, demonstrated in `showcase.html`.
> 3. Zero `window.alert` / `confirm` / `prompt` call sites in `lib/src/static/controllers/`; DESIGN.md's feedback decision table bans them explicitly.
> 4. All 23 surfaces re-validated in both themes at desktop + 768px; UI smoke test (TC-01…TC-31) green; drift check green (`design-system.css` byte-identical to canon).
> 5. The 64 distinct glitches from the audit are closed or explicitly deferred with a recorded reason, and every deferral is carried into a durable backlog that outlives this milestone.

### From `docs/specs/0.22.1/plan.json` – executionNotes: the deferral rule
<!-- source: docs/specs/0.22.1/plan.json#executionNotes -->
<!-- extracted: 2026-07-26 (plan.json deferral rule amended, uncommitted) -->
> Deferrals must be written down. Success metric 5 accepts a glitch as closed *or* explicitly deferred with a recorded reason — the two identified so far are the missing chart/sparkline component (S09) and the KG timeline's absent time axis (S10), both new capabilities this release does not take on. Silent omissions fail the metric. A recorded reason is not the end of the trail: S14 TI11 promotes every deferral the ledger carries into the durable backlog, because the ledger is milestone-scoped.

_"The two identified so far" is the plan's wording at plan time, not a complete list. Sweeping the sixteen FIS finds 29 live rows (§ Deferral inventory, D01–D30, one of them since withdrawn) plus one open item; the set moved twice while this FIS was being written and will move again._

### From `docs/specs/0.22.1/plan.json` – executionNotes: DEFERRAL RECORDS NEED A DURABLE HOME
<!-- source: docs/specs/0.22.1/plan.json#executionNotes -->
<!-- extracted: 2026-07-26 (plan.json deferral rule amended, uncommitted) -->
> Success metric 5 accepts a glitch as closed OR explicitly deferred with a recorded reason, and S14's ledger is assembled from per-story deferral records. But implementation runs against the transient `dev/bundle/` export in the public repo, which is deleted before merge — so a deferral written only into the bundle copy of a FIS vanishes and the metric fails silently, which is the exact failure it exists to prevent. Rule: every deferral is written back to the CANONICAL private FIS at `dartclaw-private/docs/specs/0.22.1/fis/`, not only to the bundle copy, and S14 consolidates them into `dartclaw-private/docs/specs/0.22.1/glitch-ledger.md`. Stories that record deferrals in prose (a `What We're NOT Doing` bullet) must also land them in Implementation Observations, because that is the only block S14 reads. The ledger is itself milestone-scoped, so it is a checkpoint and not the final resting place: S14 TI11 promotes each row it marks `deferred` into `dartclaw-private/docs/PRODUCT-BACKLOG.md` (a deferred capability) or `dartclaw-public/dev/state/TECH-DEBT-BACKLOG.md` (a cleanup blocked on requirements or an architecture decision), carrying the reason and citing the ledger row, with no target milestone – recording is not scheduling. A deferral left only in a closed milestone's ledger is as lost as one left in the bundle. Per the private-repo policy nothing here is auto-committed — the operator commits.

_This story does not rely on that write-back having happened. TI06 sweeps **both** blocks of the canonical private FIS, so a story that recorded a deferral only in prose is still caught. See TI06 and § Constraints & Gotchas._

### From `docs/specs/0.22.1/plan.json` – executionNotes: EMBEDDED ASSETS
<!-- source: docs/specs/0.22.1/plan.json#executionNotes -->
<!-- extracted: 2026-07-25 -->
> `embedded_assets.g.dart` is regenerated exactly ONCE, by S14. No other story runs `dart run dev/tools/embed_assets.dart`, and no other story asserts a clean `git diff` on it. Mid-release regeneration is re-drifted by every subsequent story, so it is wasted work that also lands a large generated-file diff into parallel branches.

### From `docs/specs/0.22.1/plan.json` – Shared decision: what canon closure covers
<!-- source: docs/specs/0.22.1/plan.json#sharedDecisions -->
<!-- extracted: 2026-07-25 -->
> ONLY the P1 stories S01-S04 hold that right, and only for the three DRIFT-CHECKED files — `tokens.css`, `components.css` and `icons.css`. […] `DESIGN.md` and `showcase.html` are NOT closed and NOT drift-checked — they are prose and a demo, never synced — so any story that establishes a documented contract writes it there directly, and S14 reconciles the whole document at release close.

### From `docs/specs/0.22.1/plan.json` – executionNotes: the documentation contradiction
<!-- source: docs/specs/0.22.1/plan.json#executionNotes -->
<!-- extracted: 2026-07-25 -->
> One known documentation contradiction to resolve in S14: `DESIGN.md § Source-of-truth scope` states the served files may deliberately extend canon with live-only rules, while `check_design_system_sync.sh` diffs for byte identity and fails on any extension. Treat the script as authoritative and fix the prose unless the check itself is wrong.

### From `docs/specs/0.22.1/plan.json` – Shared decision: "Visual-baseline protocol"
<!-- source: docs/specs/0.22.1/plan.json#sharedDecisions -->
<!-- extracted: 2026-07-25 -->
> The audit's 92-shot set stays the release-level baseline that S14 re-proves once. A story that finds a regression outside its own scope reports it rather than absorbing it.

### From `docs/specs/0.22.1/plan.json` – Shared decision: "Canon-first, and canon closes after P1"
<!-- source: docs/specs/0.22.1/plan.json#sharedDecisions -->
<!-- extracted: 2026-07-25, working-tree plan.json -->
> A story that changes a canon-owned rule edits `dev/design-system/` (tokens.css / components.css / icons.css / DESIGN.md / showcase.html) first, then re-syncs the served copies under `packages/dartclaw_server/lib/src/static/` — regenerating the two-line `/* Synced from … sha256: … */` provenance header — within the same story. `dev/tools/fitness/check_design_system_sync.sh` must be green at every story boundary.

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

### From `docs/specs/0.22.1/prd.md` – Binding constraint: FR5 forbidden call forms
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

_The audit's 92 image files do not exist on disk in either repo – they were produced in an ephemeral audit run and only their **written** evidence survives, inside `audit-ui-polish-2026-07-25.md` (each finding quotes its screenshot, the measured values, and the coordinates). The durable comparator is therefore the audit text plus the story-start captures each story took; this story re-captures the same matrix and validates finding-by-finding, not pixel-by-pixel. See TI08._

### Deferral inventory across the story FIS – spec-time snapshot
<!-- source: docs/specs/0.22.1/fis/*.md (§ What We're NOT Doing, § Implementation Observations, task bodies) -->
<!-- extracted: 2026-07-25, before execution -->

Every deferral the sixteen FIS record **as authored**, swept from the canonical private `fis/` directory. It is a floor, not a ceiling: execution adds more, and TI06's sweep – not this table – is the authority. A row missing from the finished ledger is a defect; a row in the ledger that is not here is expected.

| # | Story | Deferred item | Recorded reason (abbrev.) | Where recorded |
|---|---|---|---|---|
| D01 | S01, S09 | Chart / sparkline / `--chart-*` backing component | canon defines the ramp with no component behind it; adding one is a new capability | S01 NOT-doing; S09 NOT-doing + TI11 |
| D02 | S05 | The ten pre-existing `app.css` shadow names (`banner`, `data-table`, `input-area`, `session-item`, `shell`, `sidebar`, `terminal-frame-body`, `theme-toggle`, `topbar`, `well-content`) | pre-existing overrides no S01–S04 change created; sweeping them breaks traceability | S05 NOT-doing |
| D03 | S16 | Pagination / page-size caps on the unbounded page handlers | bounding a list is a new UX capability and needs handler changes | S16 NOT-doing |
| D04 | S07 | The unstyled template classes no surface story claims, and an orphan-class fitness check | a new check is tooling, not polish | S07 NOT-doing |
| D05 | S08 | `--icon-fallback` question-mark treatment for unmapped icon names | changes canon's base `.icon` / `[data-icon]::before` rules; new capability | S08 NOT-doing |
| D06 | S08 | `.run-card-step` / `.run-card--attention` on agent-pool runner cards | no step counter or blocked state is modelled for a pool runner; adopting them means inventing data | S08 NOT-doing |
| D07 | S08 | The task IA overhaul | deferred to Cross-Surface UX | S08 NOT-doing |
| D08 | S09 | Wiring FTS5 Index / Runtime / Format to real probes | needs a health-service change; barred by no-backend-work | S09 NOT-doing |
| D09 | S10 | Recomputing knowledge layer counts from an unfiltered corpus query | root cause is `knowledge_hub_service.dart#KnowledgeHubService.search`, a service change | S10 NOT-doing |
| D10 | S10 | Markdown stripping / word-boundary snapping in snippets | `WikiSearchSource._snippet` is in `dartclaw_storage`; service change | S10 NOT-doing |
| D11 | S10 | A canonical chronology component **and the KG timeline's missing time axis** | a new canon family (P1 closed) plus a new capability – a redesign, not polish | S10 NOT-doing |
| D12 | S10 | A Start / Connect action for a not-running channel | no such endpoint exists; new UX capability | S10 NOT-doing |
| D13 | S10 | An `a.chip[aria-current]` selected treatment in canon | canon's pressed-chip rule is `button`-qualified and canon is frozen for S10 | S10 NOT-doing |
| D14 | S10 | A `.status-dot--muted` variant | canon ships six dot variants and none is muted; `disabled` routes onto `--idle` instead | S10 NOT-doing |
| D15 | S10 | The unstable "Page 1 of N" label (`limit = perPage * page + perPage` grows `totalPages`) | generation-side defect, deferred with the other service changes | **S10 § Validation only – neither block** |
| D16 | S11 | `allowedValues` for `agent.effort` **and** `agent.provider` on `FieldMeta` (`dartclaw_config/lib/src/config_meta.dart`) | config-metadata change altering the `/api/config` meta payload, plus a product decision on the legal value set | S11 NOT-doing + TI09 |
| D17 | S11 | A default-value surface on `FieldMeta` (same file) | same shape as D16; verified – `FieldMeta` carries `yamlPath`/`jsonKey`/`type`/`mutability`/`nullable`/`min`/`max`/`allowedValues` and no default, so the client cannot read the effective default for `agent.model` / `agent.max_turns` / `agent.effort` | S11 NOT-doing |
| D18 | S11 | Settings IA – regrouping ten flat tabs into 3–4 sections; moving Authentication / System Health / Workspace out of "Server"; pending-pairing counts on the tab strip | three separate new UX capabilities, barred by Out of Scope | S11 NOT-doing |
| D19 | S12 | Composer model / guard indicators (`.composer-model`, guard `.status-badge`) | the surface renders none of that information today; the picker is a 0.24 chat feature | S12 NOT-doing |
| D20 | S12 | Per-message timestamps in the chat thread | `ClassifiedMessage` (`templates/chat.dart:15`) has no time field | S12 NOT-doing |
| D21 | S12 | Re-classing the slash-command palette onto `.palette-section` / `.palette-item` | `plan.json#stories[S12].scope` names "command palette" in its exclusion list and the plan is binding | S12 NOT-doing |
| D22 | S12 | The restart banner's inconsistent width and top offset | hoisting it out of its 14 per-page includes would conflict with every W2 story editing those templates | S12 NOT-doing |
| D23 | S12 | `dc_chat_controller.js#openCommandPalette` left as an unreferenced Stimulus action | deleting a public action here would pre-empt 0.24, which owns the palette | **S12 TI-body only – neither block** |
| D24 | S13 | `dev/design-system/showcase.html` keeps its Google Fonts `<link>` | a disk-opened dev artifact, not a served surface | S13 NOT-doing |
| D25 | S13 | No Cyrillic / Greek / Vietnamese font subsets | they fall back to the system stack; the trade is recorded in `vendoring-analysis.md` | S13 NOT-doing |
| ~~D26~~ | S15 | ~~The two native `<select>` controls in `workflow_list.html` (audit `:1395`, med)~~ | **WITHDRAWN** – S15 now closes audit `:1395`'s custom-select half (S03's `select.form-select` plus S15 TI13's markup swap; S11 reaches the settings half with no markup change). It belongs in § Glitch rows as `closed`, not in carried deferrals. | S15 NOT-doing, revised |
| D27 | S15 | The "Add credential" affordance on the project error banner (audit `:526`/`:535`) | a new UX capability and a cross-surface navigation contract | S15 NOT-doing |
| D28 | S15 | The empty `.run-card` identicon and `.tool-indicator` slots | the list view-model carries no per-run agent identity or activity line | S15 NOT-doing – also a `deviations.md` row |
| D29 | S08 | Retiring the SSE `task_event` payload's `iconChar` field and `task_event_display.dart#compactEventIconChar` | `task_sse_routes.dart` is under `lib/src/api/`, barred by no-backend-work; TI05 moves every consumer off the emoji path and leaves the field on the wire unread, for whichever later story legitimately owns `lib/src/api/` | S08 NOT-doing |
| D30 | S09 | FR6's `.meter` half on the health dashboard – **the criterion is half-deferred, not met** | nothing on the surface is a ratio a determinate meter could read: `healthDashboardTemplate` receives only unbounded counters and `HealthService.getStatus()` emits no cap beside any of them; the two caps that exist are absent from the payload and unset by default, so surfacing one means a health-service change plus a fact the page does not show today | S09 NOT-doing + TI03 |

One further item is **open, not deferred**, and TI06 must resolve it to `closed` or `deferred` rather than let it fall through the gap the cross-cutting review found:

- **Z1** – the app-side `--z-*` migration: the review recorded the z-index glitch as "neither closed nor deferred" and S04's ladder as an orphan output. Remediation gave it to **S07 TI08** (numbered TI18 before the S07/S16 split renumbered S07's tasks; S04's What-We're-NOT-Doing now routes it there too). Confirm S07 TI08 actually closed it – all seven ad-hoc `app.css` literals, including `.restart-overlay`'s 9999 – and record it as a glitch row. If it did not, it is a carried deferral.

_D26 was a deferral when this FIS was written and is now closed; D29 and D30 appeared the same way. That churn is the reason the inventory is a floor and TI06's sweep is the authority: **re-read the FIS as they stand at release close**, do not transcribe this table._


## Deeper Context

- `../dartclaw-public/dev/tools/release_check.sh` – § 5 is the embedded-asset gate this story satisfies; § 9 runs the fitness suite that contains the drift check
- `../dartclaw-public/dev/guidelines/VISUAL-VALIDATION-WORKFLOW.md` – capture conventions; note the desktop width here is 1440×900 to match the audit matrix, not the guideline's 1280px default
- `../dartclaw-public/dev/testing/profiles/visual/README.md` – the only profile rendering all 23 surfaces; start with `bash dev/testing/profiles/visual/run.sh`, port 3338. It does not enumerate the 23 – derive the list from the distinct surface keys in the audit's sections A–C and record it with the capture (TI08)
- `../dartclaw-public/packages/dartclaw_server/lib/src/auth/security_headers.dart#_csp` – where the CSP actually lives; `font-src` is **not** in `layout.html`, so the external-origin criterion needs its own read-only check (TI10)
- `docs/DEVELOPMENT-PROCESS.md#path-b--implement-a-planned-milestone` – step 3: private canonical docs are edited **directly**, not through the one-way bundle; this is what makes `deviations.md` and the ledger writable, and the sixteen story FIS readable, from a public-repo implementation run
- `docs/specs/0.22.1/audit-ui-polish-2026-07-25.md#b-glitches--visibly-broken-no-design-decision-needed-72` – the ledger's input set, grouped by surface
- `../dartclaw-private/docs/specs/0.22.1/fis/` – the fourteen other canonical story FIS; TI06's deferral sweep reads these, **not** their `dev/bundle/` exports
- `../dartclaw-public/dev/tools/fitness/check_design_system_sync.sh` – three `check` calls and nothing else; the authority TI02 rewrites the prose to match


## Acceptance Scenarios

- [ ] **S01 [OC01] [TI01] Every class DESIGN.md names has a rule behind it**
  - **Given** the shipped `dev/design-system/DESIGN.md`, `components.css` and `icons.css`
  - **When** every backticked class name in DESIGN.md is looked up in the two CSS files
  - **Then** the only names without a rule are the two DESIGN.md itself marks app-owned in § Layout (`.page-content`, `.page-inner`); `.chip--file`, unbacked today, is dropped from the prose **and** from the two `showcase.html` demos that apply it (`:638`, `:652`), since no new CSS may be written; and § Native selects – prose-only, so invisible to the class sweep – resolves to the `.form-select` rules S03 shipped or is rewritten to describe what canon defines

- [ ] **S02 [OC01] [TI02] The source-of-truth prose and the check that enforces it agree**
  - **Given** DESIGN.md § Source-of-truth scope (`DESIGN.md:311`), which today reads "The served files may deliberately extend the spec with live-only implementation details … such extensions are not drift", and `check_design_system_sync.sh`, whose three `check` calls cover exactly `tokens.css` → `static/tokens.css`, `components.css` → `static/design-system.css` and `icons.css` → `static/icons.css`
  - **When** a single live-only rule is appended to `packages/dartclaw_server/lib/src/static/design-system.css` and `bash dev/tools/fitness/check_design_system_sync.sh` is run
  - **Then** the check fails with `design-system drift: design-system.css`, and DESIGN.md no longer contains prose sanctioning that extension – the paragraph states byte identity for **exactly those three pairs**, names `DESIGN.md` and `showcase.html` as prose and demo that are never synced and therefore writable by any story, and stops describing `icons.css` as the sole strict-sync exception (its icon-inventory test is an *additional* check, not the only one)

- [ ] **S03 [OC01] [TI03] The showcase demonstrates every tier and primitive the release added**
  - **Given** `dev/design-system/showcase.html` after the release
  - **When** it is opened in a browser in both themes
  - **Then** all seven composite type classes (`.t-caption`, `.t-body`, `.t-label`, `.t-heading`, `.t-page-title`, `.t-display`, `.t-metric`) render as visibly distinct steps, and the form, tab and dialog families each have a live panel – the dialog opening as a real `<dialog>`, not a static mock

- [ ] **S04 [OC02] [TI06] Every catalogued glitch leaves the release with a disposition**
  - **Given** the 72 findings under the audit's section B, and – from **outside** section B – every deferral the sixteen story FIS record, read from the **canonical** private copies at `../dartclaw-private/docs/specs/0.22.1/fis/` and swept from **both** the `## Implementation Observations` block and the `### What We're NOT Doing` block of each, because several stories record a deferral only in prose (the spec-time floor is § Deferral inventory's live rows, D01–D30 less the withdrawn D26, plus the open item Z1)
  - **When** the glitch ledger at `../dartclaw-private/docs/specs/0.22.1/glitch-ledger.md` is read
  - **Then** its **Glitch rows** section covers the 72 section-B findings, deduplicated to distinct defects with the duplicate findings named against their entry, each carrying its audit severity and either `closed` with the story ID and the commit or file that closed it, or `deferred` with a reason; its **Carried deferrals** section holds the out-of-section-B deferrals, counted separately, and carries a per-story roll-call in which each of the fourteen non-S14 stories states either its carried deferrals or "none", so an unswept story is visible rather than silent; the distinct-defect count and the distinct **HIGH** count are stated and reconciled against the PRD's 64 and 23; and no `HIGH` row is `deferred` – FR7's first criterion admits closure only

- [ ] **S05 [OC02] [TI06] A glitch left open without a reason fails the ledger, and a deferral written only into the bundle cannot reach it**
  - **Given** a ledger draft in which one section-B row carries an empty disposition cell and a second carries `deferred` with an empty reason cell, and a bundle copy of one story FIS under `../dartclaw-public/dev/bundle/docs/specs/0.22.1/fis/` carrying a deferral its canonical private twin does not
  - **When** `awk` is run over the ledger table asserting every row's disposition is `closed` or `deferred` and its evidence-or-reason cell is non-empty, and the sweep is re-run
  - **Then** the `awk` pass prints both offending row ids and exits non-zero – a blank reason is rejected the same way a missing entry is, so an omission cannot pass as a deferral – and the bundle-only deferral is **absent** from the ledger, proving the sweep reads the canonical private FIS and not the transient export that is deleted before merge

- [ ] **S06 [OC03] [TI07] S14 is the only story that regenerates the embedded assets, and its run is idempotent**
  - **Given** the release build, on which every upstream story re-synced or edited an embed root (`lib/src/templates`, `lib/src/static`, `packages/dartclaw_workflow/skills` and its workflow definitions) and **none** ran the generator – `plan.json#executionNotes` reserves the single regeneration for S14
  - **When** `dart run dev/tools/embed_assets.dart` is run for the first time in the release and `git diff -- '**/generated/embedded_assets.g.dart'` is inspected, then the diff is committed and `bash dev/tools/release_check.sh` § 5 is run
  - **Then** the first run produces a **non-empty** diff on both tracked files – proving the bundles were stale, which is what makes the idempotency check mean anything; an empty first diff means another story regenerated mid-release against the plan and is a finding, not a pass – and after the commit § 5's own `embed_assets.dart` + `git diff --exit-code` sequence reports `embedded assets current`

- [ ] **S07 [OC03] [TI08,TI09,TI10] The five success metrics hold on one build**
  - **Given** one frozen commit, served by the `visual` profile on port 3338 for the capture and by the `plain` profile on port 3335 for the smoke test – "one build" is one commit, not one server process
  - **When** the capture matrix is taken (23 surfaces × dark/light × 1440×900 and 768×1024, plus the ten settings-tab shots, plus the five data-table surfaces × dark/light at **1024×900**), the UI smoke test is walked on its own documented environment, and the automated gates are run
  - **Then** no surface regresses against the audit's recorded findings, every high-severity glitch the ledger marks closed is absent from the capture, all 31 smoke-test cases pass, `check_design_system_sync.sh` is green, `rg` finds zero forbidden native-dialog call forms under `lib/src/static/controllers/`, zero `--text-sm` usages remain, and measured card-vs-ground contrast is ≥ 1.15:1 in both themes
  - **And** FR3's "no table header wraps mid-word at any viewport ≥ 1024px" is proven **at 1024px width** on all five data-table surfaces – `/tasks`, `/scheduling`, `/health-dashboard/audit`, `/memory` and `/settings` Security – by measuring `scrollWidth <= clientWidth` on every `th` and confirming no table overflows its wrapper. Once canon's `.data-table th { white-space: nowrap }` governs, "renders on one line" is true by construction and proves nothing; **clipping** is the failure mode that survives the rule

- [ ] **S08 [OC04] [TI04,TI05] Operator-facing documentation outside the design system matches what shipped**
  - **Given** `VENDORS.md` documenting four vendored assets and `deviations.md` carrying 18 dated rows, both written before this release
  - **When** an operator reads them plus `docs/guide/` after the release
  - **Then** `VENDORS.md` carries one `## ` section per asset actually vendored under `lib/src/static/`, `deviations.md` carries at least three new dated rows naming the surface re-tone, the in-app confirmation replacing native dialogs and the wide-container tier, and no guide page still describes behaviour this release replaced – "no guide change required", recorded in the ledger's scope notes with the sweep that established it, is a valid outcome

- [ ] **S09 [OC02] [TI11] A deferral outlives the milestone that deferred it**
  - **Given** the finished ledger, carrying at least one row whose `disposition` is `deferred` – at spec time the missing chart/sparkline component (S09) and the KG timeline's absent time axis (S10)
  - **When** a planner who has never read `docs/specs/0.22.1/` opens `PRODUCT-BACKLOG.md` (and `dev/state/TECH-DEBT-BACKLOG.md`) while scoping a later milestone
  - **Then** every deferral 0.22.1 carried is there with the ledger's reason and a citation back to its ledger row, and none carries a target milestone – so the follow-up is *findable* without being pre-scheduled. A deferral present only in the closed milestone's ledger fails this scenario even though the ledger itself is complete


## Structural Criteria

- [ ] `bash dev/tools/fitness/check_design_system_sync.sh` exits 0 for all three synced pairs on the release build, and DESIGN.md's § Source-of-truth paragraph describes exactly those three – no more, no fewer – with `DESIGN.md` and `showcase.html` named as never synced.
- [ ] `bash dev/tools/fitness/run_all.sh` and `dart run dev/tools/arch_check.dart` are green, and `dart analyze --fatal-warnings --fatal-infos` reports nothing.
- [ ] The two tracked `embedded_assets.g.dart` files remain tracked and are regenerated **exactly once in the release, by this story**, after the last change to an embed root; the first run moves them (they arrive stale because no other story regenerates) and the regeneration is idempotent – a second consecutive run leaves `git diff --exit-code` at 0.
- [ ] FR3's criterion is proven at **1024px width** on all five `.data-table` surfaces, as a clipping measurement (`scrollWidth <= clientWidth` per `th`, no table overflowing its wrapper) rather than a one-line assertion that canon's `nowrap` rule would satisfy by construction.
- [ ] The glitch ledger's carried deferrals are sourced from the canonical private FIS at `../dartclaw-private/docs/specs/0.22.1/fis/`, swept from both `## Implementation Observations` and `### What We're NOT Doing`, and no row cites a `dev/bundle/` path.
- [ ] Every ledger row dispositioned `deferred` is promoted to `PRODUCT-BACKLOG.md` (a deferred capability) or `dev/state/TECH-DEBT-BACKLOG.md` (a cleanup blocked on requirements or an architecture decision), citing its ledger row id and carrying the ledger's reason with no target milestone – the ledger is milestone-scoped, so an unpromoted deferral does not survive it.
- [ ] No backend surface changes: nothing under `lib/src/api/`, `lib/src/security/`, `lib/src/auth/` or any Dart handler is modified by this story, and no runtime JS dependency is added.
- [ ] No new component, token or capability is introduced by the reconciliation – a documented-but-unbacked entry is resolved by correcting the prose, never by writing new CSS.
- [ ] *If story S13 shipped:* no external origin appears in `layout.html` or in the CSP at `lib/src/auth/security_headers.dart`, and `font-src` is `'self'` (S13's gate, re-proven read-only here). *If FR8 split out:* skipped, with the split recorded in the ledger's scope notes.
- [ ] Nothing is committed or pushed in the private repo by this story; the ledger, `deviations.md` and `PRODUCT-BACKLOG.md` edits are left modified and uncommitted for the operator.


## Scope & Boundaries

### Work Areas
- `../dartclaw-public/dev/design-system/DESIGN.md` – end-to-end reconciliation and the § Source-of-truth rewrite
- `../dartclaw-public/dev/design-system/showcase.html` – demonstrations for the type tiers and the form / tab / dialog families
- `../dartclaw-public/packages/dartclaw_server/lib/src/static/VENDORS.md` + `docs/guide/` – vendored-asset and user-guide reconciliation
- `../dartclaw-private/docs/specs/0.22.1/glitch-ledger.md` (private, new) – the release's defect disposition record, milestone-scoped
- `../dartclaw-private/docs/PRODUCT-BACKLOG.md` (private) – § Deferral Rationale, the durable carrier for the ledger's deferred capabilities
- `../dartclaw-public/dev/state/TECH-DEBT-BACKLOG.md` – only for a deferral blocked on requirements input or an architecture decision, per that file's own admission rule
- `../dartclaw-private/docs/specs/0.22.1/fis/s*.md` (private, **read-only**) – the canonical FIS the deferral sweep reads; this story reads them, it does not edit them
- `../dartclaw-private/docs/wireframes/deviations.md` (private) – intentional divergences this release introduced
- `../dartclaw-public/packages/dartclaw_server/lib/src/generated/embedded_assets.g.dart` + `packages/dartclaw_workflow/lib/src/generated/embedded_assets.g.dart` – the once-per-release regeneration, owned solely by this story
- Release validation run: `visual` profile capture matrix, `dev/testing/UI-SMOKE-TEST.md`, `dev/tools/release_check.sh`

### What We're NOT Doing
- Writing new CSS to close a documented-but-unbacked entry -- that is a new capability, which the release's out-of-scope constraint forbids; the prose is what gets corrected.
- Fixing regressions the release capture uncovers -- this story is the gate that *finds* them; a regression traced to a specific story is reported back to that story rather than patched here, so blame and per-story validation stay intact. Reporting is not disposal: the gate **blocks** until the owning story lands its fix and TI07–TI10 re-run (see § Execution Contract).
- Version bump, `CHANGELOG.md`, `STATE.md`, `ROADMAP.md` and `feature-comparison.md` -- release *preparation* per the project's release checklist, sequenced after this story's gate passes and outside the plan's scope for it.
- *Scheduling* the release's deferrals -- TI11 records each one in the durable backlog with its reason and **no target milestone**; which milestone picks it up is a roadmap decision, and `ROADMAP.md` / `INSPIRATION-BACKLOG.md` are untouched here. Recording is not scheduling: a deferral that exists only in a closed milestone's ledger is lost, which is the failure OC02 exists to prevent.
- Re-running per-story visual validation -- each story already gated on its own captures; this is the release gate, not a substitute for them.


## Architecture Decision

**Approach**: treat `check_design_system_sync.sh` as the authority on what canon means and correct DESIGN.md to match it; treat the audit's *written* findings as the release baseline and TI08's capture matrix – the audit's 92 plus 20 shots the FR3 and settings criteria need – as a fresh capture validated against them.
**Why this over alternatives**: relaxing the check to match the prose would re-open the app-side fork 0.22 closed, and the pixel baseline the NFR names no longer exists – finding-by-finding validation is the only comparator that actually survives.


## Technical Overview

Two halves that share one build. The documentation half (TI01–TI06) is text-only and lands before TI07 for sequencing hygiene: the bundles are drifted by **every upstream story**, each of which re-synced `lib/src/static/`, not by S14's own work – `dev/design-system/` is not an embed root (`embed_assets.dart` bundles only `lib/src/templates`, `lib/src/static`, `packages/dartclaw_workflow/skills` and its workflow definitions). The one S14 write into an embed root is TI02's temporary drift-proof append, which must be reverted before TI07. The validation half (TI08–TI10) then runs against a frozen tree – capture matrix, smoke test, automated gates – and reports rather than repairs. The ledger sits between them: it is written from the audit plus every upstream story's recorded deferrals, and it is what TI08 checks the capture against. TI11 is the tail: text-only like the first half, but it runs after the gate because the gate itself can produce a deferral, and it moves the ledger's survivors into a backlog that outlives the milestone.


## Code Patterns & External References

```
# type | path#anchor or url                                          | why needed (intent)
file   | dev/tools/fitness/check_design_system_sync.sh#check          | The byte-identity contract DESIGN.md must be rewritten to describe: sha256 header + `tail -n +3` body diff
file   | dev/tools/release_check.sh:122-134                           | The embedded-asset gate: ls-files → embed_assets.dart → git diff --exit-code
file   | dev/design-system/components.css:6-30                        | The numbered category index; the reverse half of the reconciliation checks it against the file's own section banners
file   | dev/design-system/DESIGN.md:400                              | The existing app-owned exemption wording for `.page-content` / `.page-inner` – reuse this shape for any further exemption
file   | packages/dartclaw_server/lib/src/static/VENDORS.md#highlightjs | Per-asset entry shape: version, source URL, file table, upgrade steps
file   | ../dartclaw-private/docs/wireframes/deviations.md            | Row shape: # / Area / Wireframe Shows / Implementation Does / Resolution / Canonical, each dated
file   | dev/testing/UI-SMOKE-TEST.md                                 | The 31 cases and the R-01…R-12 regression checks the release run walks
```


## Constraints & Gotchas

- **Constraint**: this FIS lives in `dartclaw-private`, the code does not -- every bare `dev/…`, `packages/…` and `docs/guide/…` path and every Verify command is relative to the sibling repo root `../dartclaw-public/`; run them from there. Private-repo paths carry an explicit `../dartclaw-private/` prefix.
- **Critical**: the smoke test's cases are `TC-01…TC-29`, `TC-07A` and `TC-31` – **there is no TC-30**. The PRD's "TC-01…TC-31" is a range label, not a count -- Must handle by: asserting all **31** cases present in `UI-SMOKE-TEST.md` pass, never by iterating 1..31.
- **Critical**: the audit's `shots/desktop-dark/*.png` paths quoted throughout the findings do not exist on disk -- Must handle by: reading each finding's written evidence (measured px, sampled colours, coordinates) as the baseline and confirming it against the fresh capture; never cite or depend on a path under `.agent_temp/`.
- **Constraint**: `deviations.md`, the ledger **and the sixteen story FIS the deferral sweep reads** are all **private-repo** files. A public-repo implementation run must read and write `../dartclaw-private/...` directly (DEVELOPMENT-PROCESS Path B step 3) – the exported copies under `dev/bundle/` are deleted before merge, so a write there is lost and a *read* there sees whatever the export froze rather than what the stories actually recorded. And per project policy, **never commit or push in the private repo**: leave `glitch-ledger.md` and `deviations.md` modified for the operator to commit.
- **Critical**: the deferral sweep must read **both** `## Implementation Observations` **and** `### What We're NOT Doing`, plus task bodies -- `plan.json#executionNotes` asks stories to land prose deferrals in Implementation Observations, but nothing this story can check enforces that, and as authored several stories record deferrals only in prose. Two are in neither block: S10's unstable "Page 1 of N" label sits in its § Validation notes and S12's orphaned `openCommandPalette` sits in a task body (D15 and D23 in § Deferral inventory). Must handle by: sweeping each whole file, not two named headings.
- **Critical**: the DM and group allowlist deletes are **S06's shipped work, not deferrals** -- `plan.json#stories[S06].scope` mandates them, S06's Required Context binds them ("all three are this story's, not deferrals"), S06 TI10 implements them and its Final Validation Checklist gates on all three issuing no `DELETE` until confirmed. An earlier reading that routed two of them to this ledger has been corrected out of S06 and S11 as authored. Must handle by: taking the ledger row from what S06 actually recorded at story close, and if any prose in either story still reads them as deferred, treating that as stale and noting it in the scope notes. Do not carry a deferral for work a story shipped.
- **Constraint**: the embedded-asset regeneration is **exclusively this story's** and runs after every other task -- `plan.json#executionNotes` reserves the single release regeneration for S14 precisely so TI07's idempotency check has meaning: the bundles arrive stale, so the first run moves them. Running it earlier means any later re-sync or regression fix re-drifts it and the gate fails again. If TI08–TI10 send a regression back to its owning story, TI07 re-runs after that fix lands.
- **Critical**: after S02 ships `.data-table th { white-space: nowrap }` – absent from `components.css` today – any FR3 check phrased as "the header renders on one line" is true by construction and tests nothing. Must handle by: measuring **clipping** (`scrollWidth <= clientWidth` per `th`, and the table not exceeding its wrapper) at 1024px, the shape S08 TI02 already uses for the tasks table. The cascade trap applies here too: S08 removes `.task-status-group`'s `white-space: normal` / `word-break: break-word` / `table-layout: fixed` overrides (`app.css:1616-1628`), without which canon's rule is live but inert.
- **Constraint**: the UI smoke test is written against the **`plain`** profile (port 3335, desktop 1280 / mobile 375) and several cases assert plain-profile seed state; the capture matrix is written against the **`visual`** profile (port 3338, 1440×900 / 768×1024) -- Must handle by: running each on its own documented environment, built from the **same commit**, and recording that commit with both results. Do not run the smoke test against the `visual` profile.
- **Avoid**: closing the DESIGN.md reverse direction with a per-selector match -- Instead: reconcile at **category** level (the numbered index in `components.css:6-30` vs. its own section banners vs. DESIGN.md sections); `components.css` defines 209 selectors against 111 backticked in DESIGN.md, and most of the difference is variants and sub-elements of documented families, not gaps.
- **Constraint**: if FR8 (S13) was split into its own point release, the `VENDORS.md` entries for htmx / marked / JetBrains Mono and the external-origin structural criterion do not apply -- record that in the ledger as a scope note rather than asserting a gate that has no owner.


## Implementation Plan

### Implementation Tasks

- [ ] **TI01** DESIGN.md documents exactly what canon defines, in both directions
  - Forward: every backticked class in DESIGN.md resolves to a rule in `components.css` or `icons.css`, except entries DESIGN.md itself marks app-owned in the § Layout migration-note shape (`DESIGN.md:400`). Prose-only sections carry no backticked class and are therefore invisible to that sweep – § Native selects (`DESIGN.md:662-666`) is the one FR9 names, and it is checked by hand against the `.form-select` rules story S03 shipped. Reverse: the numbered category index at `components.css:6-30` matches the file's own section banners one-for-one, by number and name, and every category has a DESIGN.md section. Resolve gaps by correcting prose – no new CSS.
  - **Verify**: ``Test: for c in $(grep -o '`\.[a-z][a-z0-9-]*`' dev/design-system/DESIGN.md | tr -d '`' | sort -u); do grep -q -- "\\$c\b" dev/design-system/components.css dev/design-system/icons.css || echo "$c"; done`` prints only `.page-content` and `.page-inner` (it prints `.chip--file`, `.page-content`, `.page-inner` today); `grep -c '^   [0-9]\{1,2\}\. ' dev/design-system/components.css` returns 48 = 2×24, and the 24 index entries and 24 banner lines are diffed pairwise to confirm the numbering and names actually agree (the count alone does not prove it); `rg -n 'form-select' dev/design-system/components.css` matches and § Native selects names it, or § Native selects is rewritten to prose an existing rule backs; and `git diff --stat -- dev/design-system/components.css dev/design-system/icons.css` shows no added rule head – the reconciliation corrects or deletes prose only

- [ ] **TI02** DESIGN.md § Source-of-truth scope states the byte-identity contract the check enforces
  - Start by re-reading `check_design_system_sync.sh` and confirming its scope has not moved: it calls `check` exactly three times, on `tokens.css` → `static/tokens.css`, `components.css` → `static/design-system.css`, and `icons.css` → `static/icons.css`, each comparing a `sha256` of the source against line 2 of the served copy and then `diff`ing the source against `tail -n +3` of it. `DESIGN.md` and `showcase.html` appear in no `check` call and are not synced at all. **The script is authoritative and the prose is what changes** – if this reading is wrong, stop and report rather than editing either.
  - Then replace the "served files may deliberately extend the spec … such extensions are not drift" sentence (`DESIGN.md:311`) with that contract: byte identity under a two-line `sha256:` provenance header for those three pairs and only those; `icons.css` stops being described as the sole strict-sync exception (its icon-inventory test at `packages/dartclaw_server/test/static/design_system_icons_sync_test.dart` is an *additional* check, not the only enforcement); and `DESIGN.md` / `showcase.html` are named as never-synced prose and demo. That last clause is load-bearing beyond documentation hygiene: `plan.json#sharedDecisions` closes only the three drift-checked files after P1 and leaves `DESIGN.md` and `showcase.html` writable by any story, so the paragraph must not read as though the whole directory is under one rule.
  - **Verify**: `Test: rg -c '^check ' dev/tools/fitness/check_design_system_sync.sh` returns exactly 3, those three lines name `tokens.css`, `components.css`→`design-system.css` and `icons.css`, and `rg -n 'DESIGN\.md|showcase' dev/tools/fitness/check_design_system_sync.sh` exits with code exactly 1 – the script's scope is those three pairs and nothing else, so the prose's asymmetry is the script's own; `grep -n "not drift\|deliberately extend" dev/design-system/DESIGN.md` prints nothing; `grep -n "byte-identical" dev/design-system/DESIGN.md` matches inside the § Source-of-truth paragraph, and that paragraph also names `DESIGN.md` and `showcase.html` as never synced; appending one rule to `packages/dartclaw_server/lib/src/static/design-system.css` makes `bash dev/tools/fitness/check_design_system_sync.sh` exit non-zero with `design-system drift: design-system.css`; then `git checkout -- packages/dartclaw_server/lib/src/static/design-system.css` (that file only – `showcase.html` carries TI03's work and must not be reverted), and the check exits 0 and `git status --porcelain packages/dartclaw_server/lib/src/static/` prints nothing before TI07 runs

- [ ] **TI03** `showcase.html` demonstrates every type tier and component family the release added
  - One panel per addition, in the file's existing section style: the seven `.t-*` composite classes shown as a ladder, the `.form-*` family with every control state, `.tabs` / `.tab`, and a `.dialog` / `.dialog--confirm` that actually opens. Consumes what stories S02/S03/S04 shipped; adds no class of its own. Drops the two `chip--file` demos (`:638`, `:652`) TI01 removes from the prose, so the showcase demonstrates no class canon does not define.
  - **Verify**: `Test: for c in t-caption t-body t-label t-heading t-page-title t-display t-metric form-field form-input form-select form-textarea tabs dialog--confirm; do grep -q "$c" dev/design-system/showcase.html || echo "MISSING $c"; done` prints nothing (every one is missing today); `rg -c 'chip--file' dev/design-system/showcase.html dev/design-system/DESIGN.md` returns no matches; browser: the seven type samples render at visibly different sizes in both themes and the dialog demo opens and closes

- [ ] **TI04** `VENDORS.md` documents every asset served from `lib/src/static/`
  - Each vendored asset carries version, source URL, file table and upgrade instructions in the existing per-asset shape. If story S13 shipped, that is seven entries (highlight.js, DOMPurify, htmx-ext-sse, Stimulus, htmx 2.0.8, marked 15, JetBrains Mono 400/500/600); if FR8 split out, four, with the split recorded in the ledger's scope notes. Determine the branch from `plan.json` story S13's `status` before starting.
  - **Verify**: `Test: grep -c '^## ' packages/dartclaw_server/lib/src/static/VENDORS.md` returns 7 if story S13 shipped, 4 if FR8 split out (4 today); and the seven vendored files under `lib/src/static/` – `hljs.min.js`, `hljs-dart.min.js`, `hljs-catppuccin-latte.css`, `hljs-catppuccin-mocha.css`, `purify.min.js`, `sse.js`, `stimulus.min.js` – plus anything story S13 added each appear in exactly one file table (first-party `app*.css`, the three synced canon files and `controllers/*.js` are excluded by definition)

- [ ] **TI05** The deviations register and the user guide describe the shipped UI
  - Add one dated row to `../dartclaw-private/docs/wireframes/deviations.md` per intentional divergence this release introduced – at minimum the surface re-tone, the in-app confirmation replacing native dialogs, and the wide-container tier – plus every deviation upstream stories recorded, read from the canonical private FIS and swept from both blocks per TI06's rules (S15's empty `.run-card` identicon and `.tool-indicator` slots, D28 in § Deferral inventory, is the one named at spec time). Sweep `../dartclaw-public/docs/guide/` for invalidated behaviour; `architecture.md:404` ("Custom CSS with Catppuccin-based design tokens") and `web-ui-and-api.md` are the only two candidates found at spec time, and "no guide change required" is a valid recorded outcome.
  - **Verify**: `Test: grep -c '^| [0-9]' ../dartclaw-private/docs/wireframes/deviations.md` has grown by at least 3 over its current 18 rows, each new row dated from `date +%Y-%m-%d` and naming Resolution + Canonical; the guide sweep's outcome (changed files, or "none required" with the grep that established it) is recorded in the ledger's scope-notes section

- [ ] **TI06** The glitch ledger carries a disposition for every catalogued defect
  - Create `../dartclaw-private/docs/specs/0.22.1/glitch-ledger.md` with three sections. **(1) Glitch rows** – one row per **distinct** defect derived from the audit's 72 section-B findings, grouped by surface, in the fixed shape `| id | surface | folded findings | severity | disposition | evidence-or-reason |`, naming the duplicate findings folded into it (e.g. the five separate `tasks` table-header findings are one defect) and carrying that finding's audit severity (`HIGH` / `med` / `low`). `disposition` is `closed` – evidence being the owning story ID plus the file or commit that closed it – or `deferred`, evidence being the reason. No `HIGH` row may be `deferred`: FR7's first acceptance criterion admits closure only, and a `HIGH` that cannot close is escalated, not recorded.
  - **(2) Carried deferrals** – every deferral the stories recorded that sits **outside** section B, in the same row shape plus a `source` column naming the FIS *and the block within it*. Three rules govern the sweep, the first two from `plan.json#executionNotes`:
    - **Source is the canonical private FIS**, `../dartclaw-private/docs/specs/0.22.1/fis/s*.md` – never the exported copies under `../dartclaw-public/dev/bundle/`, which are deleted before merge. A deferral that exists only in a bundle copy dies with it and success metric 5 then fails silently, which is the exact failure the rule exists to prevent.
    - **Sweep both blocks**, `## Implementation Observations` *and* `### What We're NOT Doing`. The plan asks stories to land prose deferrals in Implementation Observations, but nothing this story can check enforces that write-back, and several stories record deferrals only as prose bullets. Reading one block is how the ledger silently loses rows. Sweep task bodies as well, where a story routes a deferral there rather than into either block – D15 and D23 in § Deferral inventory are the two known cases at spec time. The reliable pass is `rg -n -i 'defer|ledger|record as|orphan' ../dartclaw-private/docs/specs/0.22.1/fis/s*.md` over each whole file, then triage the hits.
    - **§ Deferral inventory's D01–D30 is the floor** (D26 withdrawn – it belongs in § Glitch rows as `closed`). Each live row must appear here – carrying its `D..` id in the `source` column so the sweep is checkable – or be shown closed by a story; **Z1** (the `--z-*` app-side migration, now owned by S07 TI08) is open, not deferred, and must resolve to `closed` or `deferred`. Execution will add rows the table does not have; that is expected, a missing row is not. Close the section with a **per-story roll-call** – one line for each of S01–S13, S15 and S16 stating the deferrals carried or `none` – so a story that was never swept is visible rather than silent. These rows are counted separately and are not part of the 72.
  - **(3) Scope notes** – the FR8/story-S13 branch, the user-guide sweep outcome, the capture manifest and smoke-test result locations, and the count reconciliation. State the distinct-defect count and the distinct `HIGH` count, and reconcile them against the PRD's 64 and 23; section B holds 72 findings of which 26 are `HIGH`, so folding is expected to close both gaps. If it does not, record the delta and why rather than forcing the number.
  - **Verify**: `Test:` an `awk` pass over section 1's table prints the id of every row whose `disposition` is not exactly `closed` or `deferred`, whose `evidence-or-reason` cell is empty, or whose `severity` is `HIGH` while `disposition` is `deferred`, and exits non-zero if it printed anything – on the finished ledger it prints nothing, and re-run against a scratch copy with one disposition cell and one reason cell blanked it prints both ids and exits non-zero. Row count equals the stated distinct-defect count; every `### <surface> (n)` heading under the audit's section B is represented and the sum of the folded finding counts is 72; section 2's rows each name their source FIS **and the block within it** and are excluded from that 72; section 3 states the reconciliation against 64 and 23, the story-S13 branch and the guide-sweep outcome. Sweep completeness: `for f in ../dartclaw-private/docs/specs/0.22.1/fis/s[0-9][0-9]-*.md; do id=$(basename "$f" | cut -c1-3 | tr 'a-z' 'A-Z'); [ "$id" = "S14" ] && continue; grep -q "^| $id " ../dartclaw-private/docs/specs/0.22.1/glitch-ledger.md || echo "no roll-call row: $id"; done` prints nothing, and printing it after deleting one roll-call row names exactly that story. `L=../dartclaw-private/docs/specs/0.22.1/glitch-ledger.md; for d in D01 D02 D03 D04 D05 D06 D07 D08 D09 D10 D11 D12 D13 D14 D15 D16 D17 D18 D19 D20 D21 D22 D23 D24 D25 D27 D28 D29 D30 Z1; do grep -q "\b$d\b" "$L" || echo "missing: $d"; done` prints nothing (drop one inventory row from the ledger and it names that id). `rg -n 'dev/bundle' ../dartclaw-private/docs/specs/0.22.1/glitch-ledger.md` exits with code exactly 1 – no row cites the transient export as its source. `git -C ../dartclaw-private status --porcelain docs/` shows `glitch-ledger.md` and `deviations.md` modified and uncommitted, and `git -C ../dartclaw-private log --oneline -1` is unchanged from story start – the operator commits; this story never does

- [ ] **TI07** The tracked embedded-asset bundles match the shipped static tree – S14's single, exclusive regeneration
  - **S14 is the sole owner of this action for the whole release.** `plan.json#executionNotes`: *"`embedded_assets.g.dart` is regenerated exactly ONCE, by S14. No other story runs `dart run dev/tools/embed_assets.dart`, and no other story asserts a clean `git diff` on it."* S01, S02, S04, S13 and S15 each carry the matching "leave it stale" instruction. That exclusivity is what makes the idempotency check below mean anything: the bundles arrive here **stale**, so the first run must move them.
  - Run after TI01–TI06, after every canon re-sync in the release has landed, and after TI02's temporary drift-proof append is reverted. Follow `release_check.sh:122-134`: confirm both files are tracked (`packages/dartclaw_server/lib/src/generated/embedded_assets.g.dart` and `packages/dartclaw_workflow/lib/src/generated/embedded_assets.g.dart`), run the generator **once**, inspect the diff before committing it in the **public** repo, then let `release_check.sh` § 5 – which runs the generator itself and follows with `git diff --exit-code -- '**/generated/embedded_assets.g.dart'` – prove the run was idempotent. If TI08–TI10 send a regression back to its owning story, re-run this task once that fix lands.
  - **Verify**: `Test: git ls-files --error-unmatch -- packages/dartclaw_server/lib/src/generated/embedded_assets.g.dart packages/dartclaw_workflow/lib/src/generated/embedded_assets.g.dart` exits 0; then `dart run dev/tools/embed_assets.dart` followed by `git diff --stat -- '**/generated/embedded_assets.g.dart'` prints a **non-empty** stat on this first release run – an empty stat means a story other than S14 already regenerated, which contradicts `executionNotes` and is recorded as a finding rather than passed (on a *re-run* after a regression fix the stat is empty unless that fix touched an embed root, which is expected and not a finding); after committing, `dart run dev/tools/embed_assets.dart && git diff --exit-code -- '**/generated/embedded_assets.g.dart'` exits 0, and `bash dev/tools/release_check.sh` § 5 reports `embedded assets current`

- [ ] **TI08** The release capture matrix shows no regression against the audit's recorded findings
  - Capture 112 shots from the `visual` profile (port 3338), in three bands:
    - **92** – 23 surfaces × dark/light × 1440×900 and 768×1024, the audit's own matrix.
    - **10** – the settings tabs at 1440×900 dark; the audit's method line captured them beyond the 92, and six section-B findings key to them (`settings/tab-bar`, `settings/agent`, `settings/all-tabs`, `settings/restart-banner`, `settings/security`) are otherwise unverifiable.
    - **10** – the five data-table surfaces × dark/light at **1024×900**. FR3's criterion is *"No table header wraps mid-word at any viewport ≥ 1024px"* and 1024px **width** is captured nowhere else in this matrix: 1440×900 is above it and 768×1024 is 768 wide. Only the tasks table is checked at 1024px by any other story (S08 TI02). The five are `/tasks` (`tasks.html`), `/scheduling` (`scheduling.html`), `/health-dashboard/audit` (`audit_table.dart`, which gains `class="data-table"` in S09 TI07), `/memory` (`memory_dashboard.html`, three tables) and `/settings` Security tab (the guard-editor table, which gains `class="data-table guard-editor-table"` in S11 TI10).
  - **Assert clipping, not wrapping.** Once canon's `.data-table th { white-space: nowrap }` governs – S02 ships it; it is absent from `components.css` today – "the header renders on one line" is true **by construction** and proves nothing. The failure mode that survives the rule is the header being clipped or its table overflowing. Measure per `th`, as S08 TI02 already does for tasks.
  - Record the surface list, the three bands and the commit under test in the ledger's scope notes so the 112 is checkable. Validate each shot against the audit's written evidence for that surface, and confirm every high-severity defect the ledger marks closed is absent. A regression outside this story's scope is reported to its owning story, not patched here – and it blocks the gate until that story's fix lands.
  - **Verify**: `Test: the capture manifest names 23 surfaces and 112 files – 92 (23 × dark/light × 1440×900 and 768×1024), 10 settings-tab shots at 1440×900 dark, and 10 data-table shots at 1024×900 – all from the visual profile on port 3338, with the commit SHA; at 1024px width, on each of /tasks, /scheduling, /health-dashboard/audit, /memory and /settings Security, every th in every .data-table satisfies scrollWidth <= clientWidth and its table's scrollWidth does not exceed its wrapper's clientWidth – a clipping measurement, so it can still fail once canon's nowrap rule ships, which a "renders on one line" assertion cannot; every section-B finding the ledger marks closed is confirmed absent in the named capture; card-vs-ground contrast computed as the WCAG relative-luminance ratio of the resolved tokens.css values is ≥ 1.15:1 in both themes and no gradient stop equals the card fill; WCAG AA text contrast (≥ 4.5:1) holds on every re-toned surface; focus-visible is present across the full keyboard tab order of chat, tasks, settings, health and knowledge-hub in both themes, and no status is conveyed by colour alone`

- [ ] **TI09** The UI smoke test is green on the release build
  - Walk every case in `dev/testing/UI-SMOKE-TEST.md` plus the R-01…R-12 regression checks, on that file's own documented environment – the `plain` profile at port 3335, desktop 1280 / mobile 375 (`UI-SMOKE-TEST.md:15` § Setup) – built from the same commit as TI08's capture, after running the `## Environment Health Check` block at `UI-SMOKE-TEST.md:560`.
  - **Verify**: `Test: all 31 cases pass — TC-01…TC-29, TC-07A and TC-31 (there is no TC-30) — and R-01…R-12 show no regression; the result and the commit SHA under test are recorded in the ledger's scope notes, matching TI08's`

- [ ] **TI10** The automated release gates are green on the same build
  - Consumes TI07's regenerated bundles. Runs the drift check, the fitness suite, the architecture check and analysis, plus the release's own metric greps.
  - **Verify**: `Test: bash dev/tools/fitness/check_design_system_sync.sh` exits 0; `bash dev/tools/fitness/run_all.sh` and `dart run dev/tools/arch_check.dart` pass; `dart analyze --fatal-warnings --fatal-infos` is clean; `rg -n 'window\.(alert|confirm|prompt)|(^|[^.\w])(alert|confirm|prompt)\(' packages/dartclaw_server/lib/src/static/controllers/` prints nothing; `rg -n -- '--text-sm' packages/dartclaw_server/lib/src/static/ dev/design-system/` prints nothing; `grep -n 'https://' packages/dartclaw_server/lib/src/templates/layout.html` prints nothing (it prints three CDN loads today); `rg -n "https?://" packages/dartclaw_server/lib/src/auth/security_headers.dart` prints nothing and `rg -n "font-src 'self'" packages/dartclaw_server/lib/src/auth/security_headers.dart` matches (it reads `font-src https://fonts.gstatic.com` today) – read-only, story S13 owns the edit, and both clauses are skipped with a ledger scope note if FR8 split out; `git diff --name-only -- 'packages/*/lib/src/api/' 'packages/*/lib/src/security/' 'packages/*/lib/src/auth/'` prints nothing, proving no backend surface moved

- [ ] **TI11** Every deferral the ledger records reaches a durable backlog
  - Runs **last**, after TI10: TI08–TI10 can add carried deferrals of their own (a regression the operator explicitly accepts, per § Execution Contract), so any earlier run would miss them.
  - For each row in the finished ledger whose `disposition` is `deferred` – from **both** § Glitch rows and § Carried deferrals – add one entry to the durable backlog carrying the ledger's reason verbatim and citing the ledger row's id, so the promotion is checkable in both directions. Route by kind, not by convenience:
    - **A deferred capability** – something the product does not do yet – goes to `../dartclaw-private/docs/PRODUCT-BACKLOG.md` § Deferral Rationale, in that table's existing `| Feature | Why Deferred |` shape. The two known at spec time are both of this kind: the missing chart/sparkline component (S09) and the KG timeline's absent time axis (S10).
    - **A deferred cleanup that cannot be resolved without further requirements input or an architecture decision** goes to `../dartclaw-public/dev/state/TECH-DEBT-BACKLOG.md` instead. **Z1** is the candidate: if the `--z-*` app-side migration resolves to `deferred` rather than `closed` it is debt, not a feature. Respect that file's own rule – it is reserved for items that cannot be fixed now, never a default landing zone – so a deferral that is merely unscheduled UI work is a backlog feature and does not belong there.
  - Carry the reason and **no target milestone**; see § What We're NOT Doing. A row that restates "deferred" without the ledger's reason is not a promotion.
  - `PRODUCT-BACKLOG.md` is private: leave it modified and uncommitted for the operator. `TECH-DEBT-BACKLOG.md` is public-canonical under `dev/state/` and is committed in the public repo like any other file this story edits.
  - **Verify**: `Test:` with `L=../dartclaw-private/docs/specs/0.22.1/glitch-ledger.md`, `P=../dartclaw-private/docs/PRODUCT-BACKLOG.md` and `T=dev/state/TECH-DEBT-BACKLOG.md`, an `awk` pass printing the id of every ledger row whose `disposition` is exactly `deferred`, piped through `while read id; do grep -q "$id" "$P" || grep -q "$id" "$T" || echo "not promoted: $id"; done`, prints nothing – and re-run after deleting one promoted entry it names exactly that id, proving the check can fail. The reverse direction holds too: every entry citing a `0.22.1` ledger id resolves to a row the ledger marks `deferred`, so nothing is promoted that was actually closed. Each promoted entry's reason cell is non-empty and names no target milestone; `rg -n 'dev/bundle' "$P" "$T"` exits with code exactly 1 – a promotion never cites the transient export as its source. `git -C ../dartclaw-private status --porcelain docs/PRODUCT-BACKLOG.md` shows it modified, and `git -C ../dartclaw-private log --oneline -1` is unchanged from story start – the operator commits; this story never does. *If the ledger carries no `deferred` row at all* – every catalogued defect closed – the promotion set is empty, both backlogs are untouched, and TI11 records that outcome in the ledger's scope notes rather than passing silently

### Testing Strategy

### Validation

- TI08's capture matrix, the smoke test and the automated gates must all run against **one** commit with no edits between them – a gate passing on a different tree than the capture proves nothing. The two profiles differ (`visual` for the capture, `plain` for the smoke test); the commit must not.

### Execution Contract

- Read `plan.json` story S13's `status` first and record the FR8 branch in the ledger's scope notes: it decides TI04's expected entry count and whether the external-origin criterion applies.
- TI06's deferral sweep reads the **canonical** private FIS at `../dartclaw-private/docs/specs/0.22.1/fis/`, never a `dev/bundle/` copy, and reads each file whole rather than two named headings.
- TI07 runs after TI01–TI06 and after TI02's temporary append is reverted: any edit to an embed root landing after it re-drifts the generated bundles. It is the release's **only** run of `embed_assets.dart`; if the first run yields no diff, another story regenerated against the plan – record it as a finding before proceeding.
- TI08–TI10 run after TI07, against a frozen tree.
- A regression TI08–TI10 finds **blocks the gate**. It is reported to its owning story, that story reopens and lands the fix, then TI07 re-runs and TI08–TI10 re-run against the new tree. Only a regression the operator explicitly accepts may be recorded instead, as a carried deferral naming the operator's decision. S14 never patches it in place.
- TI11 runs last, after TI10: an operator-accepted regression becomes a carried deferral during TI08–TI10, so promoting before they finish misses it.
- TI05, TI06 and TI11 write to `../dartclaw-private/`; leave them modified and uncommitted for the operator to commit. TI11's `TECH-DEBT-BACKLOG.md` edit is the exception – that file is public-canonical under `dev/state/` and is committed in the public repo.


## Final Validation Checklist

- [ ] No file under `dev/bundle/` was edited in place as a substitute for the private canonical `deviations.md` or the ledger, and no ledger row was sourced from a `dev/bundle/` copy of a FIS.
- [ ] Nothing was committed or pushed in `dartclaw-private`; `glitch-ledger.md`, `deviations.md` and `PRODUCT-BACKLOG.md` are left modified for the operator.
- [ ] Every `deferred` row in the finished ledger was promoted by TI11 into `PRODUCT-BACKLOG.md` or `dev/state/TECH-DEBT-BACKLOG.md` with its reason and a citation back to the ledger row – including any carried deferral TI08–TI10 added late – and nothing was promoted that the ledger marks `closed`. An empty promotion set is valid only if no row is `deferred`, and is recorded as such in the scope notes.
- [ ] Every live deferral in § Deferral inventory (D01–D30, less the withdrawn D26) appears in the ledger or is shown closed by a story, Z1 resolves to `closed` or `deferred`, and the per-story roll-call covers S01–S13, S15 and S16 – so a story that was never swept is visible.
- [ ] `embed_assets.dart` ran exactly once in the release, in TI07, and its first run produced a non-empty diff.
- [ ] Every regression the release capture found was fixed by its owning story and re-proven by a re-run of TI07–TI10, or explicitly accepted by the operator and recorded as a carried deferral – none absorbed silently into this story, and none merely logged.


## Implementation Observations

_No observations recorded yet._
