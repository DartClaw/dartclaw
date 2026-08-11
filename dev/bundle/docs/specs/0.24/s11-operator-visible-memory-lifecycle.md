# Feature Implementation Specification: Operator-Visible Memory Lifecycle

**Plan**: dev/bundle/docs/specs/0.24/plan.json
**Story-ID**: S11

## Feature Overview and Goal

**Intent**: Let operators understand what DartClaw remembers, what is merely observed or derived, and what action is safe when curation, indexing, or recovery is incomplete.

**Expected Outcomes**:

- [OC01] Existing Memory, Knowledge, status, API, CLI, and job surfaces distinguish canonical roles and derived chunks without presenting observations or search rows as curated truth.
- [OC02] Operators see the current collection revision, prompt-index usage, raw-observation usage and coverage, index health, and last successful reconciliation without fabricated zero or complete states.
- [OC03] Operators can start explicit curation through the existing run-now path and inspect truthful running, succeeded, conflicted, or failed results, including committed-but-index-degraded success.
- [OC04] Empty, degraded, rebuilding, conflicted, failed, and successful states remain actionable, accessible, responsive, and visually coherent with the existing design system.

## Required Context

- `dev/bundle/docs/specs/0.24/plan.json#stories.10` – exact S11 scope, dependencies, risk, existing-surface boundary, and visual-state obligation.
- `dev/bundle/docs/specs/0.24/plan.json#sharedDecisions` – canonical roles, one revision authority, observation trust, fixed ceilings, stopped-edit reconciliation, fresh prompt context, immutable host system actions, and release simplicity shared across the bundle.
- `dev/bundle/docs/specs/0.24/plan.json#bindingConstraints` – file authority, shared mutation authority, explicit-only curation, bounded prompt, backend-owned query handling, fixed traversal limits, no new administration infrastructure, and settled threat model.
- `dev/bundle/docs/specs/0.24/prd.md#user-stories` – truthful health, deterministic recovery, bounded context, explicit curation, and role separation outcomes.
- `dev/bundle/docs/specs/0.24/prd.md#fr1-coherent-memory-corpus` – canonical role and provenance distinctions the presentation must preserve.
- `dev/bundle/docs/specs/0.24/prd.md#fr2-guarded-memory-tools` – canonical-success/index-degraded outcome and current-revision contract.
- `dev/bundle/docs/specs/0.24/prd.md#fr3-on-demand-semantic-curation` – explicit curation lifecycle and whole-proposal result semantics.
- `dev/bundle/docs/specs/0.24/prd.md#fr4-bounded-turn-context` – 150-line and `memory.max_bytes` prompt-index budgets and degraded prompt state.
- `dev/bundle/docs/specs/0.24/prd.md#fr5-retrieval-citation-and-index-integrity` – role-discriminated results, stable locators, derived-index health, and no false zero counts.
- `dev/bundle/docs/specs/0.24/prd.md#fr6-maintenance-limits-and-recovery` – fixed file/traversal/result/warning ceilings and exact-versus-incomplete observation coverage.
- `dev/bundle/docs/specs/0.24/prd.md#fr7-operator-control-and-observability` – authoritative fields, lifecycle states, recovery guidance, and empty/degraded/zero-result distinctions for this story.
- `dev/bundle/docs/specs/0.24/prd.md#fr8-simplification-and-release-boundaries` – prohibits a new package, database, daemon, scheduler, approval framework, admin system, or QMD responsibility.
- `dev/bundle/docs/specs/0.24/prd.md#edge-cases` – observation growth, corrupt/deleted index, stopped edits, malformed curation, and forget behavior to present truthfully.
- `dev/bundle/docs/specs/0.24/prd.md#constraints` – trusted host plus plausible crash, cooperating concurrency, untrusted semantic content, and normal resource limits.
- `dev/bundle/docs/specs/0.24/s06-fresh-bounded-turn-context.md#architecture-decision` – current dual-capped prompt-index projection and collection revision source.
- `dev/bundle/docs/specs/0.24/s07-search-and-citation-convergence.md#architecture-decision` – canonical result roles, locators, provenance, per-layer degradation, and single-owner composition.
- `dev/bundle/docs/specs/0.24/s08-index-health-and-recovery.md#architecture-decision` – exact healthy/degraded/rebuilding/unknown semantics and persisted recovery action.
- `dev/bundle/docs/specs/0.24/s09-on-demand-memory-curation.md#architecture-decision` – ScheduleService host-callback system-action seam, shared overlap, merged read-only list/show/run, persisted four-state lifecycle, bounded results, and single commit authority.
- `dev/bundle/docs/specs/0.24/s10-memory-resource-boundaries.md#fixed-resource-contract` – inclusive 64 MiB, 8 MiB, 1,000-file, 50-result, and observation-warning contracts.
- `dev/design-system/DESIGN.md#status-indicators` – canonical state vocabulary, semantic color, motion, and text-cue rules.
- `dev/guidelines/VISUAL-VALIDATION-WORKFLOW.md#viewports` – required 1280 px desktop and 375 px mobile validation.
- `dev/guidelines/TESTING-STRATEGY.md#test-layers` – lowest-effective-layer API, template, integration, and visual proof expectations.

## Deeper Context

- `dev/architecture/cli-api-architecture.md#connected-mode` – connected job commands use the server-owned runtime state rather than a CLI side channel.
- `dev/architecture/cli-api-architecture.md#9-local-only-commands` – offline `rebuild-index` remains available when the server cannot provide live status.
- `dev/architecture/observability-operations-architecture.md#3-health-monitoring` – existing health vocabulary and operator-facing status seam.
- `dev/architecture/observability-operations-architecture.md#11-heartbeat--scheduling` – current job/run-now lifecycle and overlap behavior.
- `dev/guidelines/HTMX-GUIDELINES.md#recommended-patterns` – server-rendered fragment polling and Stimulus ownership boundaries.
- `dev/guidelines/TRELLIS-GUIDELINES.md#security--the-rules-that-matter-most` – escaped dynamic state/reason/action rendering.

## Acceptance Scenarios

- [ ] **S01 [OC01,OC02,OC04] [TI01,TI02,TI03,TI06] A healthy non-empty corpus exposes canonical roles, revision, budgets, and derived state without conflation**
  - **Given** collection revision `42` has 12 curated entries across 3 topics, 4 archived entries, 7 observations, 2 learnings, 5 wiki sources, and 28 derived chunks; prompt rendering uses 101 of 150 lines and 20 KiB of its 32 KiB budget
  - **When** the status API, Memory dashboard, and Knowledge Hub render the current state
  - **Then** curated entries, topics, archive, observations, learnings, wiki sources, and derived chunks have distinct labels and counts; revision `42` and both prompt budgets are visible; derived chunks are labelled as rebuildable index data rather than memory
  - **And** each Knowledge result uses its S07 canonical role and locator, so observation or learning results never inherit the curated-memory label and wiki results retain native source provenance
  - **Proof**: `packages/dartclaw_server/test/memory/memory_status_service_test.dart#getStatus returns complete status with all files present` – green – parity/regression for the existing status aggregation seam

- [ ] **S02 [OC01,OC02,OC04] [TI01,TI02,TI03,TI06] Valid empty, zero-result, and unavailable states remain different**
  - **Given** one fixture is a validated empty canonical union with a healthy empty index, another is a healthy non-empty corpus whose query has no matches, and a third cannot establish collection or count evidence
  - **When** API, Memory, and Knowledge surfaces present each fixture
  - **Then** the first shows a canonical empty-state explanation with exact zero counts, the second shows `No results` without saying memory is empty, and the third shows `unknown` or degraded coverage with nullable counts, reason, and safe action rather than zeros or healthy state
  - **Proof**: `packages/dartclaw_server/test/templates/knowledge_surfaces_test.dart#knowledge hub empty state` – green – parity/regression for distinct layer and query empty states

- [ ] **S03 [OC02,OC04] [TI01,TI02,TI06] Observation usage is exact only when complete and warns without deleting**
  - **Given** bounded status scans whose known observation usage is 64 MiB minus one with complete coverage, exactly 64 MiB with complete coverage, and below 64 MiB with work omitted after the 1,000-file or 64 MiB request ceiling
  - **When** status is serialized and rendered
  - **Then** complete coverage reports an exact byte total and no warning below the threshold, exact known usage at the threshold reports a warning, and incomplete coverage reports a lower bound with scanned/omitted/failed files plus known oldest/newest times
  - **And** an incomplete lower bound below the warning threshold reports warning state as unknown rather than false, no state claims full coverage, and no status action deletes or rewrites observations

- [ ] **S04 [OC02,OC03,OC04] [TI01,TI02,TI05,TI06] A committed memory change with failed indexing is successful but visibly degraded**
  - **Given** revision `42` commits durably and its derived-index reconciliation fails after canonical replacement
  - **When** the tool response, persisted status API, Memory dashboard, and later CLI inspection are observed
  - **Then** each names canonical revision `42` as committed, index state as `degraded`, the failing stage and bounded reason, and the offline repair action; none rolls back the memory, calls the change failed, or reports search healthy
  - **And** repair guidance says DartClaw must be stopped before `dartclaw rebuild-index`, whose success output includes reconciled revision, indexed-row outcome, and resulting health

- [ ] **S05 [OC02,OC04] [TI01,TI02,TI05,TI06] Active reconciliation is rebuilding and stopped-edit recovery cannot appear healthy early**
  - **Given** a supported stopped-runtime edit has advanced the canonical revision and reconciliation is blocked after fresh-sibling population but before validation and swap
  - **When** Memory/API status is read during the barrier and again after successful settlement
  - **Then** the first view shows `rebuilding`, current canonical revision, last validated index revision/time, and working text without labelling the old index current; the second becomes healthy only after complete parity validation
  - **And** a failed or interrupted attempt settles degraded or unknown with recovery guidance rather than remaining falsely rebuilding

- [ ] **S06 [OC03,OC04] [TI01,TI02,TI04,TI06] Existing run-now surfaces show curation running and durable success**
  - **Given** S09 has validated collision-free configured and reserved action IDs, API/CLI/Web list/show merge configured jobs with the immutable `memory-curation` system action, and no curation has run
  - **When** an operator starts it from the Memory dashboard, Scheduling page, or `dartclaw jobs run memory-curation`, and the one S09 proposal turn later commits changed IDs A and B plus exact-no-op ID C at revision `43`
  - **Then** all triggers call the same existing run endpoint, a concurrent start returns already running, status changes from no prior run to `running` and then `succeeded`, and terminal API/CLI/Web output shows committed revision `43`, A/B, C, last-success time, and independent index health
  - **And** running is the only pulsing working state; succeeded is static success, the action is disabled only while its own run is active, and no edit/delete/toggle control, YAML representation, schedule, timer, or automatic retry is created
  - **And** a colliding startup job or config create/edit request is rejected before any duplicate row, show result, or run target appears; the UI and CLI never choose or imply a precedence winner
  - **Proof**: `apps/dartclaw_cli/test/commands/jobs/jobs_commands_test.dart#run starts a job and prints observation guidance` – green – parity/regression for the connected job run command and endpoint

- [ ] **S07 [OC03,OC04] [TI01,TI02,TI04,TI06] Conflict and failure are actionable terminal no-effect states**
  - **Given** one curation proposal conflicts with current revision `52`, and another is rejected with per-operation validation reasons before apply
  - **When** the job, status API, Memory dashboard, Scheduling page, and jobs CLI present the results
  - **Then** the conflict is `conflicted` with current revision `52`, empty changed/no-op IDs, and explicit rerun guidance; the rejection is `failed` with empty changed/no-op IDs and bounded operation reasons
  - **And** conflicted uses the canonical attention treatment plus text, failed uses static error, neither implies partial success, and untrusted model content is never rendered or printed as raw HTML/control text

## Structural Criteria

- [ ] `GET /api/memory/status` is the single machine-readable operator projection; Memory, job, and CLI presentations consume the same S06–S10 state rather than rescanning canonical/wiki files or deriving health independently.
- [ ] Status numeric fields are nullable when unavailable; zero is emitted only when complete evidence proves zero. Observation usage explicitly distinguishes `exact`, `lowerBound`, and `unknown`.
- [ ] Curation has no invented idle lifecycle state: before the first run its result is absent; once started, its state is exactly `running`, `succeeded`, `conflicted`, or `failed` as supplied by S09.
- [ ] API, CLI, Scheduling, and Memory presentations read S09's same merged system-action descriptor and persisted lifecycle; S11 adds no action registry, lifecycle store, run endpoint, or inferred terminal state.
- [ ] Presentations receive only S09's collision-free projection. A reserved-ID startup/config mutation failure uses existing validation/error surfaces and never renders, lists, shows, or runs an ambiguous entry or compatibility alias.
- [ ] Operator reasons and actions are bounded host-classified text. Web output uses escaped Trellis text/attributes; CLI output applies its existing terminal-text safety before printing any model-derived reason.
- [ ] Existing Memory, Knowledge, Scheduling, jobs, status API, and offline rebuild surfaces remain the complete administration surface; no page family, command family, SSE stream, store, database, package, daemon, scheduler, or QMD-specific health path is added.
- [ ] Status presentation uses canonical components/tokens, never color alone: `live` means active work, `attention` means operator action required, `success` and `error` are terminal, `warning` is degraded/unknown, and `idle` is neutral absence.

## Scope & Boundaries

### Work Areas

- `MemoryStatusService` and `GET /api/memory/status` operator projection over prerequisite corpus, prompt, observation, curation, migration, and index state
- Existing Memory dashboard page, Trellis template, 30-second HTMX fragment, file reader, and Stimulus actions
- Existing Knowledge Hub result role/provenance badges, layer failure/empty states, and source labels
- Existing Scheduling system-job row plus `/api/scheduling/jobs/*` list/show/run contracts for `memory-curation`
- Existing jobs CLI and offline `rebuild-index` output/recovery guidance
- Service, route, template, controller, CLI, accessibility, and visual-state verification

### What We're NOT Doing

- Adding a memory admin page, a `memory` CLI command family, a curation endpoint, or another lifecycle store – reuse the current Memory/Scheduling/jobs/status seams.
- Changing canonical role, mutation, prompt selection, curation, index recovery, or resource-limit semantics – S06–S10 are authoritative producers.
- Adding online index repair or exposing generic file editing/deletion controls – repair remains the stopped-runtime rebuild path and manual Markdown changes remain a stopped-runtime operation.
- Adding automatic curation, raw-observation retention/deletion, approval workflows, or autonomous stewardship – those remain 0.27 product decisions.
- Giving QMD new status, repair, locator, or lifecycle meaning – it remains transitional under the settled release boundary.

## Architecture Decision

**Approach**: Extend the existing memory status projection with typed snapshots from S06–S10, and expose S09's merged read-only system-action descriptor plus persisted lifecycle through the current Memory, Knowledge, Scheduling, API, jobs CLI, and rebuild surfaces.
**Why this over alternatives**: A separate admin service or live-stream protocol would duplicate state and operations; the existing 30-second status poll and connected job endpoint already provide sufficient control and freshness.

## Technical Overview

`GET /api/memory/status` exposes five cohesive objects, with absent evidence represented by null rather than zero:

- `collection`: `revision`, curated/topic/archive counts, opaque-legacy count, and S03 migration state/backup/action.
- `promptIndex`: `usedBytes`, `budgetBytes`, `usedLines`, `lineBudget`, `omittedEntries`, `truncated`, and degraded reason.
- `observations`: entry count, `usageBytes`, `usageKind` (`exact|lowerBound|unknown`), scanned/omitted/failed files, oldest/newest time, `warningAtBytes`, and nullable `warning`.
- `index`: `state` (`healthy|degraded|rebuilding|unknown`), canonical/indexed revisions and nullable counts, last reconciliation, failure stage/reason, and repair action.
- `curation`: absent before first run; otherwise S09 state, start/completion/last-success time, snapshot/committed/current revisions, bounded changed/no-op IDs and operation reasons, independent index state, and repair/rerun action.

The Memory dashboard uses the polled projection for roles, budgets, lifecycle, and recovery while keeping file tabs outside the poll. Knowledge continues to own search-result presentation and adds the prerequisite role label without exposing derived chunk identity. After S09 reserved-ID validation succeeds, Scheduling list/show, jobs CLI list/show, and Web rows merge the immutable system-action descriptor with configured jobs; their existing run endpoint invokes it, while create/edit/delete/toggle and YAML remain configured-job-only. Startup and config create/edit collisions fail on existing error surfaces before an ambiguous row/result/target exists. The offline rebuild command remains the last-resort repair path.

## Code Patterns & External References

```text
# type | path#anchor | why needed (intent)
file | packages/dartclaw_server/lib/src/memory/memory_status_service.dart#MemoryStatusService.getStatus | Existing fresh status aggregator and current false-zero paths to replace with prerequisite typed state
file | packages/dartclaw_server/lib/src/api/memory_routes.dart#memoryRoutes | Existing status/file/prune API family; no new administration router
file | packages/dartclaw_server/lib/src/templates/memory_dashboard.dart#memoryDashboardTemplate | Existing render-context seam and 30-second fragment model
file | packages/dartclaw_server/lib/src/templates/memory_dashboard.html#memoryDashboard | Existing Memory layout, metrics, status, file tabs, and action cards
file | packages/dartclaw_server/lib/src/static/controllers/dc_memory_controller.js#DcMemoryController | Existing Stimulus action and post-HTMX-swap lifecycle
file | packages/dartclaw_server/lib/src/knowledge/knowledge_hub_service.dart#KnowledgeHubItem | S07 result role, locator, and provenance flow into presentation
file | packages/dartclaw_server/lib/src/templates/knowledge_hub.dart#KnowledgeHubItemView | Existing result badge/source view model
file | packages/dartclaw_server/lib/src/templates/knowledge_hub.html#knowledgeHub | Existing layer, partial-failure, result, and empty-state presentation
file | packages/dartclaw_server/lib/src/templates/scheduling.dart#schedulingTemplate | Existing system-job row and runnable action presentation
file | packages/dartclaw_server/lib/src/scheduling/schedule_service.dart#ScheduleService.runJobNow | S09 overlap-safe run-now plus merged immutable system-action descriptor/lifecycle authority
file | packages/dartclaw_server/lib/src/api/config_routes.dart#configRoutes | Existing job run endpoint and immediate started/conflict/not-found outcomes
file | packages/dartclaw_server/lib/src/api/config_api_routes.dart#configApiRoutes | Existing job list/show API projection consumed by connected CLI inspection
file | apps/dartclaw_cli/lib/src/commands/wiring/scheduling_wiring.dart#SchedulingWiring | Existing built-in system-job registration and presentation composition
file | apps/dartclaw_cli/lib/src/commands/jobs/jobs_run_command.dart#JobsRunCommand | Existing connected curation trigger and human/JSON output seam
file | apps/dartclaw_cli/lib/src/commands/jobs/jobs_show_command.dart#JobsShowCommand | Existing connected lifecycle inspection seam
file | apps/dartclaw_cli/lib/src/commands/rebuild_index_command.dart#RebuildIndexCommand | S08 offline repair result and stopped-runtime guidance
```

## Constraints & Gotchas

- **Critical – health stays independent**: Curation may be `succeeded` while index state is `degraded`; never collapse them into one badge or make derived failure negate canonical success.
- **Critical – incomplete is a lower bound**: Observation `usageBytes` and entry count are exact only with `usageKind=exact`; partial traversal preserves known values and nullable warning semantics.
- **Critical – no false zero**: Missing files in a validated complete corpus may yield zero. Read/count/coverage failure yields null plus unknown/degraded evidence.
- **Critical – no hidden status scan**: Reuse S06–S10 snapshots/status sources. Presentation code must not independently recurse through topics, observations, wiki, or index rows.
- **Avoid – lifecycle invention**: `memory-curation` is an on-demand system action, not a persisted user job; list/show/run may present it, but create/edit/delete/schedule controls must not.
- **Critical – no ambiguous presentation**: registered action IDs are reserved upstream. Do not present both colliding entries, choose one by precedence, rename either, or add compatibility copy; surface S09's validation failure and retain the prior valid live view after rejected config mutation.
- **Avoid – unsafe rendering**: Reasons, locators, file paths, and operation summaries may contain untrusted semantic text. Use `tl:text`/`tl:attr`, bounded CLI rendering, and no `tl:utext` or raw `innerHTML` for them.
- **UI state semantics**: Running/rebuilding use live working treatment; conflicted uses attention with text; degraded/unknown use static warning; succeeded/healthy use static success; failed uses static error; never pulse a terminal state.
- **HTMX state**: Polling may replace `#memory-inner` only. File-preview tabs and their scroll/loaded state stay outside the swap, while the Stimulus controller rebinds curation controls after replacement.

## Implementation Plan

### Implementation Tasks

- [ ] **TI01** One truthful operator status contract covers the complete memory lifecycle
  - Compose S03 and S06–S10 results in `MemoryStatusService.getStatus`; serialize the five Technical Overview objects through `GET /api/memory/status`, preserving nullable evidence, exact/lower-bound coverage, independent health, and bounded reasons/actions.
  - **Verify**: Service and route matrices prove S01–S07 for complete/empty/unknown corpus, prompt truncation, observation warning-minus-one/exact/partial, all four index states, absent plus all four curation states, migration recovery, and restart persistence without false zeros.

- [ ] **TI02** The Memory dashboard explains corpus roles, budgets, lifecycle, and recovery
  - Extend the existing polled status region and current component vocabulary; keep file previews static, route Curate now through the existing job run endpoint, and show revision, prompt dual-budget use, observation lower bounds, last successes, bounded results, and repair/rerun actions.
  - **Verify**: Render/controller/API tests prove S01–S07, including exact empty copy, at-least usage wording, nullable metrics, running-button overlap, changed/no-op IDs, conflict/no-effect copy, committed-but-degraded copy, escaped dynamic values, and stable file-tab state across polling.

- [ ] **TI03** Knowledge results preserve role and provenance instead of displaying every search row as memory
  - Consume S07 role metadata in the existing Hub item view: curated, archive, observation, learning, wiki, KG, and inbox labels remain distinct; source links use canonical locators and derived chunk IDs never become visible source identity.
  - **Verify**: Hub service/template tests prove S01–S02 across each role, same-text/different-source results, native wiki attribution, layer failure versus zero results, escaped labels/locators, and unchanged read-only/filter behavior.

- [ ] **TI04** Existing Scheduling and jobs surfaces control and inspect the same curation action
  - Consume S09's merged descriptor/lifecycle contract and present `memory-curation` as a runnable, non-editable, non-scheduled system action in existing list/show/run API, Scheduling, Memory, and jobs CLI surfaces; expose persisted S09 lifecycle/result fields and curation-specific next-action copy without adding another endpoint, registry, store, or run authority.
  - **Verify**: API/template/CLI component tests prove S06–S07 for collision-free merged list/show/run, first run, restart-visible last result, running overlap, success, conflict, failure, JSON parity, bounded human output, explicit create/edit/delete/toggle rejection or absence, no YAML/schedule/timer/retry controls, and exactly one S09 dispatch per accepted run. Startup-YAML and config create/edit collision fixtures prove no ambiguous row/show/run target or precedence copy is rendered and rejected mutations preserve the prior valid view.

- [ ] **TI05** Recovery guidance points to the existing safe operation
  - Render S03 backup/opaque guidance and S08 state-specific reason/action consistently; keep `dartclaw rebuild-index` offline, and make its human/JSON result report canonical revision, indexed-row outcome, health, and unchanged-state failure.
  - **Verify**: Status, CLI, and template tests prove S04–S05 for migration backup, opaque content, deleted/corrupt/degraded index, stopped edit, failed rebuild, successful rebuild, and the explicit stop-runtime precondition without online repair.

- [ ] **TI06** Every memory lifecycle state is accessible and visually coherent
  - Use canonical status indicators, cards, banners, empty state, meters, tables, focus behavior, and responsive shells; all state and action meaning has text and ARIA semantics independent of hue/motion.
  - **Verify**: Template/accessibility assertions plus project visual validation cover empty, successful, degraded, rebuilding, conflicted, and failed states at 1280 px and 375 px with no console errors; repeat successful, degraded, and conflicted semantic treatments in light theme and confirm design tokens/computed state styles, focus, disabled action, wrapping, and reduced-motion behavior.

### Testing Strategy

- [TI01,TI05] Table-drive the typed service/API state matrix. Use prerequisite service values and real temp-corpus integration fixtures where persistence matters; do not reconstruct state by mocking map keys.
- [TI02,TI03,TI04] Test rendered HTML and direct Shelf handlers at Layers 2–3, retaining existing Memory/Knowledge/Scheduling fixture builders and jobs CLI transport fakes. Dynamic content must include hostile HTML/control-text fixtures.
- [TI06] Run the project visual-validation workflow against production templates/routes with deterministic status fixtures or barriers. Capture every required state at desktop/mobile, dark as default, plus the named light-theme semantic states; inspect console and computed tokens as well as screenshots.

## Implementation Observations

_No observations recorded yet._
